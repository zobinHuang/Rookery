import CoreGraphics
import MuxShotsCore
import Observation

/// A part of the stage a dragged window can be dropped on.
enum StageZone: Hashable {
    /// The content area, which adds the window to the active group as its front tab.
    case content
    /// A group in the sidebar.
    case group(GroupId)
    case newGroup
    case release
}

/// One tab: a member of the active group.
struct StageTab: Identifiable {
    let windowId: WindowId
    let title: String
    let applicationName: String
    let bundleId: String?

    var id: WindowId {
        windowId
    }
}

/// One group in the sidebar.
struct StageGroupRow: Identifiable {
    let groupId: GroupId
    let name: String
    let listBundleIds: [String?]
    let isActive: Bool

    var id: GroupId {
        groupId
    }
}

/// The state the stage view renders.
@MainActor
@Observable
final class StageModel {
    /// Fixed sizes shared by the view and the window layout, in points.
    static let sidebarWidth: CGFloat = 232
    static let tabBarHeight: CGFloat = 44
    static let contentInset: CGFloat = 10

    var isVisible = false
    var listGroups: [StageGroupRow] = []
    var listTabs: [StageTab] = []
    var selectedWindowId: WindowId?
    var activeGroupName: String?
    /// Whether a window drag is over the stage, which reveals the drop zones.
    var isReceivingWindow = false
    /// Whether the dragged window is managed, which offers the release zone.
    var isDraggingManagedWindow = false
    var hoveredZone: StageZone?
    /// A zone that just received a window, which pulses once.
    var landedZone: StageZone?

    /// Each zone's frame in the hosting view, origin at its top-left, as last laid out.
    @ObservationIgnored var mapZoneFrames: [StageZone: CGRect] = [:]
}
