import AppKit
import MuxShotsCore
import MuxShotsPlatform

/// The stage: a backdrop that fills a display beneath every window, with the groups, the active group's
/// tabs and the content area its front window is laid over. While it is open it is also where dragged
/// windows are dropped.
@MainActor
final class StageController: DropSurface {
    /// Above the desktop icons and below every application window, so the stage never covers a window.
    private static let backdropLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private static let landedHold = Duration.milliseconds(260)

    private let workspaceController: WorkspaceController
    private let ghostAnimator: DropGhostAnimator
    private let model = StageModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    /// Whether the stage window is up while the workspace is still moving windows onto it.
    private var isEntering = false

    init(workspaceController: WorkspaceController, ghostAnimator: DropGhostAnimator) {
        self.workspaceController = workspaceController
        self.ghostAnimator = ghostAnimator
        panel = NSPanel(
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

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let stageView = StageView.makeHostingView(
            model: model,
            onSelectGroup: { [weak workspaceController] groupId in
                Task {
                    await workspaceController?.switchTo(groupId)
                }
            },
            onSelectTab: { [weak workspaceController] windowId in
                guard let groupId = workspaceController?.workspace.group(containing: windowId)?.groupId else {
                    return
                }
                Task {
                    await workspaceController?.switchTo(groupId, bringingToFront: windowId)
                }
            },
            onReleaseTab: { [weak workspaceController] windowId in
                workspaceController?.release(windowId)
            },
            onExit: { [weak self] in
                self?.close()
            }
        )
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
        let frame = screen.visibleFrame
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        model.isVisible = true
        isEntering = true
        refresh()
        let contentFrame = ScreenGeometry.windowServerFrame(fromAppKit: Self.contentFrame(inStage: frame))
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
                title: window.title,
                applicationName: window.application.name,
                bundleId: window.application.bundleId
            )
        } ?? []
        model.selectedWindowId = activeGroup?.listMembersFrontToBack.first?.windowId
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

    /// The content area of a stage covering a frame, both in AppKit screen coordinates.
    private static func contentFrame(inStage stageFrame: CGRect) -> CGRect {
        CGRect(
            x: stageFrame.minX + StageModel.sidebarWidth,
            y: stageFrame.minY + StageModel.contentInset,
            width: stageFrame.width - StageModel.sidebarWidth - StageModel.contentInset,
            height: stageFrame.height - StageModel.tabBarHeight - StageModel.contentInset
        )
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
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
            hideTask = nil
        }
    }
}
