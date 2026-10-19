import AppKit
import MuxShotsCore
import MuxShotsPlatform
import os

/// Owns the workspace: turns drops on the tray and edits in the panel into managed windows and groups,
/// keeps the tracker following exactly the managed windows, and persists the result.
@MainActor
final class WorkspaceController: WindowDragMonitorDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "workspace")
    /// Lets the dragged application finish its own drag before the window is moved back.
    private static let settleDelay = Duration.milliseconds(120)
    private static let fullscreenPollInterval = Duration.milliseconds(100)
    private static let fullscreenExitTimeout = Duration.seconds(3)
    /// The Space transition keeps animating briefly after the window reports leaving full screen.
    private static let fullscreenSettleDelay = Duration.milliseconds(400)
    /// A hidden window may keep at most this share of itself on screen.
    private static let hiddenVisibleShareLimit: CGFloat = 0.02

    private(set) var workspace: Workspace
    private let tracker: WindowTracker
    private let dragMonitor = WindowDragMonitor()
    private let ghostAnimator = DropGhostAnimator()
    private lazy var tray = DropTrayController(ghostAnimator: ghostAnimator)
    /// Where the current window drag is being dropped.
    private var activeSurface: DropSurface?

    /// The panel, which receives dragged windows while it is open.
    weak var panel: WorkspacePanelController?
    private var changeTask: Task<Void, Never>?

    /// Called after every change to the workspace, including title updates.
    var onChange: (() -> Void)?

    init(tracker: WindowTracker) {
        self.tracker = tracker
        do {
            workspace = try WorkspaceStore.load()
        } catch {
            Self.logger.error("cannot load the saved workspace, starting empty: \(error, privacy: .public)")
            workspace = Workspace()
        }
    }

    /// Resume managing the saved windows that still exist and start watching window drags.
    func start() {
        for window in workspace.listManagedWindows where liveApplication(of: window) == nil {
            workspace.release(window.windowId)
        }
        save()
        let listRestored = workspace.listManagedWindows.compactMap { window in
            liveApplication(of: window).map { (window.windowId, $0) }
        }
        changeTask = Task { [tracker] in
            await tracker.start()
            for (windowId, application) in listRestored {
                await tracker.manage(windowId, of: application)
            }
            await showAllHidden()
            for await change in await tracker.changes() {
                handle(change)
            }
        }
        dragMonitor.delegate = self
        dragMonitor.start()
    }

    /// Stop watching drags and save the latest titles.
    func stop() {
        dragMonitor.stop()
        changeTask?.cancel()
        save()
    }

    /// Manage a window in a group, moving it out of any group it was in.
    ///
    /// - Parameters:
    ///   - windowId: the window
    ///   - processId: the process that owns the window
    ///   - groupId: the destination group, or nil for a new group
    /// - Returns: the group the window joined, or nil if its application is gone
    @discardableResult
    func adopt(_ windowId: WindowId, processId: pid_t, into groupId: GroupId?) -> GroupId? {
        if let existing = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) {
            let joinedGroupId = workspace.adopt(existing, into: groupId)
            didChange()
            return joinedGroupId
        }
        guard let application = ApplicationMonitor.application(processId: processId) else {
            return nil
        }
        let joinedGroupId = workspace.adopt(
            ManagedWindow(windowId: windowId, application: application, title: ""),
            into: groupId
        )
        didChange()
        Task { [tracker] in
            await tracker.manage(windowId, of: application)
        }
        return joinedGroupId
    }

    /// Move a managed window to another group.
    func move(_ windowId: WindowId, to groupId: GroupId) {
        guard let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) else {
            return
        }
        workspace.adopt(window, into: groupId)
        didChange()
    }

    /// Stop managing a window.
    func release(_ windowId: WindowId) {
        guard workspace.release(windowId) else {
            return
        }
        didChange()
        Task { [tracker] in
            await tracker.release(windowId)
        }
    }

    /// Act on a managed window.
    func perform(_ action: WindowAction, on windowId: WindowId) async throws {
        guard workspace.isManaged(windowId) else {
            throw WindowActionError.notManaged(windowId: windowId)
        }
        switch action {
        case .focus:
            try await focus(windowId)
        case .hide:
            try await hide(windowId)
        case .show:
            try await show(windowId)
        case .maximize:
            try await maximize(windowId)
        }
    }

    /// Put every hidden window back, as MuxShots quits.
    func showAllHidden() async {
        for window in workspace.listHiddenWindows {
            try? await show(window.windowId)
        }
    }

    func rename(_ groupId: GroupId, to name: String) {
        workspace.rename(groupId, to: name)
        didChange()
    }

    /// Make a panel that shares the drop animation with the tray.
    func makePanel() -> WorkspacePanelController {
        let panel = WorkspacePanelController(controller: self, ghostAnimator: ghostAnimator)
        self.panel = panel
        return panel
    }

    func windowDragBegan(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        let surface: DropSurface = if let panel, panel.isShowing {
            panel
        } else {
            tray
        }
        activeSurface = surface
        surface.beginWindowDrag(
            listGroups: workspace.listGroups,
            currentGroup: workspace.group(containing: drag.windowId),
            draggedWindowId: drag.windowId,
            at: cursorLocation
        )
    }

    func windowDragMoved(_ drag: WindowDrag, to cursorLocation: CGPoint) {
        activeSurface?.updateWindowDrag(at: cursorLocation)
    }

    func windowDragEnded(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        guard let surface = activeSurface else {
            return
        }
        activeSurface = nil
        guard let target = surface.target(at: cursorLocation) else {
            surface.cancelWindowDrag()
            return
        }
        let droppedFrame = WindowServer.window(withId: drag.windowId).map { ScreenGeometry.appKitFrame(fromWindowServer: $0.frame) }
        let icon = NSRunningApplication(processIdentifier: drag.processId)?.icon
        let landedGroupId: GroupId? = switch target {
        case .group(let groupId):
            adopt(drag.windowId, processId: drag.processId, into: groupId)
        case .newGroup:
            adopt(drag.windowId, processId: drag.processId, into: nil)
        case .release:
            nil
        }
        surface.land(
            on: target,
            landedGroupId: landedGroupId,
            windowFrame: droppedFrame,
            icon: icon,
            listGroups: workspace.listGroups
        )
        Task { [tracker] in
            try? await Task.sleep(for: Self.settleDelay)
            await tracker.applyFrame(drag.startFrame, to: drag.windowId)
            if target == .release {
                self.release(drag.windowId)
            }
        }
    }

    private func focus(_ windowId: WindowId) async throws {
        if workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            try await show(windowId)
        }
        guard await tracker.raise(windowId) else {
            throw WindowActionError.cannotRaise(windowId: windowId)
        }
        guard
            let processId = await tracker.processId(of: windowId),
            let running = NSRunningApplication(processIdentifier: processId)
        else {
            throw WindowActionError.cannotRaise(windowId: windowId)
        }
        running.activate()
    }

    private func hide(_ windowId: WindowId) async throws {
        guard !workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) else {
            return
        }
        try await leaveFullscreen(windowId)
        guard let frame = WindowServer.window(withId: windowId)?.frame else {
            throw WindowActionError.noDisplay(windowId: windowId)
        }
        guard let parkedFrame = await tracker.applyFrame(ScreenGeometry.offscreenFrame(for: frame), to: windowId) else {
            throw WindowActionError.cannotMove(windowId: windowId)
        }
        workspace.markHidden(windowId, restoreFrame: frame)
        didChange()
        if ScreenGeometry.visibleShare(of: parkedFrame) > Self.hiddenVisibleShareLimit {
            Self.logger.error("window \(windowId.rawValue) stayed visible at \(String(describing: parkedFrame))")
            throw WindowActionError.cannotMove(windowId: windowId)
        }
    }

    private func show(_ windowId: WindowId) async throws {
        guard let restoreFrame = workspace.markShown(windowId) else {
            throw WindowActionError.notHidden(windowId: windowId)
        }
        didChange()
        guard await tracker.applyFrame(restoreFrame, to: windowId) != nil else {
            throw WindowActionError.cannotMove(windowId: windowId)
        }
    }

    private func maximize(_ windowId: WindowId) async throws {
        if workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            try await show(windowId)
        }
        try await leaveFullscreen(windowId)
        guard
            let frame = WindowServer.window(withId: windowId)?.frame,
            let visibleFrame = ScreenGeometry.visibleDisplayFrame(containing: frame)
        else {
            throw WindowActionError.noDisplay(windowId: windowId)
        }
        guard await tracker.applyFrame(visibleFrame, to: windowId) != nil else {
            throw WindowActionError.cannotMove(windowId: windowId)
        }
    }

    /// Bring a window out of native full screen onto a normal Space, waiting for the transition.
    private func leaveFullscreen(_ windowId: WindowId) async throws {
        guard await tracker.isFullscreen(windowId) else {
            return
        }
        guard await tracker.requestExitFullscreen(windowId) else {
            throw WindowActionError.stuckInFullscreen(windowId: windowId)
        }
        let deadline = ContinuousClock.now + Self.fullscreenExitTimeout
        while await tracker.isFullscreen(windowId) {
            guard ContinuousClock.now < deadline else {
                throw WindowActionError.stuckInFullscreen(windowId: windowId)
            }
            try await Task.sleep(for: Self.fullscreenPollInterval)
        }
        try await Task.sleep(for: Self.fullscreenSettleDelay)
    }

    private func handle(_ change: WindowChange) {
        switch change {
        case .added(let window), .updated(let window):
            workspace.updateTitle(of: window.windowId, to: window.title)
            onChange?()
        case .removed(let windowId):
            if workspace.release(windowId) {
                didChange()
            }
        }
    }

    /// The running application that owns a saved window, or nil if the window is gone or its identifier now
    /// belongs to another application's window.
    private func liveApplication(of window: ManagedWindow) -> RunningApplication? {
        guard
            let serverWindow = WindowServer.window(withId: window.windowId),
            let application = ApplicationMonitor.application(processId: serverWindow.processId),
            application.bundleId == window.application.bundleId
        else {
            return nil
        }
        return application
    }

    private func didChange() {
        save()
        onChange?()
    }

    private func save() {
        do {
            try WorkspaceStore.save(workspace)
        } catch {
            Self.logger.error("cannot save the workspace: \(error, privacy: .public)")
        }
    }
}
