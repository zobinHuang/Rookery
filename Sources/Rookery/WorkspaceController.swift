import AppKit
import os
import RookeryCore
import RookeryPlatform

/// Owns the workspace: turns drops on the tray, the panel and the stage into managed windows and groups,
/// keeps the tracker following exactly the managed windows, lays them out while the stage is open, and
/// persists the result.
@MainActor
final class WorkspaceController: WindowDragMonitorDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "workspace")
    /// Lets the dragged application finish its own drag before the window is moved back.
    private static let settleDelay = Duration.milliseconds(120)
    private static let fullscreenPollInterval = Duration.milliseconds(100)
    private static let fullscreenExitTimeout = Duration.seconds(3)
    /// The Space transition keeps animating briefly after the window reports leaving full screen.
    private static let fullscreenSettleDelay = Duration.milliseconds(400)
    /// A hidden window may keep at most this share of itself on screen.
    private static let hiddenVisibleShareLimit: CGFloat = 0.02
    /// How long after a switch a hidden window that takes focus is taken as the switch's leftover, the
    /// application switched away from or the one switched to activating late, and focus is taken back to the
    /// window the switch brought forward rather than followed.
    private static let focusReclaimPeriod = Duration.milliseconds(1500)
    /// How long after a switch it checks that the application in front is not focusing a hidden window, as
    /// focus changes during the switch are not followed.
    private static let focusConfirmDelay = Duration.milliseconds(300)
    /// How long a hidden window must keep focus before it counts as chosen: focus passes through other
    /// windows while an application activates.
    private static let focusSettleDelay = Duration.milliseconds(150)
    /// Applications left with only hidden windows are hidden this long after the last layout change, once
    /// the application being switched to has taken over activation.
    private static let applicationHidingDelay = Duration.milliseconds(500)
    /// How often the applications left with only hidden windows are looked for again, for those that show
    /// themselves or close their last other window without any layout change.
    private static let applicationSweepInterval = Duration.seconds(30)
    /// How long bringing a stage's front window forward waits for the click that asked for it to start a
    /// switch of its own.
    private static let clickActionDelay = Duration.milliseconds(50)
    /// How often, and for how long, a window its application was asked to reopen is looked for again.
    private static let reopenPollInterval = Duration.milliseconds(100)
    private static let reopenTimeout = Duration.seconds(2)
    /// How often, and for how long, an application asked to unhide is checked until it is shown.
    private static let unhidePollInterval = Duration.milliseconds(10)
    /// How long an application asked to unhide is waited on, and again after it is activated when the ask
    /// was not enough, as for Telegram, which ignored an unhide for over half a second.
    private static let unhideTimeout = Duration.seconds(2)
    /// When, after displays change or wake, to put the stages back on a display and minimize again the
    /// hidden windows: macOS goes on moving windows for a few seconds after the change.
    private static let listDisplaySettleDelays = [Duration.seconds(1), Duration.seconds(4)]
    /// How far a managed window may be from where its stage keeps it and still count as there.
    private static let placementTolerance: CGFloat = 2
    /// How long a window brought forward must hold still on screen to be checked where it is drawn: longer
    /// than Telegram takes to move its window back once it shows.
    private static let stillDuration = Duration.milliseconds(800)
    private static let stillTimeout = Duration.seconds(4)
    private static let stillPollInterval = Duration.milliseconds(60)
    /// How many times a window that will not stay is placed again before it is left.
    private static let placementAttempts = 3
    /// How often putting back a displaced window checks whether the mouse is up and layout is idle.
    private static let putBackPollInterval = Duration.milliseconds(100)

    private(set) var workspace: Workspace
    /// The area each open stage's front window fills, in window-server coordinates.
    private var mapStageContentFrames: [StageId: CGRect] = [:]
    /// The background watch that keeps the latest window brought forward where it was placed.
    private var placementTask: Task<Void, Never>?
    /// The group each open stage shows; a stage with no group shows nothing.
    private var mapStageGroupIds: [StageId: GroupId] = [:]
    /// The stage each group belongs to; a group in no stage is left where it is.
    private var mapGroupStageIds: [GroupId: StageId] = [:]
    /// Stages whose front window is being moved to follow them, and where it should end up next.
    private var mapPendingStageFrames: [StageId: CGRect] = [:]
    private var setFollowingStageIds: Set<StageId> = []
    /// Managed windows something other than Rookery moved or resized, to put back once the mouse is up.
    private var setDisplacedIds: Set<WindowId> = []
    private var putBackTask: Task<Void, Never>?
    /// Where windows that cannot take their stage's content area landed instead, so that they are not
    /// moved again and again.
    private var mapUnfitFrames: [WindowId: CGRect] = [:]
    private var isWindowDragActive = false
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
    private var applicationSweepTask: Task<Void, Never>?
    /// The applications Rookery hid, which tells one that showed itself again from one never hidden.
    private var setHiddenProcessIds: Set<pid_t> = []
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var listWakeObservers: [NSObjectProtocol] = []
    private var displayChangeTask: Task<Void, Never>?
    private var isSwitching = false
    /// How many switches have been asked for, which tells whether one was asked for in the meantime.
    private var switchRequestCount = 0
    /// The window the latest switch asked for brings to the front, until it is done, so stepping through
    /// a group's windows faster than they come forward steps on from the one asked for.
    private(set) var pendingFrontWindowId: WindowId?
    /// Counts the switches asked for, so one still waiting its turn when a later one is asked for is
    /// skipped: stepping through windows quickly lands on the last without bringing each one forward.
    private var latestSwitchNumber = 0
    /// Whether the workspace changed during the running layout change, which tells the views once when it
    /// ends rather than once for every window it moves.
    private var isChangePending = false
    /// The windows and pages the user went to, the most recent first, as window switcher entry ids.
    private var recentPlaces = RecentPlaces()
    /// The page the stage the user works on shows, if any, which is where the user is.
    var shownPage: @MainActor () -> StagePage? = { nil }
    /// The pages the window switcher offers beside the windows: the Rookmaster console and each live
    /// agent's page.
    var pageEntries: @MainActor () -> [SwitcherEntry] = { [] }
    /// Show a page the window switcher chose, on the stage the user works on.
    var onOpenPage: @MainActor (StagePage) -> Void = { _ in }
    /// The window the latest layout change brought forward, which focus a hidden window takes is given back
    /// to until `focusReclaimUntil`.
    private var broughtForwardWindowId: WindowId?
    private var focusReclaimUntil = ContinuousClock.now
    private var focusConfirmTask: Task<Void, Never>?

    /// Called after a structural or user initiated workspace change.
    var onChange: (() -> Void)?
    /// Told the group a switch is bringing forward, and the window it brings to the front if it names
    /// one, as soon as it is asked for, and nil once the last switch asked for is done, so a stage can show
    /// the switch under way before its windows are in place.
    var onSwitchTarget: ((GroupId?, WindowId?) -> Void)?
    /// Called when a managed window's displayed title changes, without changing workspace structure.
    var onWindowTitleChange: ((WindowId) -> Void)?
    /// The browsers playing a video in the sidebar, which are never hidden: a hidden browser stops drawing
    /// the page the video streams from.
    var pictureProcessIds: () -> Set<pid_t> = { [] }
    private let throttle = ApplicationThrottle()
    private var unhideObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?

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
                self?.scheduleApplicationHiding()
            }
        }
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleApplicationHiding()
            }
        }
        applicationSweepTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.applicationSweepInterval)
                } catch {
                    return
                }
                hideApplicationsShowingOnlyHiddenWindows()
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
        focusConfirmTask?.cancel()
        dragMonitor.stop()
        changeTask?.cancel()
        focusTask?.cancel()
        applicationHidingTask?.cancel()
        applicationSweepTask?.cancel()
        displayChangeTask?.cancel()
        placementTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let unhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unhideObserver)
        }
        if let deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver)
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
    /// before Rookery hid it.
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
        let requestCount = switchRequestCount
        latestSwitchNumber += 1
        let switchNumber = latestSwitchNumber
        pendingFrontWindowId = frontWindowId
        if let groupId {
            onSwitchTarget?(groupId, frontWindowId)
        }
        await enqueue {
            guard self.latestSwitchNumber == switchNumber else {
                Self.logger.info("skipped a switch overtaken by a later one")
                return
            }
            await self.performSwitch(to: groupId, bringingToFront: frontWindowId, onStage: stageId)
        }
        if switchRequestCount == requestCount {
            pendingFrontWindowId = nil
            onSwitchTarget?(nil, nil)
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
            focusReclaimUntil = ContinuousClock.now + Self.focusReclaimPeriod
            confirmFocusAfterSwitch()
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

    /// Put every window back where it belongs (its place before the stage, or before Rookery hid it) and
    /// leave group mode, as the stage closes and as Rookery launches or quits.
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
                taskGroup.addTask {
                    _ = await self.revealApplication(of: window.windowId)
                    _ = await self.applyShownFrame(frame, to: window.windowId, isRestoring: window.isHidden)
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
                guard
                    self.switchRequestCount == requestCount,
                    let windowId = self.group(onStage: stageId)?.listMembersFrontToBack.first?.windowId
                else {
                    return
                }
                try? await self.focus(windowId)
                self.stageCoordinator?.keepStage(stageId, beneath: windowId)
            }
        }
    }

    /// Drop the focus a click asked for and has not given yet, as when the click opened a page over the
    /// stage's front window: focusing that window would bring it back over the page.
    func cancelPendingFocus() {
        switchRequestCount += 1
    }

    /// Make the stages' coordinator, whose stages share the drop animation with the tray.
    func makeStageCoordinator(
        mixerController: MixerController,
        agentUsageMonitor: AgentUsageMonitor,
        fleetModel: FleetModel,
        shortcutRecorder: ShortcutRecorder
    ) -> StageCoordinator {
        let coordinator = StageCoordinator(
            workspaceController: self,
            preferences: preferences,
            mixerController: mixerController,
            agentUsageMonitor: agentUsageMonitor,
            fleetModel: fleetModel,
            ghostAnimator: ghostAnimator,
            shortcutRecorder: shortcutRecorder
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
        isWindowDragActive = true
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
        isWindowDragActive = false
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

    /// Hand a dropped window to Rookery, or release it, and animate it into its target. A window not yet
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

    /// Whether the user is working on the stage: it is open and in front is either Rookery or the
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
        return recentPlaces
            .ordered(listWindows.map { String($0.windowId.rawValue) }, current: nil)
            .compactMap { UInt32($0).flatMap { mapWindows[WindowId(rawValue: $0)] } }
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
            symbolName: .windows,
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

    /// The window switcher's offer: every managed window across groups and the pages beside them, the
    /// most recently used first, as Cmd-Tab offers applications.
    func windowSwitcherRequest() -> SwitcherRequest? {
        let listWindowEntries = listRecentWindows.map { window in
            SwitcherEntry(
                id: String(window.windowId.rawValue),
                title: window.application.name,
                subtitle: window.displayName,
                listBundleIds: [window.application.bundleId],
                symbolName: nil,
                isActive: false,
                tag: workspace.group(containing: window.windowId)?.name
            )
        }
        let listAll = listWindowEntries + pageEntries()
        guard listAll.count > 1 else {
            return nil
        }
        let mapEntries = Dictionary(listAll.map { ($0.id, $0) }) { first, _ in first }
        let currentId = currentPlaceId()
        if let currentId {
            recentPlaces.note(currentId)
        }
        recentPlaces.prune(keeping: Set(mapEntries.keys))
        let listEntries = recentPlaces.ordered(listAll.map(\.id), current: currentId).compactMap { mapEntries[$0] }
        return SwitcherRequest(listEntries: listEntries, currentIndex: 0, fitFrame: focusedStageFrame) { [weak self] entry in
            guard let self else {
                return
            }
            recentPlaces.note(entry.id)
            if let page = StagePage(switcherId: entry.id) {
                onOpenPage(page)
                return
            }
            guard
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

    /// Note that the user went to a page the window switcher offers.
    func notePageShown(_ page: StagePage) {
        if let switcherId = page.switcherId {
            notePlace(switcherId)
        }
    }

    private func notePlace(_ placeId: String) {
        recentPlaces.note(placeId)
    }

    /// Where the user is now, by its switcher id: the page their stage shows, else the window in front of
    /// it, else, with no stage open, the managed window in front.
    private func currentPlaceId() -> String? {
        if let switcherId = shownPage()?.switcherId {
            return switcherId
        }
        if isStageOpen {
            guard let stageId = focusedStageId(), let windowId = group(onStage: stageId)?.listMembersFrontToBack.first?.windowId else {
                return nil
            }
            return String(windowId.rawValue)
        }
        let setManagedIds = Set(workspace.listManagedWindows.map(\.windowId))
        return WindowServer.listWindows().map(\.windowId).first { setManagedIds.contains($0) }.map { String($0.rawValue) }
    }

    private func noteRecentlyUsed(_ windowId: WindowId) {
        notePlace(String(windowId.rawValue))
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
        await stepActiveGroupWindow(by: 1)
    }

    /// Bring forward the window some places after the one in front, or before it with a negative step, in
    /// the frontmost active group's join order, which is the order of its tabs, wrapping around.
    func stepActiveGroupWindow(by step: Int) async {
        guard let group = frontmostActiveGroup(), group.listMembers.count > 1 else {
            return
        }
        let count = group.listMembers.count
        if let stageId = stage(showing: group.groupId) {
            let frontId = pendingFrontWindowId ?? group.listMembersFrontToBack.first?.windowId
            let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? 0
            let nextId = group.listMembers[((frontIndex + step) % count + count) % count].windowId
            await switchTo(group.groupId, bringingToFront: nextId, onStage: stageId)
            return
        }
        let listServerOrder = WindowServer.listWindows().map(\.windowId)
        let frontId = listServerOrder.first { windowId in group.listMembers.contains { $0.windowId == windowId } }
        let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? 0
        try? await focus(group.listMembers[((frontIndex + step) % count + count) % count].windowId)
    }

    /// Whether a managed window belongs to the application in front, whose focus is the user's doing.
    private func isInFrontmostApplication(_ windowId: WindowId) -> Bool {
        guard
            let frontmostProcessId = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId })
        else {
            return false
        }
        return window.application.processId == frontmostProcessId
    }

    /// Follow the user to a hidden window they focused, through Cmd-Tab, the Dock or a notification, by
    /// switching to its group. Only the application in front counts: one behind it moving its own focus is
    /// not the user's choice. Applications can report a focus change late, after a switch has hidden the
    /// window, so the switch waits until the application confirms the window still has focus; within
    /// `focusReclaimPeriod` of a switch, focus is taken back instead.
    private func handleFocus(of windowId: WindowId) {
        if
            workspace.isManaged(windowId)
            && !workspace.listHiddenWindows.contains(where: { $0.windowId == windowId })
            && !isSwitching
            && isInFrontmostApplication(windowId)
            && (!isStageOpen || stageShowing(windowId: windowId) != nil)
        {
            noteRecentlyUsed(windowId)
            if let stageId = stageShowing(windowId: windowId) {
                stageCoordinator?.keepStage(stageId, beneath: windowId)
            }
        }
        guard
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
                !isSwitching,
                await isFocusedInFront(windowId)
            else {
                return
            }
            if let broughtForwardWindowId, ContinuousClock.now < focusReclaimUntil {
                guard windowId != broughtForwardWindowId else {
                    return
                }
                Self.logger.info("""
                    hidden window \(windowId.rawValue) took focus right after a switch; taking it back to \
                    \(broughtForwardWindowId.rawValue)
                    """)
                await bringForward(broughtForwardWindowId)
                return
            }
            Self.logger.info("hidden window \(windowId.rawValue) took focus; switching to it")
            await switchTo(group.groupId, bringingToFront: windowId)
        }
    }

    /// Whether a window is hidden and is the focused window of the application in front.
    private func isFocusedInFront(_ windowId: WindowId) async -> Bool {
        guard
            workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }),
            let processId = await tracker.processId(of: windowId),
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processId
        else {
            return false
        }
        return await tracker.focusedWindowId(ofProcess: processId) == windowId
    }

    /// Once a switch has settled, take focus back to the window it brought forward if the application in
    /// front is focusing a hidden window, as when the application switched away from activates after the
    /// one switched to. Focus changes during a switch are not followed, so this is the only check of them.
    private func confirmFocusAfterSwitch() {
        let requestCount = switchRequestCount
        focusConfirmTask?.cancel()
        focusConfirmTask = Task {
            do {
                try await Task.sleep(for: Self.focusConfirmDelay)
            } catch {
                return
            }
            guard
                switchRequestCount == requestCount,
                !isSwitching,
                let broughtForwardWindowId,
                let frontProcessId = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                let focusedWindowId = await tracker.focusedWindowId(ofProcess: frontProcessId),
                focusedWindowId != broughtForwardWindowId,
                await isFocusedInFront(focusedWindowId)
            else {
                return
            }
            Self.logger.info("""
                hidden window \(focusedWindowId.rawValue) has focus after a switch; taking it back to \
                \(broughtForwardWindowId.rawValue)
                """)
            await bringForward(broughtForwardWindowId)
        }
    }

    /// Raise a window and activate its application.
    /// Whether a window is the one its group shows on a stage: its group is on a stage and it is the
    /// group's front window.
    private func isShownOnStage(_ windowId: WindowId, in group: WindowGroup) -> Bool {
        guard
            let stageId = mapGroupStageIds[group.groupId],
            mapStageGroupIds[stageId] == group.groupId
        else {
            return false
        }
        return group.listMembersFrontToBack.first?.windowId == windowId
    }

    /// Keep a window brought forward drawn where it was placed, as the window server shows it rather than as
    /// its application reports it, in the background so the switch is not held up; a later one takes over.
    private func keepPlaced(_ windowId: WindowId, at frame: CGRect) {
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            await self?.settlePlacement(of: windowId, at: frame)
        }
    }

    /// Wait for a window to hold still on screen and place it again wherever that is not where it was put,
    /// until it holds still there. Telegram, back from the Dock, draws its window where it last was on
    /// screen while reporting the frame it was given meanwhile, takes that same frame again as no change,
    /// and some half a second after it shows moves its window back once more: so the window is placed only
    /// once it holds still, a point off and then right, and watched until it holds still in place. A window
    /// drawn at another size than it reports is warped, as Telegram's was by a minimize animation cut short;
    /// moving it shifts the warp along and nothing short of its application reopening it mends it.
    private func settlePlacement(of windowId: WindowId, at frame: CGRect) async {
        for attempt in 1...Self.placementAttempts {
            guard let stillFrame = await stillFrame(of: windowId) else {
                return
            }
            if Self.isFrame(stillFrame, closeTo: frame) {
                if attempt > 1 {
                    Self.logger.notice("window \(windowId.rawValue) holds still where it was placed")
                }
                return
            }
            Self.logger.notice("""
                window \(windowId.rawValue) holds still at \(String(describing: stillFrame), privacy: .public) though \
                placed at \(String(describing: frame), privacy: .public); placing it again (\(attempt))
                """)
            _ = await tracker.applyFrameAfresh(frame.offsetBy(dx: 1, dy: 1), to: windowId)
            _ = await tracker.applyFrame(frame, to: windowId)
        }
        if
            let reportedFrame = await tracker.frame(of: windowId),
            let drawnFrame = WindowServer.window(withId: windowId)?.frame,
            abs(reportedFrame.width - drawnFrame.width) > Self.placementTolerance
                || abs(reportedFrame.height - drawnFrame.height) > Self.placementTolerance
        {
            Self.logger.error("""
                window \(windowId.rawValue) is drawn warped, \(String(describing: drawnFrame), privacy: .public) for \
                \(String(describing: reportedFrame), privacy: .public), as a minimize animation cut short leaves it; \
                only its application reopening it mends it
                """)
            return
        }
        Self.logger.error("window \(windowId.rawValue) will not stay where it was placed")
    }

    /// Where the window server draws a window once it has held still on screen for `stillDuration`, or nil
    /// if it does not within `stillTimeout`, or the wait is cancelled.
    private func stillFrame(of windowId: WindowId) async -> CGRect? {
        let deadline = ContinuousClock.now + Self.stillTimeout
        var heldFrame: CGRect?
        var heldSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            if let window = WindowServer.window(withId: windowId), window.isOnScreen {
                if heldFrame != window.frame {
                    heldFrame = window.frame
                    heldSince = ContinuousClock.now
                } else if ContinuousClock.now - heldSince >= Self.stillDuration {
                    return window.frame
                }
            } else {
                heldFrame = nil
            }
            do {
                try await Task.sleep(for: Self.stillPollInterval)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func bringForward(_ windowId: WindowId) async {
        _ = await tracker.raise(windowId)
        if let processId = await tracker.processId(of: windowId) {
            NSRunningApplication(processIdentifier: processId)?.activate()
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

        let setShownIds = Set(listToShow.map(\.windowId))
        var listVisible = targetGroup.listMembersFrontToBack.filter { window in
            setShownIds.contains(window.windowId) || mapRecords[window.windowId]?.isMinimized != true
        }
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
                let front = group.listMembersFrontToBack.first(where: { $0.isHidden || mapRecords[$0.windowId]?.isMinimized != true })
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
            guard await revealApplication(of: windowId) else {
                Self.logger.error("cannot show \(windowId.rawValue) on its stage: its application stays hidden")
                continue
            }
            let restoreFrame = workspace.markShown(windowId)
            guard await applyShownFrame(contentFrame, to: windowId, isRestoring: restoreFrame != nil) == nil else {
                continue
            }
            Self.logger.error("cannot show \(windowId.rawValue) on its stage")
            if let restoreFrame {
                workspace.markHidden(windowId, restoreFrame: restoreFrame)
            }
        }

        if let selected = group(onStage: stageId)?.listMembersFrontToBack.first(where: { mapShownFrames[$0.windowId] != nil }) {
            // A window the user asked for counts as used; one a switch merely brought back counts once it has focus.
            if frontWindowId != nil {
                noteRecentlyUsed(selected.windowId)
            }
            broughtForwardWindowId = selected.windowId
            await bringForward(selected.windowId)
            if let contentFrame = mapShownFrames[selected.windowId] {
                keepPlaced(selected.windowId, at: contentFrame)
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
        if await !tracker.raise(windowId) {
            guard
                await reopenApplication(of: windowId),
                await retryWhileReopening({ await self.tracker.raise(windowId) })
            else {
                throw WindowActionError.cannotRaise(windowId: windowId)
            }
        }
        guard
            let processId = await tracker.processId(of: windowId),
            let running = NSRunningApplication(processIdentifier: processId)
        else {
            throw WindowActionError.cannotRaise(windowId: windowId)
        }
        running.activate()
        var placedFrame = stageShowing(windowId: windowId).flatMap { mapStageContentFrames[$0] }
        if placedFrame == nil {
            placedFrame = await tracker.frame(of: windowId)
        }
        if let placedFrame {
            keepPlaced(windowId, at: placedFrame)
        }
    }

    private func hide(_ windowId: WindowId) async throws {
        guard !workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) else {
            return
        }
        try await leaveFullscreen(windowId)
        guard let frame = await tracker.frame(of: windowId) else {
            throw WindowActionError.noDisplay(windowId: windowId)
        }
        guard await tracker.applyMinimized(true, to: windowId) else {
            throw WindowActionError.cannotMinimize(windowId: windowId)
        }
        Self.logger.info("hid \(windowId.rawValue) from \(String(describing: frame), privacy: .public)")
        workspace.markHidden(windowId, restoreFrame: frame)
        didChange()
    }

    private func show(_ windowId: WindowId) async throws {
        guard await revealApplication(of: windowId) else {
            throw WindowActionError.applicationHidden(windowId: windowId)
        }
        guard let restoreFrame = workspace.markShown(windowId) else {
            throw WindowActionError.notHidden(windowId: windowId)
        }
        didChange()
        guard let landedFrame = await applyShownFrame(restoreFrame, to: windowId, isRestoring: true) else {
            workspace.markHidden(windowId, restoreFrame: restoreFrame)
            didChange()
            throw WindowActionError.cannotMove(windowId: windowId)
        }
        Self.logger.info("""
            showed \(windowId.rawValue) at \(String(describing: restoreFrame), privacy: .public), \
            landed at \(String(describing: landedFrame), privacy: .public)
            """)
    }

    /// Move a window being shown into place and, if Rookery hid it, restore it from the Dock there: a
    /// minimized window takes a new frame, so it opens straight into place. An application that ordered the
    /// window out while it was hidden, as WeChat does, is asked to reopen, as a click on its Dock icon would,
    /// and the window is moved once it is back; unless Rookery holds other windows of it hidden, which a
    /// reopen would restore from the Dock in its place, as Chrome does.
    ///
    /// - Parameters:
    ///   - frame: where the window goes
    ///   - windowId: the window
    ///   - isRestoring: whether Rookery hid the window, so it is restored from the Dock; a window the user
    ///     minimized stays there
    /// - Returns: where the window landed, or nil if it could not be moved
    private func applyShownFrame(_ frame: CGRect, to windowId: WindowId, isRestoring: Bool) async -> CGRect? {
        if let landedFrame = await tracker.applyFrame(frame, to: windowId) {
            if isRestoring, !(await tracker.applyMinimized(false, to: windowId)) {
                Self.logger.error("cannot restore window \(windowId.rawValue) from the Dock")
            }
            return landedFrame
        }
        guard await reopenApplication(of: windowId) else {
            return nil
        }
        var landedFrame: CGRect?
        _ = await retryWhileReopening {
            landedFrame = await self.tracker.applyFrame(frame, to: windowId)
            return landedFrame != nil
        }
        if landedFrame != nil, isRestoring {
            _ = await tracker.applyMinimized(false, to: windowId)
        }
        return landedFrame
    }

    /// Ask the application of a window it ordered out to reopen, as a click on its Dock icon does, which
    /// shows the window again; unless Rookery holds other windows of it hidden, which a reopen would restore
    /// from the Dock in its place, as Chrome does.
    ///
    /// - Returns: whether the application was asked
    private func reopenApplication(of windowId: WindowId) async -> Bool {
        guard
            WindowServer.window(withId: windowId)?.isOrderedIn != true,
            let processId = await tracker.processId(of: windowId),
            let bundleUrl = NSRunningApplication(processIdentifier: processId)?.bundleURL
        else {
            return false
        }
        let hasHiddenSiblings = workspace.listHiddenWindows.contains { window in
            window.windowId != windowId && window.application.processId == processId
        }
        guard !hasHiddenSiblings else {
            Self.logger.info("""
                window \(windowId.rawValue) was ordered out by its application, which is not asked to reopen: \
                that would bring back one of its hidden windows instead
                """)
            return false
        }
        Self.logger.info("window \(windowId.rawValue) was ordered out by its application, which is asked to reopen")
        do {
            try await NSWorkspace.shared.openApplication(at: bundleUrl, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Self.logger.error("cannot reopen the application of window \(windowId.rawValue): \(error)")
            return false
        }
        return true
    }

    /// Try something on a window its application was asked to reopen until it works or `reopenTimeout`
    /// passes: the window is listed again only once the application has shown it.
    private func retryWhileReopening(_ attempt: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + Self.reopenTimeout
        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.reopenPollInterval)
            } catch {
                return false
            }
            if await attempt() {
                return true
            }
        }
        return false
    }

    /// Put the stages back on a display and minimize again any hidden window back from the Dock, once the
    /// displays have settled after a change: a display that comes, goes or wakes makes macOS move windows
    /// by itself, and moves the origin the window server's coordinates count from.
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
                    await self.minimizeStrayWindows()
                }
            }
        }
    }

    /// Minimize again every hidden window that is back from the Dock.
    private func minimizeStrayWindows() async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for window in workspace.listHiddenWindows {
                taskGroup.addTask {
                    await self.minimizeAgain(window.windowId)
                }
            }
        }
    }

    private func minimizeAgain(_ windowId: WindowId) async {
        guard !(await tracker.isMinimized(windowId)) else {
            return
        }
        let isMinimized = await tracker.applyMinimized(true, to: windowId)
        Self.logger.info("minimized hidden window \(windowId.rawValue) again: \(isMinimized, privacy: .public)")
    }

    /// Bring back a browser hidden before it started playing a video in the sidebar, and hide one whose
    /// last video closed if it has only hidden windows left.
    func picturesDidChange() {
        for processId in pictureProcessIds() {
            throttle.release(processId)
            setHiddenProcessIds.remove(processId)
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

    /// Hide whole every application with managed windows hidden whose other windows shown on some Space
    /// nobody sees, so it stops drawing them: windows off every display, as Chrome's link bubble, and windows
    /// wholly beneath a stage, as a WeChat chat left under it. An application whose windows are all minimized
    /// draws nothing and is left as it is, so showing one of them does not wait for it to unhide. It is not
    /// put in the background: its helpers starved there made the whole machine lag. The active application
    /// is left alone, as hiding it would hand activation to another.
    private func hideApplicationsShowingOnlyHiddenWindows() {
        releaseShownApplications()
        let setCandidateIds = Set(workspace.listHiddenWindows.map(\.application.processId))
        setHiddenProcessIds.formIntersection(setCandidateIds)
        guard
            !isSwitching,
            !setCandidateIds.isEmpty
        else {
            return
        }
        let setBeneathStageIds = windowIdsBeneathStages()
        let listShownWindows = WindowServer.listShownWindows(ofProcesses: setCandidateIds)
        let setShowingProcessIds = Set(listShownWindows.map(\.processId))
        let mapShownProcessIds = Dictionary(
            uniqueKeysWithValues: listShownWindows
                .filter { ScreenGeometry.visibleShare(of: $0.frame) > Self.hiddenVisibleShareLimit }
                .filter { !setBeneathStageIds.contains($0.windowId) }
                .map { ($0.windowId, $0.processId) }
        )
        let setPictureProcessIds = pictureProcessIds()
        let frontmostProcessId = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for processId in workspace.processIdsShowingOnlyHiddenWindows(among: mapShownProcessIds) {
            guard
                setShowingProcessIds.contains(processId),
                !setPictureProcessIds.contains(processId),
                processId != frontmostProcessId,
                let running = NSRunningApplication(processIdentifier: processId),
                !running.isActive
            else {
                continue
            }
            if !running.isHidden {
                _ = running.hide()
                if setHiddenProcessIds.contains(processId) {
                    Self.logger.notice("""
                        \(running.localizedName ?? "", privacy: .public) showed itself while its windows are all \
                        hidden; hid it again
                        """)
                } else {
                    Self.logger.info("hid \(running.localizedName ?? "", privacy: .public), whose windows are all hidden")
                }
            }
            setHiddenProcessIds.insert(processId)
        }
    }

    /// Put back to normal every application in the background that is in front or shown again, whatever
    /// missed it: an application in front left in the background makes everything typed into it lag.
    private func releaseShownApplications() {
        let frontmostProcessId = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for processId in throttle.setThrottledProcessIds {
            let running = NSRunningApplication(processIdentifier: processId)
            guard
                processId == frontmostProcessId
                || running?.isActive == true
                || running?.isHidden == false
            else {
                continue
            }
            Self.logger.notice("\(running?.localizedName ?? String(processId), privacy: .public) was in the background while shown")
            throttle.release(processId)
        }
    }

    /// The on-screen windows wholly beneath an open stage, which nobody sees.
    private func windowIdsBeneathStages() -> Set<WindowId> {
        let setStageWindowIds = stageCoordinator?.setOpenStageWindowIds ?? []
        var listStageFramesAbove: [CGRect] = []
        var setBeneathIds: Set<WindowId> = []
        for onScreen in WindowServer.listOnScreenWindows() {
            if setStageWindowIds.contains(onScreen.windowId) {
                listStageFramesAbove.append(onScreen.frame)
            } else if listStageFramesAbove.contains(where: { $0.contains(onScreen.frame) }) {
                setBeneathIds.insert(onScreen.windowId)
            }
        }
        return setBeneathIds
    }

    /// Bring back the application of a window about to be shown, if it is hidden, and put it back to normal.
    /// Unhiding finishes later and puts the application's windows back in its own order, and a hidden
    /// application's windows cannot be moved, so this waits until the application is shown.
    /// - Returns: whether the application shows, so its windows can be moved: a hidden application's cannot
    private func revealApplication(of windowId: WindowId) async -> Bool {
        guard
            let window = workspace.group(containing: windowId)?.listMembers.first(where: { $0.windowId == windowId })
        else {
            return true
        }
        throttle.release(window.application.processId)
        setHiddenProcessIds.remove(window.application.processId)
        guard
            let running = NSRunningApplication(processIdentifier: window.application.processId),
            running.isHidden
        else {
            return true
        }
        running.unhide()
        if await waitUntilShown(running) {
            return true
        }
        Self.logger.notice("\(running.localizedName ?? "", privacy: .public) is still hidden after asking it to unhide; activating it")
        running.activate()
        if await waitUntilShown(running) {
            return true
        }
        Self.logger.error("\(running.localizedName ?? "", privacy: .public) stays hidden; its window is left where it is")
        return false
    }

    /// Wait, up to `unhideTimeout`, for an application to stop being hidden.
    private func waitUntilShown(_ running: NSRunningApplication) async -> Bool {
        let deadline = ContinuousClock.now + Self.unhideTimeout
        while running.isHidden && ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.unhidePollInterval)
            } catch {
                return false
            }
        }
        return !running.isHidden
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
            noteIfDisplaced(window)
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

    /// Where a window belongs when it is shown: its place before Rookery hid it, or where it is now.
    /// Note a managed window on a stage that is no longer where its stage keeps it, as when the user resizes
    /// it or its application moves it, so it is put back: managed windows stay with their stage until
    /// released. Where a window is is where the window server draws it: an application can report a frame
    /// it does not draw at.
    private func noteIfDisplaced(_ record: WindowRecord) {
        guard
            !record.isMinimized,
            !record.isFullscreen,
            let group = workspace.group(containing: record.windowId),
            let stageId = mapGroupStageIds[group.groupId],
            let contentFrame = mapStageContentFrames[stageId],
            !Self.isFrame(record.seenFrame, closeTo: contentFrame),
            mapUnfitFrames[record.windowId].map({ Self.isFrame(record.seenFrame, closeTo: $0) }) != true
        else {
            return
        }
        let isHidden = workspace.listHiddenWindows.contains { $0.windowId == record.windowId }
        if !isHidden && !isShownOnStage(record.windowId, in: group) {
            return
        }
        setDisplacedIds.insert(record.windowId)
        guard putBackTask == nil else {
            return
        }
        putBackTask = Task {
            while
                NSEvent.pressedMouseButtons != 0
                || isWindowDragActive
                || !setFollowingStageIds.isEmpty
            {
                do {
                    try await Task.sleep(for: Self.putBackPollInterval)
                } catch {
                    return
                }
            }
            putBackTask = nil
            let listWindowIds = Array(setDisplacedIds)
            setDisplacedIds.removeAll()
            await enqueue {
                for windowId in listWindowIds {
                    await self.putBack(windowId)
                }
            }
        }
    }

    /// Put a displaced managed window back where its stage keeps it: in the content area if it is its
    /// stage's front window, minimized again if it is hidden.
    private func putBack(_ windowId: WindowId) async {
        if workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            await minimizeAgain(windowId)
            return
        }
        guard let group = workspace.group(containing: windowId) else {
            return
        }
        guard isShownOnStage(windowId, in: group) else {
            return
        }
        guard
            let stageId = mapGroupStageIds[group.groupId],
            let contentFrame = mapStageContentFrames[stageId],
            let reportedFrame = await tracker.frame(of: windowId),
            await !tracker.isFullscreen(windowId)
        else {
            return
        }
        let shownWindow = WindowServer.window(withId: windowId)
        let frame = shownWindow?.isOnScreen == true ? (shownWindow?.frame ?? reportedFrame) : reportedFrame
        guard !Self.isFrame(frame, closeTo: contentFrame) else {
            return
        }
        Self.logger.info("""
            window \(windowId.rawValue) moved off its stage to \(String(describing: frame), privacy: .public); \
            putting it back
            """)
        if Self.isFrame(reportedFrame, closeTo: contentFrame) {
            keepPlaced(windowId, at: contentFrame)
            return
        }
        if
            let landedFrame = await tracker.applyFrame(contentFrame, to: windowId),
            !Self.isFrame(landedFrame, closeTo: contentFrame)
        {
            mapUnfitFrames[windowId] = landedFrame
        } else {
            mapUnfitFrames[windowId] = nil
        }
    }

    private static func isFrame(_ lhs: CGRect, closeTo rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= placementTolerance
            && abs(lhs.minY - rhs.minY) <= placementTolerance
            && abs(lhs.width - rhs.width) <= placementTolerance
            && abs(lhs.height - rhs.height) <= placementTolerance
    }

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
