import AppKit
import RookeryCore

/// Somewhere a dragged window can be dropped to hand it to Rookery: the tray, or the open panel.
/// Cursor locations and frames are in AppKit screen coordinates.
@MainActor
protocol DropSurface: AnyObject {
    /// Start showing drop feedback for a window drag.
    ///
    /// - Parameters:
    ///   - listGroups: the groups to offer
    ///   - currentGroup: the group the dragged window is in
    ///   - draggedWindowId: the window being dragged, which stays above the surface
    ///   - cursorLocation: the cursor
    func beginWindowDrag(
        listGroups: [WindowGroup],
        currentGroup: WindowGroup?,
        draggedWindowId: WindowId,
        at cursorLocation: CGPoint
    )

    /// Follow the cursor, lighting up the target under it.
    func updateWindowDrag(at cursorLocation: CGPoint)

    /// The target under the cursor.
    func target(at cursorLocation: CGPoint) -> DropTarget?

    /// Animate a dropped window into its target, then end the feedback.
    ///
    /// - Parameters:
    ///   - target: the target the window was dropped on
    ///   - landedGroupId: the group the window joined, or nil when it was released
    ///   - windowFrame: the dropped window's frame
    ///   - icon: the window's application icon
    ///   - listGroups: the groups after the drop
    func land(
        on target: DropTarget,
        landedGroupId: GroupId?,
        windowFrame: CGRect?,
        icon: NSImage?,
        listGroups: [WindowGroup]
    )

    /// End the feedback without a drop.
    func cancelWindowDrag()
}
