import AppKit
import MuxShotsCore
import MuxShotsPlatform

/// The open stages, at most one per display: opens and closes them, moves them between displays, and
/// passes a window drag to whichever stage is under the cursor.
@MainActor
final class StageCoordinator: DropSurface {
    private let workspaceController: WorkspaceController
    private let preferences: Preferences
    private let ghostAnimator: DropGhostAnimator
    private var listStages: [StageController] = []
    /// The stage a window drag is over, which shows the drop feedback.
    private var dropStage: StageController?
    private var currentDragGroup: WindowGroup?
    private var draggedWindowId: WindowId?

    init(workspaceController: WorkspaceController, preferences: Preferences, ghostAnimator: DropGhostAnimator) {
        self.workspaceController = workspaceController
        self.preferences = preferences
        self.ghostAnimator = ghostAnimator
    }

    /// Whether any stage is open.
    var isAnyOpen: Bool {
        listStages.contains { $0.isShowing }
    }

    /// Open a stage on the display under the cursor, or close the one there.
    func toggleOnCursorDisplay() {
        guard let screen = Self.screenUnderCursor() else {
            return
        }
        if let stage = stage(on: screen) {
            stage.close()
        } else {
            open(on: screen)
        }
    }

    /// Open a stage on the display under the cursor, unless one is there already.
    func openOnCursorDisplay() {
        guard let screen = Self.screenUnderCursor(), stage(on: screen) == nil else {
            return
        }
        open(on: screen)
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

    /// Move the stage under the cursor to the next display, trading places with a stage already there.
    func moveStageUnderCursorToNextDisplay() {
        let listScreens = NSScreen.screens
        guard
            listScreens.count > 1,
            let screen = Self.screenUnderCursor(),
            let stage = stage(on: screen),
            let index = listScreens.firstIndex(of: screen)
        else {
            return
        }
        move(stage, from: screen, to: listScreens[(index + 1) % listScreens.count])
    }

    /// Settle a stage the user dragged: it fills the display under the cursor, trading places with a stage
    /// already there.
    ///
    /// - Parameters:
    ///   - stage: the dragged stage
    ///   - originalScreen: the display it was dragged from
    func stageDragEnded(_ stage: StageController, from originalScreen: NSScreen?) {
        guard let targetScreen = Self.screenUnderCursor() else {
            return
        }
        move(stage, from: originalScreen, to: targetScreen)
    }

    /// Redisplay every stage, and forget the ones that have closed.
    func refresh() {
        for stage in listStages {
            stage.refresh()
        }
        listStages.removeAll { $0.isClosed }
    }

    /// The stage under a point, in AppKit screen coordinates.
    func stageId(at location: CGPoint) -> StageId? {
        listStages.first { $0.isShowing && $0.frame.contains(location) }?.stageId
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
        let stage = listStages.first { $0.isShowing && $0.frame.contains(cursorLocation) }
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

    // MARK: - Displays

    private func open(on screen: NSScreen) {
        let stage = StageController(
            stageId: .make(),
            workspaceController: workspaceController,
            preferences: preferences,
            ghostAnimator: ghostAnimator,
            coordinator: self
        )
        listStages.append(stage)
        stage.open(on: screen)
    }

    private func move(_ stage: StageController, from originalScreen: NSScreen?, to targetScreen: NSScreen) {
        if let occupant = self.stage(on: targetScreen), occupant !== stage, let originalScreen {
            occupant.place(on: originalScreen)
        }
        stage.place(on: targetScreen)
    }

    /// The open stage on a display.
    private func stage(on screen: NSScreen) -> StageController? {
        listStages.first { $0.isShowing && $0.frame.intersects(screen.visibleFrame) && $0.screen == screen }
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
