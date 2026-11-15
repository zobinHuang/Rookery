import AppKit
import RookeryCore
import RookeryPlatform

/// The open stages, each a window of its own that hosts its groups: opens and closes them, keeps each
/// one just beneath its front window, moves a stage along when its front window is dragged, and passes a
/// window drag to whichever stage is under the cursor.
@MainActor
final class StageCoordinator: DropSurface {
    /// How much of the display a new stage takes when another stage is already open.
    private static let newStageShare: CGFloat = 0.72
    /// How far each further new stage is offset from the last, so they do not cover each other exactly.
    private static let cascadeOffset: CGFloat = 28
    private static let themeFadeDuration: TimeInterval = 0.35

    private let workspaceController: WorkspaceController
    private let preferences: Preferences
    private let mixerController: MixerController
    private let agentUsageMonitor: AgentUsageMonitor
    private let quickNotes: QuickNotes
    private let ghostAnimator: DropGhostAnimator
    private let shortcutRecorder: ShortcutRecorder
    private var listStages: [StageController] = []
    private var mouseMonitor: Any?
    /// The stage the left mouse button went down on, which brings its front window forward when it goes up.
    private weak var pressedStage: StageController?
    /// The stage a window drag is over, which shows the drop feedback.
    private var dropStage: StageController?
    private var currentDragGroup: WindowGroup?
    private var draggedWindowId: WindowId?
    /// The stage moving along with its dragged front window.
    private var followingStage: StageController?
    private var followStartCursor: CGPoint?
    private var followStartOrigin: CGPoint?

    init(
        workspaceController: WorkspaceController,
        preferences: Preferences,
        mixerController: MixerController,
        agentUsageMonitor: AgentUsageMonitor,
        quickNotes: QuickNotes,
        ghostAnimator: DropGhostAnimator,
        shortcutRecorder: ShortcutRecorder
    ) {
        self.workspaceController = workspaceController
        self.preferences = preferences
        self.mixerController = mixerController
        self.agentUsageMonitor = agentUsageMonitor
        self.quickNotes = quickNotes
        self.ghostAnimator = ghostAnimator
        self.shortcutRecorder = shortcutRecorder
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let window = event.window
            let isDown = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                self?.handleClick(in: window, isDown: isDown)
            }
            return event
        }
    }

    /// Bring a clicked stage's front window forward once the click is over, so a click that switches groups
    /// or tabs is not undone by focusing the window it switches away from.
    private func handleClick(in window: NSWindow?, isDown: Bool) {
        guard isDown else {
            pressedStage?.bringContentToFront()
            pressedStage = nil
            return
        }
        pressedStage = listStages.first { $0.owns(window) }
    }

    /// Whether any stage is open.
    var isAnyOpen: Bool {
        listStages.contains { $0.isShowing }
    }

    /// Close the stage under the cursor, or open one filling the display there if none is.
    func toggleOnCursorDisplay() {
        if let stage = stage(at: NSEvent.mouseLocation) {
            stage.close()
        } else {
            openStage()
        }
    }

    /// Open a stage unless one is open already, filling the display under the cursor.
    func openOnCursorDisplay() {
        guard !isAnyOpen else {
            return
        }
        openStage()
    }

    /// Open another stage: the first fills the display under the cursor, later ones are smaller and
    /// cascaded so they can be dragged apart.
    func openStage() {
        guard let screen = Self.screenUnderCursor() else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let openCount = listStages.filter(\.isShowing).count
        let frame: CGRect
        if openCount == 0 {
            frame = visibleFrame
        } else {
            let size = CGSize(width: visibleFrame.width * Self.newStageShare, height: visibleFrame.height * Self.newStageShare)
            let offset = Self.cascadeOffset * CGFloat(openCount)
            frame = CGRect(
                x: min(visibleFrame.minX + (visibleFrame.width - size.width) / 2 + offset, visibleFrame.maxX - size.width),
                y: max(visibleFrame.minY + (visibleFrame.height - size.height) / 2 - offset, visibleFrame.minY),
                width: size.width,
                height: size.height
            )
        }
        let stage = StageController(
            stageId: .make(),
            workspaceController: workspaceController,
            preferences: preferences,
            mixerController: mixerController,
            agentUsageMonitor: agentUsageMonitor,
            quickNotes: quickNotes,
            ghostAnimator: ghostAnimator,
            shortcutRecorder: shortcutRecorder,
            coordinator: self
        )
        listStages.append(stage)
        stage.open(frame: frame)
    }

    /// Show the settings in the content area of the stage under the cursor, or of the first open stage.
    ///
    /// - Returns: whether a stage was open to show them
    func showSettings() -> Bool {
        guard let stage = stage(at: NSEvent.mouseLocation) ?? listStages.first(where: \.isShowing) else {
            return false
        }
        stage.open(.settings)
        return true
    }

    /// Close every stage.
    func closeAll() {
        Task { [workspaceController] in
            await workspaceController.exitAllStages()
        }
        for stage in listStages {
            stage.dismiss()
        }
    }

    /// Move the stage under the cursor to the next display, keeping its share of the display.
    func moveStageUnderCursorToNextDisplay() {
        let listScreens = NSScreen.screens
        guard
            listScreens.count > 1,
            let stage = stage(at: NSEvent.mouseLocation),
            let screen = stage.screen,
            let index = listScreens.firstIndex(of: screen)
        else {
            return
        }
        stage.place(on: listScreens[(index + 1) % listScreens.count])
    }

    /// Fit every open stage back onto the display it is mostly on, or the main display if it is on none, and
    /// refit its front window, as after displays change.
    func settleStagesOnDisplays() {
        for stage in listStages where stage.isShowing {
            stage.settleOnItsDisplay()
        }
    }

    /// Keep a stage just beneath its front window, as after that window comes forward.
    func keepStage(_ stageId: StageId, beneath windowId: WindowId) {
        listStages.first { $0.stageId == stageId }?.keep(beneath: windowId)
    }

    /// Make a change of theme fade in smoothly on every open stage instead of flipping at once.
    ///
    /// - Parameter change: what changes the theme
    func crossfadeTheme(_ change: () -> Void) {
        let listCovers = listStages.compactMap { $0.coverForCrossfade() }
        change()
        refresh()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.themeFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for cover in listCovers {
                cover.animator().alphaValue = 0
            }
        } completionHandler: {
            MainActor.assumeIsolated {
                for cover in listCovers {
                    cover.removeFromSuperview()
                }
            }
        }
    }

    /// Redisplay every stage, and forget the ones that have closed.
    func refresh() {
        for stage in listStages {
            stage.refresh()
        }
        listStages.removeAll { $0.isClosed }
    }

    /// Update only the title-bearing rows affected by a window title change.
    func refreshWindowTitle(_ windowId: WindowId) {
        for stage in listStages where !stage.isClosed {
            stage.refreshWindowTitle(windowId)
        }
    }

    /// The windows of the open stages, as the window server knows them.
    var setOpenStageWindowIds: Set<WindowId> {
        Set(listStages.filter(\.isShowing).map(\.windowId))
    }

    /// A stage's frame, in AppKit screen coordinates, while it is open.
    func frame(ofStage stageId: StageId) -> CGRect? {
        listStages.first { $0.stageId == stageId && $0.isShowing }?.frame
    }

    /// The stage under a point, in AppKit screen coordinates.
    func stageId(at location: CGPoint) -> StageId? {
        stage(at: location)?.stageId
    }

    // MARK: - Following a dragged front window

    /// Start moving a stage along with its front window, which the user is dragging by its title bar.
    func beginFollowing(_ stageId: StageId, windowDrag: WindowDrag, at cursorLocation: CGPoint) {
        guard let stage = listStages.first(where: { $0.stageId == stageId }) else {
            return
        }
        followingStage = stage
        followStartCursor = cursorLocation
        followStartOrigin = stage.frame.origin
        stage.isFollowingWindow = true
    }

    /// Move the following stage by as much as the cursor has moved.
    func follow(to cursorLocation: CGPoint) {
        guard let followingStage, let followStartCursor, let followStartOrigin else {
            return
        }
        followingStage.move(to: CGPoint(
            x: followStartOrigin.x + cursorLocation.x - followStartCursor.x,
            y: followStartOrigin.y + cursorLocation.y - followStartCursor.y
        ))
    }

    /// Stop following. A stage whose window was dropped on another stage goes back where it was; otherwise
    /// it stays and its window is refitted to it.
    func endFollowing(isReturning: Bool) {
        guard let followingStage else {
            return
        }
        followingStage.isFollowingWindow = false
        if isReturning, let followStartOrigin {
            followingStage.move(to: followStartOrigin)
            followingStage.relayout()
        } else {
            followingStage.settleOnCursorDisplay()
        }
        self.followingStage = nil
        followStartCursor = nil
        followStartOrigin = nil
    }

    // MARK: - Dropping windows

    func beginWindowDrag(
        listGroups: [WindowGroup],
        currentGroup: WindowGroup?,
        draggedWindowId: WindowId,
        at cursorLocation: CGPoint
    ) {
        currentDragGroup = currentGroup
        self.draggedWindowId = draggedWindowId
        updateWindowDrag(at: cursorLocation)
    }

    func updateWindowDrag(at cursorLocation: CGPoint) {
        let stage = stage(at: cursorLocation)
        if stage !== dropStage {
            dropStage?.cancelWindowDrag()
            dropStage = stage
            if let stage, let draggedWindowId {
                stage.beginWindowDrag(
                    listGroups: workspaceController.workspace.listGroups,
                    currentGroup: currentDragGroup,
                    draggedWindowId: draggedWindowId,
                    at: cursorLocation
                )
            }
        }
        dropStage?.updateWindowDrag(at: cursorLocation)
    }

    func target(at cursorLocation: CGPoint) -> DropTarget? {
        dropStage?.target(at: cursorLocation)
    }

    func land(
        on target: DropTarget,
        landedGroupId: GroupId?,
        windowFrame: CGRect?,
        icon: NSImage?,
        listGroups: [WindowGroup]
    ) {
        dropStage?.land(on: target, landedGroupId: landedGroupId, windowFrame: windowFrame, icon: icon, listGroups: listGroups)
        endDrag()
    }

    func cancelWindowDrag() {
        dropStage?.cancelWindowDrag()
        endDrag()
    }

    // MARK: - Helpers

    /// The frontmost open stage under a point, in AppKit screen coordinates, other than one following a
    /// dragged window.
    private func stage(at location: CGPoint) -> StageController? {
        let listOrderedWindows = NSApplication.shared.orderedWindows
        return listStages
            .filter { $0.isShowing && $0 !== followingStage && $0.frame.contains(location) }
            .min { lhs, rhs in
                (listOrderedWindows.firstIndex { lhs.owns($0) } ?? .max)
                    < (listOrderedWindows.firstIndex { rhs.owns($0) } ?? .max)
            }
    }

    private func endDrag() {
        dropStage = nil
        currentDragGroup = nil
        draggedWindowId = nil
    }

    private static func screenUnderCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
    }
}
