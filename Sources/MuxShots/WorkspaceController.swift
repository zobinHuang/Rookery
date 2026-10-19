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

    private(set) var workspace: Workspace
    /// The area the front window fills while the stage is open, in window-server coordinates; nil while
    /// the stage is closed.
    private(set) var stageContentFrame: CGRect?
    private let tracker: WindowTracker
    private let dragMonitor = WindowDragMonitor()
    private let ghostAnimator = DropGhostAnimator()
    private lazy var tray = DropTrayController(ghostAnimator: ghostAnimator)
    /// Where the current window drag is being dropped.
    private var activeSurface: DropSurface?

    /// The panel, which receives dragged windows while it is open.
    weak var panel: WorkspacePanelController?
    /// The stage, which receives dragged windows while it is open, in preference to the panel.
    weak var stageSurface: DropSurface?
    private var changeTask: Task<Void, Never>?
    /// Resuming the saved windows at launch, which every layout change waits for.
    private var startupTask: Task<Void, Never>?
    /// The latest layout change (a switch, or opening or closing the stage); each waits for the one before.
    private var switchTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var isSwitching = false
    /// Managed windows the user has used, most recent first.
    private var listRecentWindowIds: [WindowId] = []
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
    ///   - homeFrame: where the window belongs off the stage, when it is not where it is now, as for a window
    ///     dragged onto the stage
    /// - Returns: the group the window joined, or nil if its application is gone
    @discardableResult
    func adopt(_ windowId: WindowId, processId: pid_t, into groupId: GroupId?, homeFrame: CGRect? = nil) -> GroupId? {
        let isNew = !workspace.isManaged(windowId)
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
            if self.workspace.isActive(joinedGroupId) || self.workspace.setActiveGroupIds.isEmpty {
                await self.switchTo(joinedGroupId, bringingToFront: windowId)
            } else {
                await self.switchTo(self.frontmostActiveGroup()?.groupId)
            }
        }
        return joinedGroupId
    }

    /// Whether the stage is open.
    var isStageOpen: Bool {
        stageContentFrame != nil
    }

    /// Open the stage: every managed window leaves its place, remembered as its home, and the front window
    /// of the group the user was in fills the content area. With no groups yet, the stage opens empty.
    ///
    /// - Parameter contentFrame: the content area, in window-server coordinates
    func enterStage(contentFrame: CGRect) async {
        await enqueue {
            let isOpening = self.stageContentFrame == nil
            self.stageContentFrame = contentFrame
            let startGroupId = self.frontmostActiveGroup()?.groupId ?? self.workspace.listGroups.first?.groupId
            if isOpening {
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
            guard let startGroupId else {
                self.didChange()
                return
            }
            await self.performSwitch(to: startGroupId, bringingToFront: nil)
        }
    }

    /// Move the stage's content area, as when the sidebar collapses or the stage moves to another display,
    /// and refit the front window to it.
    ///
    /// - Parameter contentFrame: the new content area, in window-server coordinates
    func relayoutStage(contentFrame: CGRect) async {
        await enqueue {
            guard self.stageContentFrame != nil else {
                return
            }
            self.stageContentFrame = contentFrame
            guard let windowId = self.workspace.listActiveGroups.first?.listMembersFrontToBack.first?.windowId else {
                return
            }
            await self.tracker.applyFrame(contentFrame, to: windowId)
        }
    }

    /// Close the stage, putting every window back where it was before the stage took it over.
    func exitStage() async {
        await enqueue {
            guard self.stageContentFrame != nil else {
                return
            }
            self.stageContentFrame = nil
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
            if self.isStageOpen, let groupId, self.workspace.isActive(groupId) {
                await self.switchTo(groupId)
            }
        }
    }

    /// Show one group and hide every other group's windows, or with nil show every managed window and leave
    /// group mode. Switches run one after another in the order requested.
    ///
    /// - Parameters:
    ///   - groupId: the group to show, or nil for every managed window
    ///   - frontWindowId: a member to put in front of the group's other windows
    func switchTo(_ groupId: GroupId?, bringingToFront frontWindowId: WindowId? = nil) async {
        await enqueue {
            await self.performSwitch(to: groupId, bringingToFront: frontWindowId)
        }
    }

    /// Run a layout change after the ones already requested.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previousTask = switchTask
        let startupTask = startupTask
        let task = Task {
            await startupTask?.value
            await previousTask?.value
            isSwitching = true
            await work()
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

    /// Put every window back where it belongs (its place before the stage, or before MuxShots hid it) and
    /// leave group mode, as the stage closes and as MuxShots launches or quits.
    func restoreAllWindows() async {
        stageContentFrame = nil
        let listWindows = workspace.listManagedWindows.filter { $0.homeFrame != nil || $0.isHidden }
        await withTaskGroup(of: Void.self) { taskGroup in
            for window in listWindows {
                let homeFrame = workspace.markUnstaged(window.windowId)
                let restoreFrame = workspace.markShown(window.windowId)
                guard let frame = homeFrame ?? restoreFrame else {
                    continue
                }
                taskGroup.addTask { [tracker] in
                    await tracker.applyFrame(frame, to: window.windowId)
                }
            }
        }
        workspace.deactivateAll()
        didChange()
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

    /// Move a managed window to a group, or to a new group with nil, laying out the stage afterwards.
    func moveWindow(_ windowId: WindowId, to groupId: GroupId?) {
        guard let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) else {
            return
        }
        adopt(windowId, processId: window.application.processId, into: groupId)
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
        guard isStageOpen, let windowId = workspace.listActiveGroups.first?.listMembersFrontToBack.first?.windowId else {
            return
        }
        Task {
            try? await focus(windowId)
        }
    }

    /// Make the stage, which shares the drop animation with the tray.
    func makeStage() -> StageController {
        let stage = StageController(workspaceController: self, preferences: preferences, ghostAnimator: ghostAnimator)
        stageSurface = stage
        return stage
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
        let surface: DropSurface = if isStageOpen, let stageSurface {
            stageSurface
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
        activeSurface?.updateWindowDrag(at: cursorLocation)
    }

    func windowDragEnded(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        guard let surface = activeSurface else {
            return
        }
        activeSurface = nil
        guard let target = surface.target(at: cursorLocation) else {
            surface.cancelWindowDrag()
            snapBackToStage(drag)
            return
        }
        let isStageDrop = isStageOpen && surface === stageSurface
        let droppedFrame = WindowServer.window(withId: drag.windowId).map { ScreenGeometry.appKitFrame(fromWindowServer: $0.frame) }
        let icon = NSRunningApplication(processIdentifier: drag.processId)?.icon
        let homeFrame = isStageDrop ? drag.startFrame : nil
        let landedGroupId: GroupId? = switch target {
        case .group(let groupId):
            adopt(drag.windowId, processId: drag.processId, into: groupId, homeFrame: homeFrame)
        case .newGroup:
            adopt(drag.windowId, processId: drag.processId, into: nil, homeFrame: homeFrame)
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

    /// Put the stage's front window back in the content area after the user dragged it off without
    /// dropping it anywhere.
    private func snapBackToStage(_ drag: WindowDrag) {
        guard
            let contentFrame = stageContentFrame,
            workspace.listStagedWindows.contains(where: { $0.windowId == drag.windowId && !$0.isHidden })
        else {
            return
        }
        Task { [tracker] in
            try? await Task.sleep(for: Self.settleDelay)
            await tracker.applyFrame(contentFrame, to: drag.windowId)
        }
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
        let stageProcessId = workspace.listActiveGroups.first?.listMembersFrontToBack.first?.application.processId
        return frontmostProcessId == ProcessInfo.processInfo.processIdentifier || frontmostProcessId == stageProcessId
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
    func groupSwitcherRequest() -> SwitcherRequest? {
        guard !workspace.listGroups.isEmpty else {
            return nil
        }
        let currentGroupId = frontmostActiveGroup()?.groupId
        let listEntries = workspace.listGroups.map { group in
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
            subtitle: isStageOpen ? "leave the stage" : "show everything",
            listBundleIds: [],
            symbolName: "square.grid.2x2",
            isActive: false
        )]
        let currentIndex = listEntries.firstIndex { $0.id == currentGroupId?.rawValue } ?? listEntries.count - 1
        return SwitcherRequest(listEntries: listEntries, currentIndex: currentIndex) { [weak self] entry in
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
        return SwitcherRequest(listEntries: listEntries, currentIndex: 0) { [weak self] entry in
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
        if isStageOpen {
            let frontId = group.listMembersFrontToBack.first?.windowId
            let frontIndex = group.listMembers.firstIndex { $0.windowId == frontId } ?? -1
            await switchTo(group.groupId, bringingToFront: group.listMembers[(frontIndex + 1) % group.listMembers.count].windowId)
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
        if workspace.isManaged(windowId) && !workspace.listHiddenWindows.contains(where: { $0.windowId == windowId }) {
            noteRecentlyUsed(windowId)
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
            await switchTo(group.groupId, bringingToFront: windowId)
        }
    }

    private func performSwitch(to groupId: GroupId?, bringingToFront frontWindowId: WindowId?) async {
        if let stageContentFrame {
            guard let groupId else {
                await restoreAllWindows()
                return
            }
            await performStageSwitch(to: groupId, bringingToFront: frontWindowId, contentFrame: stageContentFrame)
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

    /// Fill the stage's content area with one window of a group, its front tab unless another is asked for,
    /// and hide every other managed window.
    private func performStageSwitch(
        to groupId: GroupId,
        bringingToFront frontWindowId: WindowId?,
        contentFrame: CGRect
    ) async {
        let startTime = ContinuousClock.now
        guard let targetGroup = workspace.listGroups.first(where: { $0.groupId == groupId }) else {
            return
        }
        let mapRecords = Dictionary(uniqueKeysWithValues: await tracker.listWindows().map { ($0.windowId, $0) })
        let listCandidates = targetGroup.listMembersFrontToBack.filter { mapRecords[$0.windowId]?.isMinimized != true }
        let selected = listCandidates.first { $0.windowId == frontWindowId } ?? listCandidates.first
        let listToHide = workspace.listManagedWindows.filter { window in
            window.windowId != selected?.windowId
                && !window.isHidden
                && mapRecords[window.windowId]?.isMinimized != true
        }
        await run(showing: [], hiding: listToHide)
        if let selected {
            noteRecentlyUsed(selected.windowId)
            workspace.markShown(selected.windowId)
            workspace.bringToFront(selected.windowId)
            await tracker.applyFrame(contentFrame, to: selected.windowId)
            _ = await tracker.raise(selected.windowId)
            if let processId = await tracker.processId(of: selected.windowId) {
                NSRunningApplication(processIdentifier: processId)?.activate()
            }
        }
        workspace.deactivateAll()
        workspace.activate(targetGroup.groupId, displacing: [])
        didChange()
        Self.logger.info("""
            staged \(targetGroup.name, privacy: .public): hid \(listToHide.count) in \
            \(ContinuousClock.now - startTime, privacy: .public)
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
            workspace.updateTitle(of: window.windowId, to: window.title)
            onChange?()
        case .removed(let windowId):
            let groupId = workspace.group(containing: windowId)?.groupId
            if workspace.release(windowId) {
                didChange()
                if isStageOpen, let groupId, workspace.isActive(groupId) {
                    Task {
                        await switchTo(groupId)
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
