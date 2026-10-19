import AppKit
import MuxShotsCore
import MuxShotsPlatform

/// The panel behind the stage. It takes keyboard input only while a name is edited, and never activates
/// MuxShots, so clicking the stage leaves the front window's application in front.
final class StagePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// The stage: a backdrop that fills a display beneath every window, with the groups, the active group's
/// tabs and the content area its front window is laid over. While it is open it is also where dragged
/// windows are dropped.
@MainActor
final class StageController: DropSurface, StageActions {
    /// Just beneath normal windows, and so above the desktop and its widgets.
    private static let backdropLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private static let landedHold = Duration.milliseconds(260)
    private static let fadeOutDelay = Duration.milliseconds(240)
    private static let mouseReleasePollInterval = Duration.milliseconds(100)
    private static let snapDuration: TimeInterval = 0.28

    private let workspaceController: WorkspaceController
    private let preferences: Preferences
    private let ghostAnimator: DropGhostAnimator
    private let model = StageModel()
    private let panel: StagePanel
    private var hideTask: Task<Void, Never>?
    /// Whether the stage window is up while the workspace is still moving windows onto it.
    private var isEntering = false
    /// Where the cursor was when the user started dragging the stage.
    private var moveStartCursor: CGPoint?
    /// Where the stage was when the user started dragging it.
    private var moveStartOrigin: CGPoint?
    private var tabDragTask: Task<Void, Never>?

    init(workspaceController: WorkspaceController, preferences: Preferences, ghostAnimator: DropGhostAnimator) {
        self.workspaceController = workspaceController
        self.preferences = preferences
        self.ghostAnimator = ghostAnimator
        panel = StagePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = Self.backdropLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        model.isSidebarCollapsed = preferences.isStageSidebarCollapsed

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let stageView = StageView.makeHostingView(model: model, actions: self)
        stageView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stageView)
        NSLayoutConstraint.activate([
            stageView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stageView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stageView.topAnchor.constraint(equalTo: background.topAnchor),
            stageView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Whether the stage is showing.
    var isOpen: Bool {
        workspaceController.isStageOpen
    }

    /// Open the stage on the display under the cursor, or close it if it is open.
    func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    /// Open the stage on the display under the cursor.
    func open() {
        let cursor = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main
        else {
            return
        }
        hideTask?.cancel()
        hideTask = nil
        panel.setFrame(screen.visibleFrame, display: true)
        panel.orderFrontRegardless()
        model.isVisible = true
        isEntering = true
        refresh()
        let contentFrame = contentFrame()
        Task { [weak self, workspaceController] in
            await workspaceController.enterStage(contentFrame: contentFrame)
            self?.isEntering = false
            self?.refresh()
        }
    }

    /// Close the stage, putting every window back where it was.
    func close() {
        Task { [workspaceController] in
            await workspaceController.exitStage()
        }
        dismiss()
    }

    /// Move the stage to the next display, if there is more than one.
    func moveToNextDisplay() {
        let listScreens = NSScreen.screens
        guard
            isOpen,
            listScreens.count > 1,
            let currentIndex = listScreens.firstIndex(where: { $0.visibleFrame.intersects(panel.frame) })
        else {
            return
        }
        snap(to: listScreens[(currentIndex + 1) % listScreens.count])
    }

    /// Redisplay the groups and tabs; take the window down if the stage closed some other way, as when
    /// every window is shown.
    func refresh() {
        guard model.isVisible else {
            return
        }
        guard workspaceController.isStageOpen || isEntering else {
            dismiss()
            return
        }
        let workspace = workspaceController.workspace
        model.listGroups = workspace.listGroups.map { group in
            StageGroupRow(
                groupId: group.groupId,
                name: group.name,
                listBundleIds: group.listMembersFrontToBack.map(\.application.bundleId),
                isActive: workspace.isActive(group.groupId)
            )
        }
        let activeGroup = workspace.listActiveGroups.first
        model.activeGroupName = activeGroup?.name
        model.listTabs = activeGroup?.listMembers.map { window in
            StageTab(
                windowId: window.windowId,
                title: window.displayName,
                bundleId: window.application.bundleId,
                hasCustomName: window.customName != nil
            )
        } ?? []
        model.selectedWindowId = activeGroup?.listMembersFrontToBack.first?.windowId
    }

    // MARK: - Stage actions

    func selectGroup(_ groupId: GroupId) {
        Task { [workspaceController] in
            await workspaceController.switchTo(groupId)
        }
    }

    func selectTab(_ windowId: WindowId) {
        guard let groupId = workspaceController.workspace.group(containing: windowId)?.groupId else {
            return
        }
        Task { [workspaceController] in
            await workspaceController.switchTo(groupId, bringingToFront: windowId)
        }
    }

    func releaseWindow(_ windowId: WindowId) {
        workspaceController.release(windowId)
    }

    func moveWindow(_ windowId: WindowId, to groupId: GroupId?) {
        workspaceController.moveWindow(windowId, to: groupId)
    }

    func renameGroup(_ groupId: GroupId, to name: String) {
        workspaceController.rename(groupId, to: name)
    }

    func renameWindow(_ windowId: WindowId, to name: String) {
        workspaceController.rename(window: windowId, to: name)
    }

    func beginEditing() {
        panel.makeKey()
    }

    func endEditing() {
        panel.resignKey()
        workspaceController.focusStageFront()
    }

    func tabDragBegan() {
        model.isDraggingTab = true
        clearDragStateOnMouseUp()
    }

    func groupDragBegan(_ groupId: GroupId) {
        model.draggingGroupId = groupId
        clearDragStateOnMouseUp()
    }

    func moveGroup(_ groupId: GroupId, before targetGroupId: GroupId?) {
        workspaceController.moveGroup(groupId, before: targetGroupId)
    }

    func moveTab(_ windowId: WindowId, before targetWindowId: WindowId?) {
        workspaceController.moveTab(windowId, before: targetWindowId)
    }

    /// Clear the drag feedback once the mouse is released, wherever the drag ended.
    private func clearDragStateOnMouseUp() {
        tabDragTask?.cancel()
        tabDragTask = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: Self.mouseReleasePollInterval)
            }
            self?.model.clearDragState()
        }
    }

    func toggleSidebar() {
        model.isSidebarCollapsed.toggle()
        preferences.isStageSidebarCollapsed = model.isSidebarCollapsed
        relayout()
    }

    func exitStage() {
        close()
    }

    func moveStageChanged() {
        let cursor = NSEvent.mouseLocation
        guard let moveStartCursor, let moveStartOrigin else {
            moveStartCursor = cursor
            moveStartOrigin = panel.frame.origin
            return
        }
        panel.setFrameOrigin(CGPoint(
            x: moveStartOrigin.x + cursor.x - moveStartCursor.x,
            y: moveStartOrigin.y + cursor.y - moveStartCursor.y
        ))
    }

    func moveStageEnded() {
        moveStartCursor = nil
        moveStartOrigin = nil
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        snap(to: screen)
    }

    // MARK: - Dropping windows

    func beginWindowDrag(
        listGroups: [WindowGroup],
        currentGroup: WindowGroup?,
        draggedWindowId: WindowId,
        at cursorLocation: CGPoint
    ) {
        model.isReceivingWindow = true
        model.isDraggingManagedWindow = currentGroup != nil
        updateWindowDrag(at: cursorLocation)
    }

    func updateWindowDrag(at cursorLocation: CGPoint) {
        let zone = zone(at: cursorLocation)
        if zone != model.hoveredZone, zone != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        model.hoveredZone = zone
    }

    func target(at cursorLocation: CGPoint) -> DropTarget? {
        switch zone(at: cursorLocation) {
        case .content:
            workspaceController.workspace.listActiveGroups.first.map { .group($0.groupId) } ?? .newGroup
        case .group(let groupId):
            .group(groupId)
        case .newGroup, .sidebar, .newGroupRow:
            .newGroup
        case .release:
            .release
        case nil:
            nil
        }
    }

    func land(
        on target: DropTarget,
        landedGroupId: GroupId?,
        windowFrame: CGRect?,
        icon: NSImage?,
        listGroups: [WindowGroup]
    ) {
        let zone = model.hoveredZone
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else {
                return
            }
            model.isReceivingWindow = false
            model.hoveredZone = nil
            refresh()
            model.landedZone = landedGroupId.map { .group($0) }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            Task { [weak self] in
                try? await Task.sleep(for: Self.landedHold)
                self?.model.landedZone = nil
            }
        }
        let landingZone: StageZone? = switch zone {
        case .group:
            zone
        case .newGroup:
            model.mapZoneFrames[.newGroupRow] == nil ? .newGroup : .newGroupRow
        default:
            nil
        }
        guard
            let windowFrame,
            let landingZone,
            let targetFrame = screenFrame(of: landingZone),
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            finish()
            return
        }
        ghostAnimator.fly(from: windowFrame, to: targetFrame, icon: icon, completion: finish)
    }

    func cancelWindowDrag() {
        model.isReceivingWindow = false
        model.hoveredZone = nil
    }

    // MARK: - Geometry

    /// The content area of the stage as it is laid out now, in window-server coordinates.
    private func contentFrame() -> CGRect {
        let stageFrame = panel.frame
        let sidebarWidth = model.sidebarWidth
        return ScreenGeometry.windowServerFrame(fromAppKit: CGRect(
            x: stageFrame.minX + sidebarWidth,
            y: stageFrame.minY + StageModel.contentInset,
            width: stageFrame.width - sidebarWidth - StageModel.contentInset,
            height: stageFrame.height - StageModel.tabBarHeight - StageModel.contentInset
        ))
    }

    /// Fill a display with the stage, animating there, and refit the front window.
    private func snap(to screen: NSScreen) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.snapDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(screen.visibleFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
    }

    private func relayout() {
        let contentFrame = contentFrame()
        Task { [workspaceController] in
            await workspaceController.relayoutStage(contentFrame: contentFrame)
        }
    }

    private func zone(at cursorLocation: CGPoint) -> StageZone? {
        guard panel.isVisible, panel.frame.contains(cursorLocation) else {
            return nil
        }
        let listPriority: [StageZone] = [.release, .newGroup, .newGroupRow]
            + model.listGroups.map { .group($0.groupId) }
            + [.sidebar, .content]
        let zone = listPriority.first { zone in
            screenFrame(of: zone)?.contains(cursorLocation) == true
        }
        switch zone {
        case .sidebar, .newGroupRow:
            return .newGroup
        default:
            return zone
        }
    }

    private func screenFrame(of zone: StageZone) -> CGRect? {
        guard let frame = model.mapZoneFrames[zone] else {
            return nil
        }
        let isDropOnlyZone = [StageZone.newGroup, .release, .newGroupRow].contains(zone)
        if zone == .release && !model.isDraggingManagedWindow || isDropOnlyZone && !model.isReceivingWindow {
            return nil
        }
        if zone == .newGroupRow && model.hoveredZone != .newGroup {
            return nil
        }
        return CGRect(
            x: panel.frame.minX + frame.minX,
            y: panel.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func dismiss() {
        model.isVisible = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeOutDelay)
            guard let self, !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
            hideTask = nil
        }
    }
}
