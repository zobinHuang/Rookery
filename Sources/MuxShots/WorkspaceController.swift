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
    /// Focus changes this soon after a switch are the switch's own and do not trigger another.
    private static let focusQuietPeriod = Duration.milliseconds(400)

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
    /// The latest group switch; each switch waits for the one before it.
    private var switchTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var isSwitching = false
    private var focusQuietUntil = ContinuousClock.now

    /// Called after every change to the workspace, including title updates.
    var onChange: (() -> Void)?

    private let preferences: Preferences

    init(tracker: WindowTracker, preferences: Preferences) {
        self.tracker = tracker
        self.preferences = preferences
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
        focusTask = Task { [tracker] in
            for await windowId in tracker.focusedWindows {
                handleFocus(of: windowId)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self, tracker] notification in
            guard
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            let processId = running.processIdentifier
            Task { @MainActor in
                if let windowId = await tracker.focusedWindowId(ofProcess: processId) {
                    self?.handleFocus(of: windowId)
                }
            }
        }
        dragMonitor.delegate = self
        dragMonitor.start()
    }

    /// Stop watching drags and save the latest titles.
    func stop() {
        dragMonitor.stop()
        changeTask?.cancel()
        focusTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
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

    /// Stop managing a window, first putting it back on screen if MuxShots hid it.
    func release(_ windowId: WindowId) {
        let restoreFrame = workspace.markShown(windowId)
        guard workspace.release(windowId) else {
            return
        }
        didChange()
        Task { [tracker] in
            if let restoreFrame {
                await tracker.applyFrame(restoreFrame, to: windowId)
            }
            await tracker.release(windowId)
        }
    }

    /// Show one group and hide every other group's windows, or with nil show every managed window and leave
    /// group mode. Switches run one after another in the order requested.
    ///
    /// - Parameters:
    ///   - groupId: the group to show, or nil for every managed window
    ///   - frontWindowId: a member to put in front of the group's other windows
    func switchTo(_ groupId: GroupId?, bringingToFront frontWindowId: WindowId? = nil) async {
        let previousTask = switchTask
        let task = Task {
            await previousTask?.value
            isSwitching = true
            await performSwitch(to: groupId, bringingToFront: frontWindowId)
            isSwitching = false
            focusQuietUntil = ContinuousClock.now + Self.focusQuietPeriod
        }
        switchTask = task
        await task.value
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

    /// Put every hidden window back and leave group mode, as MuxShots launches or quits.
    func showAllHidden() async {
        for window in workspace.listHiddenWindows {
            try? await show(window.windowId)
        }
        workspace.deactivateAll()
        didChange()
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
        guard preferences.isDropTrayEnabled else {
            return
        }
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
        let isReturning = preferences.isReturningDroppedWindows
        Task { [tracker] in
            try? await Task.sleep(for: Self.settleDelay)
            if isReturning {
                await tracker.applyFrame(drag.startFrame, to: drag.windowId)
            }
            if target == .release {
                self.release(drag.windowId)
            }
        }
    }

    /// The active group holding the frontmost managed window, which is where the user is working.
    func frontmostActiveGroup() -> WindowGroup? {
        let listActiveGroups = workspace.listActiveGroups
        for windowId in WindowServer.listWindows().map(\.windowId) {
            if let group = listActiveGroups.first(where: { group in group.listMembers.contains { $0.windowId == windowId } }) {
                return group
            }
        }
        return listActiveGroups.first
    }

    /// Bring the next window of the frontmost active group to the front, cycling through its members in
    /// join order.
    func cycleActiveGroupWindow() async {
        guard let group = frontmostActiveGroup(), group.listMembers.count > 1 else {
            return
        }
        let listServerOrder = WindowServer.listWindows().map(\.windowId)
        let frontId = listServerOrder.first { windowId in group.listMembers.contains { $0.windowId == windowId } }
        let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? -1
        try? await focus(group.listMembers[(frontIndex + 1) % group.listMembers.count].windowId)
    }

    /// Follow the user to a hidden window they focused, through Cmd-Tab, the Dock or a notification, by
    /// switching to its group.
    private func handleFocus(of windowId: WindowId) {
        guard
            !isSwitching,
            ContinuousClock.now >= focusQuietUntil,
            workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }),
            let group = workspace.group(containing: windowId)
        else {
            return
        }
        Task {
            await switchTo(group.groupId, bringingToFront: windowId)
        }
    }

    private func performSwitch(to groupId: GroupId?, bringingToFront frontWindowId: WindowId?) async {
        let startTime = ContinuousClock.now
        let listServerWindows = WindowServer.listWindows()
        let listServerOrder = listServerWindows.map(\.windowId)
        let mapServerFrames = Dictionary(listServerWindows.map { ($0.windowId, $0.frame) }) { first, _ in first }
        for group in workspace.listActiveGroups {
            workspace.recordStack(of: group.groupId, frontToBack: listServerOrder)
        }
        let mapRecords = Dictionary(uniqueKeysWithValues: await tracker.listWindows().map { ($0.windowId, $0) })
        let displayIndex = { (window: ManagedWindow) -> Int? in
            (window.restoreFrame ?? mapServerFrames[window.windowId]).flatMap(ScreenGeometry.displayIndex(containing:))
        }

        guard let targetGroup = groupId.flatMap({ groupId in workspace.listGroups.first { $0.groupId == groupId } }) else {
            let listToShow = workspace.listHiddenWindows
            await run(showing: listToShow, hiding: [])
            workspace.deactivateAll()
            didChange()
            Self.logger.info("showed all \(listToShow.count) hidden windows in \(ContinuousClock.now - startTime, privacy: .public)")
            return
        }
        let setTargetIds = Set(targetGroup.listMembers.map(\.windowId))
        let setTargetDisplays = Set(targetGroup.listMembers.compactMap(displayIndex))
        let listToShow = workspace.listHiddenWindows.filter { setTargetIds.contains($0.windowId) }
        let listToHide = workspace.listManagedWindows.filter { window in
            guard
                !setTargetIds.contains(window.windowId),
                !window.isHidden,
                let record = mapRecords[window.windowId],
                let display = displayIndex(window)
            else {
                return false
            }
            return !record.isMinimized && !record.isFullscreen && setTargetDisplays.contains(display)
        }
        let setDisplacedIds = Set(workspace.listActiveGroups.filter { group in
            group.groupId != targetGroup.groupId
                && !Set(group.listMembers.compactMap(displayIndex)).isDisjoint(with: setTargetDisplays)
        }.map(\.groupId))
        await run(showing: listToShow, hiding: listToHide)

        var listVisible = targetGroup.listMembersFrontToBack.filter { mapRecords[$0.windowId]?.isMinimized != true }
        if let frontIndex = listVisible.firstIndex(where: { $0.windowId == frontWindowId }) {
            listVisible.insert(listVisible.remove(at: frontIndex), at: 0)
        }
        for window in listVisible.reversed() {
            _ = await tracker.raise(window.windowId)
        }
        if let frontWindow = listVisible.first, let processId = await tracker.processId(of: frontWindow.windowId) {
            NSRunningApplication(processIdentifier: processId)?.activate()
        }
        workspace.activate(targetGroup.groupId, displacing: setDisplacedIds)
        didChange()
        Self.logger.info("""
            switched to \(targetGroup.name, privacy: .public) on displays \(setTargetDisplays.sorted(), privacy: .public): \
            showed \(listToShow.count), hid \(listToHide.count) in \(ContinuousClock.now - startTime, privacy: .public)
            """)
    }

    /// Show and hide windows concurrently, each application on its own tracker thread.
    private func run(showing listToShow: [ManagedWindow], hiding listToHide: [ManagedWindow]) async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for window in listToShow {
                taskGroup.addTask {
                    try? await self.show(window.windowId)
                }
            }
            for window in listToHide {
                taskGroup.addTask {
                    try? await self.hide(window.windowId)
                }
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
        let requestedFrame = ScreenGeometry.offscreenFrame(for: frame)
        guard let parkedFrame = await tracker.applyFrame(requestedFrame, to: windowId) else {
            throw WindowActionError.cannotMove(windowId: windowId)
        }
        Self.logger.info("""
            hid \(windowId.rawValue) from \(String(describing: frame), privacy: .public) to \
            \(String(describing: requestedFrame), privacy: .public), landed at \(String(describing: parkedFrame), privacy: .public)
            """)
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
        guard let landedFrame = await tracker.applyFrame(restoreFrame, to: windowId) else {
            throw WindowActionError.cannotMove(windowId: windowId)
        }
        Self.logger.info("""
            showed \(windowId.rawValue) at \(String(describing: restoreFrame), privacy: .public), \
            landed at \(String(describing: landedFrame), privacy: .public)
            """)
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
