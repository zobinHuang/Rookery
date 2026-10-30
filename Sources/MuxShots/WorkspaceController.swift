import AppKit
import MuxShotsCore
import MuxShotsPlatform
import os

/// Owns the workspace: turns drops on the tray, the panel and the stage into managed windows and groups,
/// keeps the tracker following exactly the managed windows, lays them out while the stage is open, and
/// persists the result.
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
    /// How long after a switch the application of the window it brought forward may still settle its focus
    /// on another of its windows, one hidden, which is then taken back rather than switched to.
    private static let focusReclaimPeriod = Duration.milliseconds(1500)
    /// How long a hidden window must keep focus before it counts as chosen: focus passes through other
    /// windows while an application activates.
    private static let focusSettleDelay = Duration.milliseconds(150)
    /// Applications left with only hidden windows are hidden this long after the last layout change, once
    /// the application being switched to has taken over activation.
    private static let applicationHidingDelay = Duration.milliseconds(500)
    /// How long bringing a stage's front window forward waits for the click that asked for it to start a
    /// switch of its own.
    private static let clickActionDelay = Duration.milliseconds(50)
    /// How often, and for how long, a window its application was asked to reopen is looked for again.
    private static let reopenPollInterval = Duration.milliseconds(100)
    private static let reopenTimeout = Duration.seconds(2)
    /// When, after displays change or wake, to put the stages back on a display and park again the hidden
    /// windows macOS moved on screen: macOS goes on moving windows for a few seconds after the change.
    private static let listDisplaySettleDelays = [Duration.seconds(1), Duration.seconds(4)]

    private(set) var workspace: Workspace
    /// The area each open stage's front window fills, in window-server coordinates.
    private var mapStageContentFrames: [StageId: CGRect] = [:]
    /// The group each open stage shows; a stage with no group shows nothing.
    private var mapStageGroupIds: [StageId: GroupId] = [:]
    /// The stage each group belongs to; a group in no stage is left where it is.
    private var mapGroupStageIds: [GroupId: StageId] = [:]
    /// Stages whose front window is being moved to follow them, and where it should end up next.
    private var mapPendingStageFrames: [StageId: CGRect] = [:]
    private var setFollowingStageIds: Set<StageId> = []
    private let tracker: WindowTracker
    private let dragMonitor = WindowDragMonitor()
    private let ghostAnimator = DropGhostAnimator()
    private lazy var tray = DropTrayController(ghostAnimator: ghostAnimator)
    /// Where the current window drag is being dropped.
    private var activeSurface: DropSurface?

    /// The panel, which receives dragged windows while it is open.
    weak var panel: WorkspacePanelController?
    /// The stages, which receive dragged windows while any is open, in preference to the panel.
    weak var stageCoordinator: StageCoordinator?
    private var changeTask: Task<Void, Never>?
    /// Resuming the saved windows at launch, which every layout change waits for.
    private var startupTask: Task<Void, Never>?
    /// The latest layout change (a switch, or opening or closing the stage); each waits for the one before.
    private var switchTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var applicationHidingTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var listWakeObservers: [NSObjectProtocol] = []
    private var displayChangeTask: Task<Void, Never>?
    private var isSwitching = false
    /// How many switches have been asked for, which tells whether one was asked for in the meantime.
    private var switchRequestCount = 0
    /// Whether the workspace changed during the running layout change, which tells the views once when it
    /// ends rather than once for every window it moves.
    private var isChangePending = false
    /// Managed windows the user has used, most recent first.
    private var listRecentWindowIds: [WindowId] = []
    private var focusQuietUntil = ContinuousClock.now
    /// The window the latest layout change brought forward, whose application's focus is taken back to it
    /// until `focusReclaimUntil`.
    private var broughtForwardWindowId: WindowId?
    private var focusReclaimUntil = ContinuousClock.now

    /// Called after a structural or user initiated workspace change.
    var onChange: (() -> Void)?
    /// Called when a managed window's displayed title changes, without changing workspace structure.
    var onWindowTitleChange: ((WindowId) -> Void)?
    /// The browsers playing a video in the sidebar, which are never hidden: a hidden browser stops drawing
    /// the page the video streams from.
    var pictureProcessIds: () -> Set<pid_t> = { [] }
    /// The applications playing sound, which are hidden but never put in the background, where their sound
    /// could stutter.
    var playingBundleIds: () -> Set<String> = { [] }
    private let throttle = ApplicationThrottle()
    private var unhideObserver: NSObjectProtocol?

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
        throttle.releaseLeftovers()
        let mapServerWindows = Dictionary(
            WindowServer.listWindows().map { ($0.windowId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for window in workspace.listManagedWindows where liveApplication(of: window, among: mapServerWindows) == nil {
            workspace.release(window.windowId)
        }
        save()
        let listRestored = workspace.listManagedWindows.compactMap { window in
            liveApplication(of: window, among: mapServerWindows).map { (window.windowId, $0) }
        }
        let startupTask = Task { [tracker] in
            await tracker.start()
            for (windowId, application) in listRestored {
                await tracker.manage(windowId, of: application)
            }
            await restoreAllWindows()
        }
        self.startupTask = startupTask
        changeTask = Task { [tracker] in
            await startupTask.value
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
                self?.throttle.release(processId)
                if let windowId = await tracker.focusedWindowId(ofProcess: processId) {
                    self?.handleFocus(of: windowId)
                }
            }
        }
        unhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            let processId = running.processIdentifier
            MainActor.assumeIsolated {
                self?.throttle.release(processId)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysDidChange()
            }
        }
        listWakeObservers = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysDidChange()
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
        applicationHidingTask?.cancel()
        displayChangeTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let unhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unhideObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        throttle.releaseAll()
        for observer in listWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        save()
    }

    /// Manage a window in a group, moving it out of any group it was in.
    ///
    /// - Parameters:
    ///   - windowId: the window
    ///   - processId: the process that owns the window
    ///   - groupId: the destination group, or nil for a new group
    ///   - homeFrame: where the window belongs off the stage, when it is not where it is now, as for a window
    ///     dragged onto the stage
    ///   - stageId: the stage the window was dropped on, which shows a group the drop creates
    /// - Returns: the group the window joined, or nil if its application is gone
    @discardableResult
    func adopt(
        _ windowId: WindowId,
        processId: pid_t,
        into groupId: GroupId?,
        homeFrame: CGRect? = nil,
        onStage stageId: StageId? = nil
    ) -> GroupId? {
        let isNew = !workspace.isManaged(windowId)
        let isNewGroup = groupId == nil
        let joinedGroupId: GroupId
        let application: RunningApplication
        if let existing = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) {
            joinedGroupId = workspace.adopt(existing, into: groupId)
            application = existing.application
        } else {
            guard let running = ApplicationMonitor.application(processId: processId) else {
                return nil
            }
            application = running
            joinedGroupId = workspace.adopt(ManagedWindow(windowId: windowId, application: application, title: ""), into: groupId)
        }
        if isStageOpen, let homeFrame {
            workspace.markStaged(windowId, homeFrame: homeFrame)
        }
        didChange()
        Task { [tracker] in
            if isNew {
                await tracker.manage(windowId, of: application)
            }
            guard self.isStageOpen else {
                return
            }
            if let frame = await tracker.frame(of: windowId) {
                self.workspace.markStaged(windowId, homeFrame: frame)
            }
            if self.mapGroupStageIds[joinedGroupId] == nil, let ownerId = stageId ?? self.focusedStageId() {
                self.mapGroupStageIds[joinedGroupId] = ownerId
            }
            guard let ownerId = self.mapGroupStageIds[joinedGroupId] else {
                return
            }
            if isNewGroup || self.mapStageGroupIds[ownerId] == joinedGroupId || self.mapStageGroupIds[ownerId] == nil {
                await self.switchTo(joinedGroupId, bringingToFront: windowId)
            } else if let shownGroupId = self.mapStageGroupIds[ownerId] {
                await self.switchTo(shownGroupId)
            }
        }
        return joinedGroupId
    }

    /// Whether any stage is open.
    var isStageOpen: Bool {
        !mapStageContentFrames.isEmpty
    }

    /// Whether a stage is open.
    func isStageOpen(_ stageId: StageId) -> Bool {
        mapStageContentFrames[stageId] != nil
    }

    /// The group a stage shows.
    func group(onStage stageId: StageId) -> WindowGroup? {
        mapStageGroupIds[stageId].flatMap { groupId in workspace.listGroups.first { $0.groupId == groupId } }
    }

    /// The stage showing a group.
    func stage(showing groupId: GroupId) -> StageId? {
        mapStageGroupIds.first { $0.value == groupId }?.key
    }

    /// The stage a group belongs to.
    func stage(owning groupId: GroupId) -> StageId? {
        mapGroupStageIds[groupId]
    }

    /// The groups that belong to a stage, in the workspace's order.
    func groups(ofStage stageId: StageId) -> [WindowGroup] {
        workspace.listGroups.filter { mapGroupStageIds[$0.groupId] == stageId }
    }

    /// Hand a group to another stage, placing it before one of that stage's groups or last with nil.
    func assignGroup(_ groupId: GroupId, toStage stageId: StageId, before targetGroupId: GroupId?) {
        let previousStageId = mapGroupStageIds[groupId]
        mapGroupStageIds[groupId] = stageId
        workspace.moveGroup(groupId, before: targetGroupId ?? groupAfterLast(ofStage: stageId, excluding: groupId))
        didChange()
        guard previousStageId != stageId else {
            return
        }
        Task {
            if let previousStageId, self.mapStageGroupIds[previousStageId] == groupId {
                self.mapStageGroupIds[previousStageId] = nil
                if let nextGroup = self.groups(ofStage: previousStageId).first {
                    await self.switchTo(nextGroup.groupId)
                }
            }
            await self.switchTo(groupId)
        }
    }

    /// The group just after a stage's last group in the workspace's order, so a group moved before it
    /// becomes that stage's last.
    private func groupAfterLast(ofStage stageId: StageId, excluding excludedGroupId: GroupId) -> GroupId? {
        guard
            let lastIndex = workspace.listGroups.lastIndex(where: { mapGroupStageIds[$0.groupId] == stageId && $0.groupId != excludedGroupId }),
            workspace.listGroups.indices.contains(lastIndex + 1)
        else {
            return nil
        }
        let nextGroupId = workspace.listGroups[lastIndex + 1].groupId
        return nextGroupId == excludedGroupId ? nil : nextGroupId
    }

    /// The stage the user is working on: the one on the display under the cursor, else any open stage.
    func focusedStageId() -> StageId? {
        let cursor = ScreenGeometry.windowServerPoint(fromAppKit: NSEvent.mouseLocation)
        let underCursor = mapStageContentFrames.first { _, contentFrame in
            ScreenGeometry.displayFrame(containing: contentFrame)?.contains(cursor) == true
        }?.key
        return underCursor ?? mapStageContentFrames.keys.first
    }

    /// Open a stage. The first stage takes every managed window off its place, remembered as its home;
    /// each stage then shows a group no other stage shows, preferring the one the user was in, or nothing.
    ///
    /// - Parameters:
    ///   - stageId: the stage
    ///   - contentFrame: its content area, in window-server coordinates
    func enterStage(_ stageId: StageId, contentFrame: CGRect) async {
        await enqueue {
            let isFirstStage = self.mapStageContentFrames.isEmpty
            self.mapStageContentFrames[stageId] = contentFrame
            if isFirstStage {
                for window in self.workspace.listManagedWindows {
                    if let frame = await self.currentOrRestoreFrame(of: window) {
                        self.workspace.markStaged(window.windowId, homeFrame: frame)
                    }
                }
                await withTaskGroup(of: Void.self) { taskGroup in
                    for window in self.workspace.listManagedWindows {
                        taskGroup.addTask {
                            try? await self.leaveFullscreen(window.windowId)
                        }
                    }
                }
            }
            if isFirstStage {
                for group in self.workspace.listGroups where self.mapGroupStageIds[group.groupId] == nil {
                    self.mapGroupStageIds[group.groupId] = stageId
                }
            }
            let listOwnGroups = self.groups(ofStage: stageId)
            let frontmostGroup = self.frontmostActiveGroup().flatMap { group in
                listOwnGroups.contains { $0.groupId == group.groupId } ? group : nil
            }
            guard let startGroup = frontmostGroup ?? listOwnGroups.first else {
                self.didChange()
                return
            }
            await self.performStageSwitch(to: startGroup.groupId, on: stageId, bringingToFront: nil)
        }
    }

    /// Move a stage's content area as the stage moves or resizes, and make its front window follow. Moves are
    /// coalesced: while one is under way only the latest frame is kept, so the window follows as fast as its
    /// application allows without falling behind.
    ///
    /// - Parameters:
    ///   - stageId: the stage
    ///   - contentFrame: the new content area, in window-server coordinates
    func relayoutStage(_ stageId: StageId, contentFrame: CGRect) {
        guard mapStageContentFrames[stageId] != nil else {
            return
        }
        mapStageContentFrames[stageId] = contentFrame
        mapPendingStageFrames[stageId] = contentFrame
        guard !setFollowingStageIds.contains(stageId) else {
            return
        }
        setFollowingStageIds.insert(stageId)
        Task {
            while let frame = self.mapPendingStageFrames.removeValue(forKey: stageId) {
                guard let windowId = self.group(onStage: stageId)?.listMembersFrontToBack.first?.windowId else {
                    break
                }
                await self.tracker.applyFrame(frame, to: windowId)
            }
            self.setFollowingStageIds.remove(stageId)
        }
    }

    /// Close one stage: the windows of its groups go back where they were before the stage took them over,
    /// and its groups are kept for the next stage to open.
    func exitStage(_ stageId: StageId) async {
        await enqueue {
            guard self.mapStageContentFrames.removeValue(forKey: stageId) != nil else {
                return
            }
            self.mapStageGroupIds[stageId] = nil
            let listOwnGroups = self.groups(ofStage: stageId)
            for group in listOwnGroups {
                self.mapGroupStageIds[group.groupId] = nil
            }
            guard !self.mapStageContentFrames.isEmpty else {
                await self.restoreAllWindows()
                return
            }
            await self.restore(listOwnGroups.flatMap(\.listMembers))
            self.activateShownGroups()
            self.didChange()
        }
    }

    /// Close every stage, putting every window back where it was before the stages took it over.
    func exitAllStages() async {
        await enqueue {
            await self.restoreAllWindows()
        }
    }

    /// Move a managed window to another group.
    func move(_ windowId: WindowId, to groupId: GroupId) {
        guard let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) else {
            return
        }
        workspace.adopt(window, into: groupId)
        didChange()
    }

    /// Stop managing a window, first putting it back where it belongs: its place before the stage, or
    /// before MuxShots hid it.
    func release(_ windowId: WindowId) {
        let homeFrame = workspace.markUnstaged(windowId)
        let restoreFrame = workspace.markShown(windowId)
        let groupId = workspace.group(containing: windowId)?.groupId
        guard workspace.release(windowId) else {
            return
        }
        didChange()
        Task { [tracker] in
            if let frame = homeFrame ?? restoreFrame {
                await tracker.applyFrame(frame, to: windowId)
            }
            await tracker.release(windowId)
            if let groupId, let stageId = self.stage(showing: groupId) {
                await self.switchTo(groupId, onStage: stageId)
            }
        }
    }

    /// Show one group and hide every other group's windows, or with nil show every managed window and leave
    /// group mode. Switches run one after another in the order requested.
    ///
    /// - Parameters:
    ///   - groupId: the group to show, or nil for every managed window, which also closes every stage
    ///   - frontWindowId: a member to put in front of the group's other windows
    ///   - stageId: with stages open, the stage to show the group on; by default the one already showing
    ///     it, else the one under the cursor
    func switchTo(_ groupId: GroupId?, bringingToFront frontWindowId: WindowId? = nil, onStage stageId: StageId? = nil) async {
        switchRequestCount += 1
        await enqueue {
            await self.performSwitch(to: groupId, bringingToFront: frontWindowId, onStage: stageId)
        }
    }

    /// Run a layout change after the ones already requested.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previousTask = switchTask
        let startupTask = startupTask
        applicationHidingTask?.cancel()
        let task = Task {
            await startupTask?.value
            await previousTask?.value
            isSwitching = true
            await work()
            isSwitching = false
            if isChangePending {
                isChangePending = false
                onChange?()
            }
            focusQuietUntil = ContinuousClock.now + Self.focusQuietPeriod
            focusReclaimUntil = ContinuousClock.now + Self.focusReclaimPeriod
            scheduleApplicationHiding()
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
            scheduleApplicationHiding()
        case .show:
            try await show(windowId)
        case .maximize:
            try await maximize(windowId)
        }
    }

    /// Put every window back where it belongs (its place before the stage, or before MuxShots hid it) and
    /// leave group mode, as the stage closes and as MuxShots launches or quits.
    func restoreAllWindows() async {
        mapStageContentFrames.removeAll()
        mapStageGroupIds.removeAll()
        mapGroupStageIds.removeAll()
        await restore(workspace.listManagedWindows)
        workspace.deactivateAll()
        didChange()
    }

    /// Put windows back where they belong off the stage and on screen.
    private func restore(_ listWindows: [ManagedWindow]) async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for window in listWindows where window.homeFrame != nil || window.isHidden {
                let homeFrame = workspace.markUnstaged(window.windowId)
                let restoreFrame = workspace.markShown(window.windowId)
                guard let frame = homeFrame ?? restoreFrame else {
                    continue
                }
                revealApplication(of: window.windowId)
                taskGroup.addTask {
                    _ = await self.applyShownFrame(frame, to: window.windowId)
                }
            }
        }
    }

    func rename(_ groupId: GroupId, to name: String) {
        workspace.rename(groupId, to: name)
        didChange()
    }

    /// Give a window a name of its own, or with a blank name go back to its title.
    func rename(window windowId: WindowId, to name: String) {
        workspace.rename(window: windowId, to: name)
        didChange()
    }

    /// Move a managed window to a group, or to a new group with nil, laying out the stages afterwards.
    ///
    /// - Parameter stageId: the stage the move happened on, which shows a group the move creates
    func moveWindow(_ windowId: WindowId, to groupId: GroupId?, onStage stageId: StageId? = nil) {
        guard let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) else {
            return
        }
        adopt(windowId, processId: window.application.processId, into: groupId, onStage: stageId)
    }

    /// Move a group to just before another, or to the end with nil.
    func moveGroup(_ groupId: GroupId, before targetGroupId: GroupId?) {
        workspace.moveGroup(groupId, before: targetGroupId)
        didChange()
    }

    /// Move a tab to just before another tab of its group, or to the end with nil.
    func moveTab(_ windowId: WindowId, before targetWindowId: WindowId?) {
        workspace.moveMember(windowId, before: targetWindowId)
        didChange()
    }

    /// Give keyboard focus back to the stage's front window, as after editing a name on the stage.
    func focusStageFront() {
        if let stageId = focusedStageId() {
            focusFront(ofStage: stageId)
        }
    }

    /// Bring a stage's front window forward with keyboard focus, keeping the stage just beneath it. A switch
    /// asked for meanwhile, as by the click that called this, focuses the window it switches to instead:
    /// focusing the one it switches away from too leaves some applications focusing that one.
    func focusFront(ofStage stageId: StageId) {
        let requestCount = switchRequestCount
        Task {
            do {
                try await Task.sleep(for: Self.clickActionDelay)
            } catch {
                return
            }
            guard switchRequestCount == requestCount else {
                return
            }
            await enqueue {
                guard let windowId = self.group(onStage: stageId)?.listMembersFrontToBack.first?.windowId else {
                    return
                }
                try? await self.focus(windowId)
                self.stageCoordinator?.keepStage(stageId, beneath: windowId)
            }
        }
    }

    /// Make the stages' coordinator, whose stages share the drop animation with the tray.
    func makeStageCoordinator(
        mixerController: MixerController,
        agentUsageMonitor: AgentUsageMonitor,
        quickNotes: QuickNotes
    ) -> StageCoordinator {
        let coordinator = StageCoordinator(
            workspaceController: self,
            preferences: preferences,
            mixerController: mixerController,
            agentUsageMonitor: agentUsageMonitor,
            quickNotes: quickNotes,
            ghostAnimator: ghostAnimator
        )
        stageCoordinator = coordinator
        return coordinator
    }

    /// Make a panel that shares the drop animation with the tray.
    func makePanel() -> WorkspacePanelController {
        let panel = WorkspacePanelController(controller: self, ghostAnimator: ghostAnimator)
        self.panel = panel
        return panel
    }

    func windowDragBegan(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        if let stageId = stageShowing(windowId: drag.windowId) {
            stageCoordinator?.beginFollowing(stageId, windowDrag: drag, at: cursorLocation)
        }
        guard preferences.isDropTrayEnabled else {
            return
        }
        let surface: DropSurface = if isStageOpen, let stageCoordinator {
            stageCoordinator
        } else if let panel, panel.isShowing {
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
        stageCoordinator?.follow(to: cursorLocation)
        activeSurface?.updateWindowDrag(at: cursorLocation)
    }

    func windowDragEnded(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        guard let surface = activeSurface else {
            stageCoordinator?.endFollowing(isReturning: false)
            return
        }
        activeSurface = nil
        guard let target = surface.target(at: cursorLocation) else {
            surface.cancelWindowDrag()
            stageCoordinator?.endFollowing(isReturning: false)
            return
        }
        stageCoordinator?.endFollowing(isReturning: true)
        let isStageDrop = isStageOpen && surface === stageCoordinator
        let dropStageId = isStageDrop ? stageCoordinator?.stageId(at: cursorLocation) : nil
        guard !workspace.isManaged(drag.windowId) else {
            completeDrop(drag, on: target, of: surface, isStageDrop: isStageDrop, stageId: dropStageId)
            return
        }
        Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard WindowServer.window(withId: drag.windowId) != nil else {
                surface.cancelWindowDrag()
                return
            }
            completeDrop(drag, on: target, of: surface, isStageDrop: isStageDrop, stageId: dropStageId)
        }
    }

    /// Hand a dropped window to MuxShots, or release it, and animate it into its target. A window not yet
    /// managed is only taken once it has outlived its drop, since an application may merge it away, as
    /// Chrome does with a tab dragged into another of its windows.
    private func completeDrop(
        _ drag: WindowDrag,
        on target: DropTarget,
        of surface: DropSurface,
        isStageDrop: Bool,
        stageId dropStageId: StageId?
    ) {
        let droppedFrame = WindowServer.window(withId: drag.windowId).map { ScreenGeometry.appKitFrame(fromWindowServer: $0.frame) }
        let icon = NSRunningApplication(processIdentifier: drag.processId)?.icon
        let homeFrame = isStageDrop ? drag.startFrame : nil
        let landedGroupId: GroupId? = switch target {
        case .group(let groupId):
            adopt(drag.windowId, processId: drag.processId, into: groupId, homeFrame: homeFrame, onStage: dropStageId)
        case .newGroup:
            adopt(drag.windowId, processId: drag.processId, into: nil, homeFrame: homeFrame, onStage: dropStageId)
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
        let isReturning = preferences.isReturningDroppedWindows && !isStageDrop
        Task { [tracker] in
            try? await Task.sleep(for: Self.settleDelay)
            if isReturning || (target == .release && !isStageDrop) {
                await tracker.applyFrame(drag.startFrame, to: drag.windowId)
            }
            if target == .release {
                self.release(drag.windowId)
            }
        }
    }

    /// The stage whose front window a window is, if it is one.
    func stageShowing(windowId: WindowId) -> StageId? {
        mapStageGroupIds.first { stageId, _ in
            group(onStage: stageId)?.listMembersFrontToBack.first?.windowId == windowId
        }?.key
    }

    /// Whether the user is working on the stage: it is open and in front is either MuxShots or the
    /// application of the stage's front window.
    var isStageFocused: Bool {
        guard
            isStageOpen,
            let frontmostProcessId = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else {
            return false
        }
        let setStageProcessIds = Set(mapStageGroupIds.keys.compactMap { stageId in
            group(onStage: stageId)?.listMembersFrontToBack.first?.application.processId
        })
        return frontmostProcessId == ProcessInfo.processInfo.processIdentifier || setStageProcessIds.contains(frontmostProcessId)
    }

    /// Every managed window, the most recently used first.
    var listRecentWindows: [ManagedWindow] {
        let listWindows = workspace.listManagedWindows
        let mapWindows = Dictionary(listWindows.map { ($0.windowId, $0) }) { first, _ in first }
        let listRecent = listRecentWindowIds.compactMap { mapWindows[$0] }
        let setRecentIds = Set(listRecent.map(\.windowId))
        return listRecent + listWindows.filter { !setRecentIds.contains($0.windowId) }
    }

    /// The group switcher's offer: every group, then every window shown at once.
    /// The groups the group shortcuts and switcher offer: with stages open, those of the stage the user is
    /// working on; otherwise every group.
    var listSwitchableGroups: [WindowGroup] {
        guard isStageOpen, let stageId = focusedStageId() else {
            return workspace.listGroups
        }
        return groups(ofStage: stageId)
    }

    /// The frame of the stage the user is working on, in AppKit screen coordinates, for the switchers to fit.
    private var focusedStageFrame: CGRect? {
        guard isStageOpen, let stageId = focusedStageId() else {
            return nil
        }
        return stageCoordinator?.frame(ofStage: stageId)
    }

    func groupSwitcherRequest() -> SwitcherRequest? {
        let listGroups = listSwitchableGroups
        guard !listGroups.isEmpty else {
            return nil
        }
        let currentGroupId = frontmostActiveGroup()?.groupId
        let listEntries = listGroups.map { group in
            SwitcherEntry(
                id: group.groupId.rawValue,
                title: group.name,
                subtitle: group.listMembers.count == 1 ? "1 window" : "\(group.listMembers.count) windows",
                listBundleIds: group.listMembersFrontToBack.map(\.application.bundleId),
                symbolName: nil,
                isActive: workspace.isActive(group.groupId)
            )
        } + [SwitcherEntry(
            id: "all",
            title: "All Windows",
            subtitle: isStageOpen ? "close the stages" : "show everything",
            listBundleIds: [],
            symbolName: "square.grid.2x2",
            isActive: false
        )]
        let currentIndex = listEntries.firstIndex { $0.id == currentGroupId?.rawValue } ?? listEntries.count - 1
        return SwitcherRequest(listEntries: listEntries, currentIndex: currentIndex, fitFrame: focusedStageFrame) { [weak self] entry in
            let groupId = entry.id == "all" ? nil : GroupId(rawValue: entry.id)
            Task {
                await self?.switchTo(groupId)
            }
        }
    }

    /// The window switcher's offer: every managed window across groups, the most recently used first, as
    /// Cmd-Tab offers applications.
    func windowSwitcherRequest() -> SwitcherRequest? {
        let listWindows = listRecentWindows
        guard listWindows.count > 1 else {
            return nil
        }
        let listEntries = listWindows.map { window in
            SwitcherEntry(
                id: String(window.windowId.rawValue),
                title: window.displayName,
                subtitle: workspace.group(containing: window.windowId)?.name ?? "",
                listBundleIds: [window.application.bundleId],
                symbolName: nil,
                isActive: false
            )
        }
        return SwitcherRequest(listEntries: listEntries, currentIndex: 0, fitFrame: focusedStageFrame) { [weak self] entry in
            guard
                let self,
                let rawId = UInt32(entry.id),
                let groupId = workspace.group(containing: WindowId(rawValue: rawId))?.groupId
            else {
                return
            }
            Task {
                await self.switchTo(groupId, bringingToFront: WindowId(rawValue: rawId))
            }
        }
    }

    private func noteRecentlyUsed(_ windowId: WindowId) {
        listRecentWindowIds.removeAll { $0 == windowId }
        listRecentWindowIds.insert(windowId, at: 0)
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
        if let stageId = stage(showing: group.groupId) {
            let frontId = group.listMembersFrontToBack.first?.windowId
            let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? -1
            let nextId = group.listMembers[(frontIndex + 1) % group.listMembers.count].windowId
            await switchTo(group.groupId, bringingToFront: nextId, onStage: stageId)
            return
        }
        let listServerOrder = WindowServer.listWindows().map(\.windowId)
        let frontId = listServerOrder.first { windowId in group.listMembers.contains { $0.windowId == windowId } }
        let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? -1
        try? await focus(group.listMembers[(frontIndex + 1) % group.listMembers.count].windowId)
    }

    /// Follow the user to a hidden window they focused, through Cmd-Tab, the Dock or a notification, by
    /// switching to its group. Applications can report a focus change late, after a switch has hidden the
    /// window, so the switch waits until the application confirms the window still has focus.
    private func handleFocus(of windowId: WindowId) {
        if workspace.isManaged(windowId) && !workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            noteRecentlyUsed(windowId)
            if let stageId = stageShowing(windowId: windowId) {
                stageCoordinator?.keepStage(stageId, beneath: windowId)
            }
        }
        guard
            !isSwitching,
            ContinuousClock.now >= focusQuietUntil,
            workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }),
            let group = workspace.group(containing: windowId)
        else {
            return
        }
        Task {
            do {
                try await Task.sleep(for: Self.focusSettleDelay)
            } catch {
                return
            }
            guard
                let processId = await tracker.processId(of: windowId),
                await tracker.focusedWindowId(ofProcess: processId) == windowId,
                !isSwitching,
                workspace.listHiddenWindows.contains(where: { $0.windowId == windowId })
            else {
                return
            }
            if
                let broughtForwardWindowId,
                ContinuousClock.now < focusReclaimUntil,
                await tracker.processId(of: broughtForwardWindowId) == processId
            {
                Self.logger.info("""
                    focus went to hidden window \(windowId.rawValue) right after \(broughtForwardWindowId.rawValue) \
                    of the same application came forward; taking it back
                    """)
                _ = await tracker.raise(broughtForwardWindowId)
                return
            }
            Self.logger.info("hidden window \(windowId.rawValue) took focus; switching to it")
            await switchTo(group.groupId, bringingToFront: windowId)
        }
    }

    private func performSwitch(to groupId: GroupId?, bringingToFront frontWindowId: WindowId?, onStage stageId: StageId?) async {
        if isStageOpen {
            guard let groupId else {
                await restoreAllWindows()
                return
            }
            if mapGroupStageIds[groupId] == nil, let assignedStageId = stageId ?? focusedStageId() {
                mapGroupStageIds[groupId] = assignedStageId
            }
            guard let targetStageId = mapGroupStageIds[groupId] else {
                return
            }
            await performStageSwitch(to: groupId, on: targetStageId, bringingToFront: frontWindowId)
            return
        }
        let startTime = ContinuousClock.now
        let listServerOrder = WindowServer.listWindows().map(\.windowId)
        for group in workspace.listActiveGroups {
            workspace.recordStack(of: group.groupId, frontToBack: listServerOrder)
        }
        let mapRecords = Dictionary(uniqueKeysWithValues: await tracker.listWindows().map { ($0.windowId, $0) })
        let displayIndex = { (window: ManagedWindow) -> Int? in
            (window.restoreFrame ?? mapRecords[window.windowId]?.frame).flatMap(ScreenGeometry.displayIndex(containing:))
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
        broughtForwardWindowId = listVisible.first?.windowId
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

    /// Show a group on a stage, its front tab unless another is asked for filling the content area, and hide
    /// every managed window no stage shows. A group already on another stage trades places with the group
    /// this stage showed.
    private func performStageSwitch(to groupId: GroupId, on stageId: StageId, bringingToFront frontWindowId: WindowId?) async {
        let startTime = ContinuousClock.now
        guard
            mapStageContentFrames[stageId] != nil,
            let targetGroup = workspace.listGroups.first(where: { $0.groupId == groupId })
        else {
            return
        }
        mapStageGroupIds[stageId] = groupId
        if let frontWindowId, targetGroup.listMembers.contains(where: { $0.windowId == frontWindowId }) {
            workspace.bringToFront(frontWindowId)
        }

        let mapRecords = Dictionary(uniqueKeysWithValues: await tracker.listWindows().map { ($0.windowId, $0) })
        var mapShownFrames: [WindowId: CGRect] = [:]
        for (shownStageId, shownGroupId) in mapStageGroupIds {
            guard
                let contentFrame = mapStageContentFrames[shownStageId],
                let group = workspace.listGroups.first(where: { $0.groupId == shownGroupId }),
                let front = group.listMembersFrontToBack.first(where: { mapRecords[$0.windowId]?.isMinimized != true })
            else {
                continue
            }
            mapShownFrames[front.windowId] = contentFrame
        }
        let setStagedGroupIds = Set(mapGroupStageIds.keys)
        let listToHide = workspace.listGroups
            .filter { setStagedGroupIds.contains($0.groupId) }
            .flatMap(\.listMembers)
            .filter { window in
                mapShownFrames[window.windowId] == nil
                    && !window.isHidden
                    && mapRecords[window.windowId]?.isMinimized != true
            }
        for (windowId, contentFrame) in mapShownFrames {
            revealApplication(of: windowId)
            let restoreFrame = workspace.markShown(windowId)
            guard await applyShownFrame(contentFrame, to: windowId) == nil else {
                continue
            }
            Self.logger.error("cannot show \(windowId.rawValue) on its stage")
            if let restoreFrame {
                workspace.markHidden(windowId, restoreFrame: restoreFrame)
            }
        }

        if let selected = group(onStage: stageId)?.listMembersFrontToBack.first(where: { mapShownFrames[$0.windowId] != nil }) {
            noteRecentlyUsed(selected.windowId)
            broughtForwardWindowId = selected.windowId
            _ = await tracker.raise(selected.windowId)
            if let processId = await tracker.processId(of: selected.windowId) {
                NSRunningApplication(processIdentifier: processId)?.activate()
            }
            stageCoordinator?.keepStage(stageId, beneath: selected.windowId)
        }
        await run(showing: [], hiding: listToHide)
        activateShownGroups()
        didChange()
        Self.logger.info("""
            staged \(targetGroup.name, privacy: .public) on one of \(self.mapStageContentFrames.count) stages: hid \
            \(listToHide.count) in \(ContinuousClock.now - startTime, privacy: .public)
            """)
    }

    /// Make the active groups exactly the ones the stages show.
    private func activateShownGroups() {
        workspace.deactivateAll()
        for groupId in mapStageGroupIds.values {
            workspace.activate(groupId, displacing: [])
        }
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
        broughtForwardWindowId = windowId
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
        guard let frame = await tracker.frame(of: windowId) else {
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
        revealApplication(of: windowId)
        guard let restoreFrame = workspace.markShown(windowId) else {
            throw WindowActionError.notHidden(windowId: windowId)
        }
        didChange()
        guard let landedFrame = await applyShownFrame(restoreFrame, to: windowId) else {
            workspace.markHidden(windowId, restoreFrame: restoreFrame)
            didChange()
            throw WindowActionError.cannotMove(windowId: windowId)
        }
        Self.logger.info("""
            showed \(windowId.rawValue) at \(String(describing: restoreFrame), privacy: .public), \
            landed at \(String(describing: landedFrame), privacy: .public)
            """)
    }

    /// Move a window being shown into place. An application that ordered the window out while it was parked,
    /// as WeChat does, is asked to reopen, as a click on its Dock icon would, and the window is moved once it
    /// is back.
    ///
    /// - Returns: where the window landed, or nil if it could not be moved
    private func applyShownFrame(_ frame: CGRect, to windowId: WindowId) async -> CGRect? {
        if let landedFrame = await tracker.applyFrame(frame, to: windowId) {
            return landedFrame
        }
        guard
            WindowServer.window(withId: windowId)?.isOrderedIn != true,
            let processId = await tracker.processId(of: windowId),
            let bundleUrl = NSRunningApplication(processIdentifier: processId)?.bundleURL
        else {
            return nil
        }
        Self.logger.info("window \(windowId.rawValue) was ordered out by its application, which is asked to reopen")
        do {
            try await NSWorkspace.shared.openApplication(at: bundleUrl, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Self.logger.error("cannot reopen the application of window \(windowId.rawValue): \(error)")
            return nil
        }
        let deadline = ContinuousClock.now + Self.reopenTimeout
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.reopenPollInterval)
            } catch {
                return nil
            }
            if let landedFrame = await tracker.applyFrame(frame, to: windowId) {
                return landedFrame
            }
        }
        return nil
    }

    /// Put the stages back on a display and park again the hidden windows macOS moved on screen, once the
    /// displays have settled after a change: a display that comes, goes or wakes makes macOS move windows
    /// by itself, parked ones included, and moves the origin the window server's coordinates count from.
    private func displaysDidChange() {
        displayChangeTask?.cancel()
        displayChangeTask = Task {
            for delay in Self.listDisplaySettleDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                stageCoordinator?.settleStagesOnDisplays()
                await enqueue {
                    await self.reparkStrayWindows()
                }
            }
        }
    }

    /// Park again every hidden window that is back on screen.
    private func reparkStrayWindows() async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for window in workspace.listHiddenWindows {
                taskGroup.addTask {
                    await self.repark(window.windowId)
                }
            }
        }
    }

    private func repark(_ windowId: WindowId) async {
        guard
            let frame = await tracker.frame(of: windowId),
            ScreenGeometry.visibleShare(of: frame) > Self.hiddenVisibleShareLimit
        else {
            return
        }
        let requestedFrame = ScreenGeometry.offscreenFrame(for: frame)
        let parkedFrame = await tracker.applyFrame(requestedFrame, to: windowId)
        Self.logger.info("""
            parked \(windowId.rawValue) again from \(String(describing: frame), privacy: .public), landed at \
            \(String(describing: parkedFrame), privacy: .public)
            """)
    }

    /// Bring back a browser hidden before it started playing a video in the sidebar, and hide one whose
    /// last video closed if it has only hidden windows left.
    func picturesDidChange() {
        for processId in pictureProcessIds() {
            throttle.release(processId)
            guard
                let running = NSRunningApplication(processIdentifier: processId),
                running.isHidden
            else {
                continue
            }
            running.unhide()
        }
        scheduleApplicationHiding()
    }

    /// Hide the applications left with only hidden windows once layout settles; a later layout change
    /// cancels the wait.
    private func scheduleApplicationHiding() {
        applicationHidingTask?.cancel()
        applicationHidingTask = Task {
            do {
                try await Task.sleep(for: Self.applicationHidingDelay)
            } catch {
                return
            }
            hideApplicationsShowingOnlyHiddenWindows()
        }
    }

    /// Hide whole every application whose every window shown on some Space is one MuxShots hid, so it stops
    /// drawing windows nobody sees, and put it in the background, so what it goes on doing costs less power.
    /// Windows off every display do not count, as Chrome's link bubble left beside a parked window. The
    /// active application is left alone, as hiding it would hand activation to another.
    private func hideApplicationsShowingOnlyHiddenWindows() {
        let setCandidateIds = Set(workspace.listHiddenWindows.map(\.application.processId))
        guard !setCandidateIds.isEmpty else {
            return
        }
        let mapShownProcessIds = Dictionary(
            uniqueKeysWithValues: WindowServer.listShownWindows(ofProcesses: setCandidateIds)
                .filter { ScreenGeometry.visibleShare(of: $0.frame) > Self.hiddenVisibleShareLimit }
                .map { ($0.windowId, $0.processId) }
        )
        let setPictureProcessIds = pictureProcessIds()
        let setPlayingBundleIds = playingBundleIds()
        for processId in workspace.processIdsShowingOnlyHiddenWindows(among: mapShownProcessIds) {
            guard
                !setPictureProcessIds.contains(processId),
                let running = NSRunningApplication(processIdentifier: processId),
                !running.isActive
            else {
                continue
            }
            if !running.isHidden {
                guard running.hide() else {
                    continue
                }
                Self.logger.info("hid \(running.localizedName ?? "", privacy: .public), whose windows are all hidden")
            }
            if !setPlayingBundleIds.contains(running.bundleIdentifier ?? "") {
                throttle.throttle(processId)
            }
        }
    }

    /// Bring back the application of a window about to be shown, if it is hidden, and put it back to normal.
    private func revealApplication(of windowId: WindowId) {
        guard
            let window = workspace.group(containing: windowId)?.listMembers.first(where: { $0.windowId == windowId })
        else {
            return
        }
        throttle.release(window.application.processId)
        guard
            let running = NSRunningApplication(processIdentifier: window.application.processId),
            running.isHidden
        else {
            return
        }
        running.unhide()
    }

    private func maximize(_ windowId: WindowId) async throws {
        if workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            try await show(windowId)
        }
        try await leaveFullscreen(windowId)
        guard
            let frame = await tracker.frame(of: windowId),
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
            if workspace.updateTitle(of: window.windowId, to: window.title) {
                onWindowTitleChange?(window.windowId)
            }
        case .removed(let windowId):
            let groupId = workspace.group(containing: windowId)?.groupId
            let stageId = groupId.flatMap(stage(showing:))
            if workspace.release(windowId) {
                didChange()
                if let groupId, let stageId {
                    Task {
                        await switchTo(groupId, onStage: stageId)
                    }
                }
            }
        }
    }

    /// Where a window belongs when it is shown: its place before MuxShots hid it, or where it is now.
    private func currentOrRestoreFrame(of window: ManagedWindow) async -> CGRect? {
        if let restoreFrame = window.restoreFrame {
            return restoreFrame
        }
        return await tracker.frame(of: window.windowId)
    }

    /// The running application that owns a saved window, or nil if the window is gone or its identifier now
    /// belongs to another application's window. A window its application ordered out is not gone.
    private func liveApplication(
        of window: ManagedWindow,
        among mapServerWindows: [WindowId: WindowServerWindow]
    ) -> RunningApplication? {
        guard
            let serverWindow = mapServerWindows[window.windowId],
            let application = ApplicationMonitor.application(processId: serverWindow.processId),
            application.bundleId == window.application.bundleId
        else {
            return nil
        }
        return application
    }

    private func didChange() {
        save()
        guard !isSwitching else {
            isChangePending = true
            return
        }
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
