import CoreGraphics
import Observation
import RookeryCore

/// Where a window dropped on the tray goes.
enum DropTarget: Hashable {
    case group(GroupId)
    case newGroup
    case release
}

/// One drop target as the tray presents it.
struct TrayTile: Identifiable {
    let target: DropTarget
    let title: String
    /// The bundle identifiers of the group's members, in join order.
    let listBundleIds: [String?]

    var id: DropTarget {
        target
    }
}

/// The state the tray view renders: collapsed to a pill while the cursor is far, expanded into drop
/// targets near the top of the screen.
@MainActor
@Observable
final class TrayModel {
    var isVisible = false
    var isExpanded = false
    var listTiles: [TrayTile] = []
    var hoveredTarget: DropTarget?
    /// The target that just received a window, which bounces once.
    var landedTarget: DropTarget?
    /// The pill's caption: the dragged window's group, or nil for an unmanaged window.
    var draggedGroupName: String?

    /// Each tile's frame in the hosting view, origin at its top-left, as last laid out.
    @ObservationIgnored var mapTileFrames: [DropTarget: CGRect] = [:]
}
