import AppKit
import MuxShotsCore
import MuxShotsPlatform
import OSLog

/// The stage's window. It takes keyboard input only while a name is edited, and never activates MuxShots,
/// so clicking the stage leaves its front window's application in front.
final class StagePanel: NSPanel {
    /// The window the stage shows, which a press on the stage must not cover: AppKit orders a pressed window
    /// to the front, and the window would stay covered until it is brought forward again.
    var hostedWindowId: (() -> WindowId?)?

    override var canBecomeKey: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        let coveredWindowId = event.type == .leftMouseDown ? hostedWindowId?().flatMap { isBeneath($0) ? $0 : nil } : nil
        super.sendEvent(event)
        if let coveredWindowId {
            order(.below, relativeTo: Int(coveredWindowId.rawValue))
        }
    }

    /// Whether a window is in front of the stage.
    private func isBeneath(_ windowId: WindowId) -> Bool {
        let listInfo = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(windowNumber)) as? [[String: Any]] ?? []
        return listInfo.contains { ($0[kCGWindowNumber as String] as? UInt32) == windowId.rawValue }
    }

    /// Go wherever the stage is dragged, across displays: AppKit would otherwise hold a window that crosses
    /// a display's top edge on that display. The stage settles onto one display when the drag ends.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// One stage: a window of its own, moved and resized like any other, with its groups, the tabs of the group
/// it shows and the content area that group's front window is laid over and follows. It stays just beneath
/// that window. While it is open it is also where windows dragged over it are dropped.
@MainActor
final class StageController: NSObject, DropSurface, StageActions, NSWindowDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "stage")
    private static let cornerRadius: CGFloat = 14
    private static let minimumSize = CGSize(width: 640, height: 420)
    private static let landedHold = Duration.milliseconds(260)
    private static let fadeOutDelay = Duration.milliseconds(240)
    private static let mouseReleasePollInterval = Duration.milliseconds(100)
    private static let snapDuration: TimeInterval = 0.28

    let stageId: StageId
    private let workspaceController: WorkspaceController
    private weak var coordinator: StageCoordinator?
    private let preferences: Preferences
    private let mixerController: MixerController
    private let agentUsageMonitor: AgentUsageMonitor
    private let quickNotes: QuickNotes
    private let ghostAnimator: DropGhostAnimator
    private let shortcutRecorder: ShortcutRecorder
    private let model = StageModel()
    private let contentDropPill = ContentDropPill()
    /// The front window set aside while a page shows in the content area, once it is hidden.
    private var asideWindowId: WindowId?
    private let panel: StagePanel
    private var hideTask: Task<Void, Never>?
    /// Whether the stage window is up while the workspace is still moving windows onto it.
    private(set) var isEntering = false
    /// Where the cursor was when the user started dragging the stage.
    private var moveStartCursor: CGPoint?
    /// Where the stage was when the user started dragging it.
    private var moveStartOrigin: CGPoint?
    private var tabDragTask: Task<Void, Never>?
    /// The frame to go back to when a maximized stage is double-clicked again.
    private var unmaximizedFrame: CGRect?
    /// Whether the stage is moving along with its dragged front window, which then moves itself.
    var isFollowingWindow = false

    init(
        stageId: StageId,
        workspaceController: WorkspaceController,
        preferences: Preferences,
        mixerController: MixerController,
        agentUsageMonitor: AgentUsageMonitor,
        quickNotes: QuickNotes,
        ghostAnimator: DropGhostAnimator,
        shortcutRecorder: ShortcutRecorder,
        coordinator: StageCoordinator
    ) {
        self.stageId = stageId
        self.coordinator = coordinator
        self.workspaceController = workspaceController
        self.preferences = preferences
        self.mixerController = mixerController
        self.agentUsageMonitor = agentUsageMonitor
        self.quickNotes = quickNotes
        self.ghostAnimator = ghostAnimator
        self.shortcutRecorder = shortcutRecorder
        panel = StagePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = Self.minimumSize
        panel.collectionBehavior = [.fullScreenNone]
        model.isSidebarCollapsed = preferences.isStageSidebarCollapsed

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        panel.contentView = background
        super.init()
        panel.hostedWindowId = { [weak self] in
            guard let self, model.shownPage == nil else {
                return nil
            }
            return model.selectedWindowId
        }
        let stageView = StageView.makeHostingView(
            model: model,
            preferences: preferences,
            shortcutRecorder: shortcutRecorder,
            mixer: mixerController,
            agentUsage: agentUsageMonitor,
            notes: quickNotes,
            actions: self
        )
        stageView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stageView)
        NSLayoutConstraint.activate([
            stageView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stageView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stageView.topAnchor.constraint(equalTo: background.topAnchor),
            stageView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.delegate = self
    }

    /// Whether the stage's window is up.
    var isShowing: Bool {
        model.isVisible
    }

    /// Whether the stage has closed and its window has faded out, so nothing refers to it any more.
    var isClosed: Bool {
        !model.isVisible && !isEntering && hideTask == nil
    }

    /// The stage's frame, in AppKit screen coordinates.
    var frame: CGRect {
        panel.frame
    }

    /// The stage's window, as the window server knows it.
    var windowId: WindowId {
        WindowId(rawValue: UInt32(panel.windowNumber))
    }

    /// The display the stage is on.
    var screen: NSScreen? {
        panel.screen
    }

    /// Whether a window is this stage's.
    func owns(_ window: NSWindow?) -> Bool {
        window === panel
    }

    /// Open the stage with a frame.
    ///
    /// - Parameter frame: the frame, in AppKit screen coordinates
    func open(frame: CGRect) {
        hideTask?.cancel()
        hideTask = nil
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        model.isVisible = true
        isEntering = true
        refresh()
        let contentFrame = contentFrame()
        Task { [weak self, workspaceController, stageId] in
            await workspaceController.enterStage(stageId, contentFrame: contentFrame)
            self?.isEntering = false
            self?.coordinator?.refresh()
        }
    }

    /// Cover the stage with a picture of how it looks now, so a change of theme can fade in beneath it.
    ///
    /// - Returns: the cover, to fade out and remove, or nil if the stage is not showing
    func coverForCrossfade() -> NSView? {
        guard
            panel.isVisible,
            let contentView = panel.contentView,
            let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else {
            return nil
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let image = NSImage(size: contentView.bounds.size)
        image.addRepresentation(bitmap)
        let cover = NSImageView(frame: contentView.bounds)
        cover.image = image
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        contentView.addSubview(cover)
        return cover
    }

    /// Keep the stage just beneath a window, as its front window comes forward.
    func keep(beneath windowId: WindowId) {
        panel.order(.below, relativeTo: Int(windowId.rawValue))
    }

    /// Bring the stage's front window forward and give it keyboard focus, as when the stage is clicked.
    func bringContentToFront() {
        guard model.shownPage == nil else {
            return
        }
        workspaceController.focusFront(ofStage: stageId)
    }

    /// Move the stage without animation; its front window follows unless it is the one moving the stage.
    func move(to origin: CGPoint) {
        panel.setFrameOrigin(origin)
    }

    /// Close the stage, hiding the windows it showed, or putting every window back if it is the last.
    func close() {
        Task { [workspaceController, stageId] in
            await workspaceController.exitStage(stageId)
        }
        dismiss()
    }

    /// Move the stage to another display, keeping its place and size relative to the display.
    func place(on screen: NSScreen) {
        guard let currentScreen = panel.screen else {
            animate(to: screen.visibleFrame)
            return
        }
        let source = currentScreen.visibleFrame
        let target = screen.visibleFrame
        let frame = panel.frame
        animate(to: CGRect(
            x: target.minX + (frame.minX - source.minX) / source.width * target.width,
            y: target.minY + (frame.minY - source.minY) / source.height * target.height,
            width: frame.width / source.width * target.width,
            height: frame.height / source.height * target.height
        ))
    }

    /// Fill the display, or go back to the frame before filling it.
    func toggleMaximize() {
        guard let visibleFrame = panel.screen?.visibleFrame else {
            return
        }
        if panel.frame == visibleFrame, let unmaximizedFrame {
            animate(to: unmaximizedFrame)
            self.unmaximizedFrame = nil
        } else {
            unmaximizedFrame = panel.frame
            animate(to: visibleFrame)
        }
    }

    func windowDidMove(_ notification: Notification) {
        if !isFollowingWindow {
            relayout()
        }
    }

    func windowDidResize(_ notification: Notification) {
        relayout()
    }

    /// Redisplay the groups and tabs; take the window down if the stage closed some other way, as when
    /// every window is shown.
    func refresh() {
        guard model.isVisible else {
            return
        }
        guard workspaceController.isStageOpen(stageId) || isEntering else {
            dismiss()
            return
        }
        let isDarkTheme = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let activeGroup = workspaceController.group(onStage: stageId)
        let listStageGroups = workspaceController.groups(ofStage: stageId)
        let listGroups = listStageGroups.map { group in
            Self.makeGroupRow(group, isActive: group.groupId == activeGroup?.groupId)
        }
        let listTabs = activeGroup?.listMembers.map(Self.makeTab) ?? []
        var mapWindowNames: [WindowId: String] = [:]
        for window in (activeGroup?.listMembers ?? []) + listStageGroups.compactMap(\.listMembersFrontToBack.first) {
            mapWindowNames[window.windowId] = window.displayName
        }
        let setLinkedIds = Set(quickNotes.listNotes.flatMap(\.listLinks).map(\.windowId))
        var mapLinkedWindowNames: [WindowId: String] = [:]
        for window in workspaceController.workspace.listManagedWindows where setLinkedIds.contains(window.windowId) {
            mapLinkedWindowNames[window.windowId] = window.displayName
        }
        let selectedWindowId = activeGroup?.listMembersFrontToBack.first?.windowId
        if model.isDarkTheme != isDarkTheme {
            model.isDarkTheme = isDarkTheme
        }
        if model.listClockCities != preferences.listClockCities {
            model.listClockCities = preferences.listClockCities
        }
        if model.listGroups != listGroups {
            model.listGroups = listGroups
        }
        if model.listTabs != listTabs {
            model.listTabs = listTabs
        }
        if model.mapWindowNames != mapWindowNames {
            model.mapWindowNames = mapWindowNames
        }
        if model.mapLinkedWindowNames != mapLinkedWindowNames {
            model.mapLinkedWindowNames = mapLinkedWindowNames
        }
        if model.selectedWindowId != selectedWindowId {
            model.selectedWindowId = selectedWindowId
        }
        if
            let asideWindowId,
            asideWindowId != selectedWindowId
            || !workspaceController.workspace.listHiddenWindows.contains(where: { $0.windowId == asideWindowId })
        {
            leavePage()
        }
    }

    /// Show a window's new title in its tab, its group's row and the notes linked to it, without rebuilding
    /// the rest of the stage.
    func refreshWindowTitle(_ windowId: WindowId) {
        guard
            model.isVisible,
            model.mapWindowNames[windowId] != nil || model.mapLinkedWindowNames[windowId] != nil,
            let window = workspaceController.workspace.group(containing: windowId)?.listMembers.first(where: { $0.windowId == windowId })
        else {
            return
        }
        if let shownName = model.mapWindowNames[windowId], shownName != window.displayName {
            model.mapWindowNames[windowId] = window.displayName
        }
        if let linkedName = model.mapLinkedWindowNames[windowId], linkedName != window.displayName {
            model.mapLinkedWindowNames[windowId] = window.displayName
        }
    }

    private static func makeGroupRow(_ group: WindowGroup, isActive: Bool) -> StageGroupRow {
        StageGroupRow(
            groupId: group.groupId,
            name: group.name,
            listBundleIds: group.listMembersFrontToBack.map(\.application.bundleId),
            frontWindowId: group.listMembersFrontToBack.first?.windowId,
            isActive: isActive
        )
    }

    private static func makeTab(_ window: ManagedWindow) -> StageTab {
        StageTab(
            windowId: window.windowId,
            bundleId: window.application.bundleId,
            hasCustomName: window.customName != nil
        )
    }

    // MARK: - Stage actions

    func selectGroup(_ groupId: GroupId) {
        leavePage()
        Task { [workspaceController, stageId] in
            await workspaceController.switchTo(groupId, onStage: stageId)
        }
    }

    func selectTab(_ windowId: WindowId) {
        guard let groupId = workspaceController.workspace.group(containing: windowId)?.groupId else {
            return
        }
        leavePage()
        Task { [workspaceController, stageId] in
            await workspaceController.switchTo(groupId, bringingToFront: windowId, onStage: stageId)
        }
    }

    func releaseWindow(_ windowId: WindowId) {
        workspaceController.release(windowId)
    }

    func moveWindow(_ windowId: WindowId, to groupId: GroupId?) {
        workspaceController.moveWindow(windowId, to: groupId, onStage: stageId)
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
        guard
            model.shownPage == nil,
            panel.isKeyWindow
        else {
            return
        }
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

    func noteDragBegan(_ noteId: NoteId) {
        model.draggingNoteId = noteId
        clearDragStateOnMouseUp()
    }

    func dragEntered() {
        clearDragStateOnMouseUp()
    }

    func linkNote(_ noteId: NoteId?, to windowId: WindowId) -> NoteId? {
        guard
            let group = workspaceController.workspace.group(containing: windowId),
            let window = group.listMembers.first(where: { $0.windowId == windowId })
        else {
            return nil
        }
        let link = NoteLink(
            windowId: windowId,
            groupId: group.groupId,
            name: window.displayName,
            bundleId: window.application.bundleId
        )
        let linkedNoteId: NoteId
        if let noteId {
            guard quickNotes.addLink(link, to: noteId) else {
                return nil
            }
            linkedNoteId = noteId
        } else {
            linkedNoteId = quickNotes.add(listLinks: [link])
        }
        coordinator?.refresh()
        return linkedNoteId
    }

    func openLink(_ link: NoteLink) {
        let workspace = workspaceController.workspace
        guard let groupId = workspace.group(containing: link.windowId)?.groupId else {
            if workspace.listGroups.contains(where: { $0.groupId == link.groupId }) {
                selectGroup(link.groupId)
            }
            return
        }
        let isShownInFront = workspaceController.stage(showing: groupId).flatMap { shownStageId in
            workspaceController.group(onStage: shownStageId)?.listMembersFrontToBack.first?.windowId
        } == link.windowId
        if !isShownInFront {
            selectTab(link.windowId)
        }
    }

    func moveGroup(_ groupId: GroupId, before targetGroupId: GroupId?) {
        if workspaceController.stage(owning: groupId) == stageId {
            workspaceController.moveGroup(groupId, before: targetGroupId)
        } else {
            workspaceController.assignGroup(groupId, toStage: stageId, before: targetGroupId)
        }
    }

    func moveTab(_ windowId: WindowId, before targetWindowId: WindowId?) {
        guard let shownGroupId = workspaceController.group(onStage: stageId)?.groupId else {
            return
        }
        if workspaceController.workspace.group(containing: windowId)?.groupId != shownGroupId {
            workspaceController.moveWindow(windowId, to: shownGroupId, onStage: stageId)
        }
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

    func newStage() {
        coordinator?.openStage()
    }

    func showPage(_ page: StagePage) {
        guard model.shownPage != page else {
            closePage()
            return
        }
        open(page)
    }

    /// Show a page in the content area, setting the front window aside unless another page has already.
    func open(_ page: StagePage) {
        guard model.shownPage == nil else {
            model.shownPage = page
            return
        }
        model.shownPage = page
        panel.makeKey()
        guard let windowId = model.selectedWindowId else {
            return
        }
        Task { [weak self, workspaceController] in
            do {
                try await workspaceController.perform(.hide, on: windowId)
            } catch {
                Self.logger.error("cannot set \(windowId.rawValue) aside for a page: \(error, privacy: .public)")
                return
            }
            if self?.model.shownPage != nil {
                self?.asideWindowId = windowId
            }
        }
    }

    func closePage() {
        guard model.shownPage != nil else {
            return
        }
        leavePage()
        guard let groupId = workspaceController.group(onStage: stageId)?.groupId else {
            return
        }
        Task { [workspaceController, stageId] in
            await workspaceController.switchTo(groupId, onStage: stageId)
        }
    }

    /// Take the page out of the content area, leaving whatever brings a window forward next to do so.
    private func leavePage() {
        guard model.shownPage != nil else {
            return
        }
        model.shownPage = nil
        asideWindowId = nil
        shortcutRecorder.cancel()
        if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    func toggleTheme() {
        preferences.theme = model.isDarkTheme ? .light : .dark
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
        settleOnCursorDisplay()
    }

    /// Fit the stage wholly onto the display under the cursor, as a drag of it ends.
    func settleOnCursorDisplay() {
        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? panel.screen {
            settle(on: screen)
        }
    }

    /// Fit the stage wholly onto the display it is mostly on, or the main display if it is on none.
    func settleOnItsDisplay() {
        if let screen = panel.screen ?? NSScreen.main {
            settle(on: screen)
        }
    }

    /// Fit the stage wholly onto a display, shrinking it if it is larger, and refit its front window.
    private func settle(on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        if frame == panel.frame {
            relayout()
        } else {
            animate(to: frame)
        }
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
        if zone == .content || zone == .contentPill {
            contentDropPill.show(
                over: ScreenGeometry.appKitFrame(fromWindowServer: contentFrame()),
                groupName: workspaceController.group(onStage: stageId)?.name
            )
            contentDropPill.isHovered = zone == .contentPill
        } else {
            contentDropPill.dismiss()
        }
        let hoveredZone = zone == .content ? nil : zone
        if hoveredZone != model.hoveredZone, hoveredZone != nil, hoveredZone != .contentPill {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        model.hoveredZone = hoveredZone
    }

    func target(at cursorLocation: CGPoint) -> DropTarget? {
        switch zone(at: cursorLocation) {
        case .content:
            nil
        case .contentPill:
            workspaceController.group(onStage: stageId).map { .group($0.groupId) } ?? .newGroup
        case .group(let groupId):
            .group(groupId)
        case .newGroup, .newGroupRow:
            .newGroup
        case .sidebar:
            nil
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
            if zone == .contentPill {
                contentDropPill.land()
            } else {
                contentDropPill.dismiss()
            }
            refresh()
            model.landedZone = landedGroupId.map { .group($0) }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            Task { [weak self] in
                try? await Task.sleep(for: Self.landedHold)
                self?.model.landedZone = nil
            }
        }
        let landingZone: StageZone? = switch zone {
        case .group, .contentPill:
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
        contentDropPill.dismiss()
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

    /// Refit the front window to the content area as the stage is laid out now.
    func relayout() {
        workspaceController.relayoutStage(stageId, contentFrame: contentFrame())
    }

    private func animate(to frame: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.snapDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.relayout()
            }
        }
    }

    private func zone(at cursorLocation: CGPoint) -> StageZone? {
        guard panel.isVisible, panel.frame.contains(cursorLocation) else {
            return nil
        }
        if contentDropPill.frame?.contains(cursorLocation) == true {
            return .contentPill
        }
        let listPriority: [StageZone] = [.release, .newGroup, .newGroupRow]
            + model.listGroups.map { .group($0.groupId) }
            + [.sidebar, .content]
        let zone = listPriority.first { zone in
            screenFrame(of: zone)?.contains(cursorLocation) == true
        }
        switch zone {
        case .newGroupRow:
            return .newGroup
        case .sidebar:
            return nil
        default:
            return zone
        }
    }

    private func screenFrame(of zone: StageZone) -> CGRect? {
        if zone == .contentPill {
            return contentDropPill.frame
        }
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

    /// Take the stage's window down.
    func dismiss() {
        model.isVisible = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeOutDelay)
            guard let self, !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
            hideTask = nil
            coordinator?.refresh()
        }
    }
}
