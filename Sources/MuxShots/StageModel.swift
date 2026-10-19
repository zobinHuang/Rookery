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
    /// The whole sidebar; a drop on its empty space starts a new group.
    case sidebar
    /// The placeholder row that appears below the groups while a new group would be started.
    case newGroupRow
}

/// One tab: a member of the active group.
struct StageTab: Identifiable {
    let windowId: WindowId
    /// The window's name: the user's, else its title, else its application's.
    let title: String
    let bundleId: String?
    /// Whether the user named the tab, so editing starts from that name rather than an empty field.
    let hasCustomName: Bool

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
    static let collapsedSidebarWidth: CGFloat = 64
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
    var isSidebarCollapsed = false
    /// The group whose name is being edited.
    var editingGroupId: GroupId?
    /// The tab whose name is being edited.
    var editingWindowId: WindowId?
    /// The group a dragged tab is over.
    var tabDropGroupId: GroupId?
    /// Whether a dragged tab is over the sidebar's empty space.
    var isTabOverSidebar = false
    /// Whether a tab is being dragged, which reveals the "New Group" zone.
    var isDraggingTab = false

    /// The sidebar's width as laid out now.
    var sidebarWidth: CGFloat {
        isSidebarCollapsed ? Self.collapsedSidebarWidth : Self.sidebarWidth
    }

    /// The zone to light up, from a dragged window or a dragged tab.
    var highlightedZone: StageZone? {
        if let hoveredZone {
            return hoveredZone
        }
        if let tabDropGroupId {
            return .group(tabDropGroupId)
        }
        return isTabOverSidebar ? .newGroup : nil
    }

    /// Each zone's frame in the hosting view, origin at its top-left, as last laid out.
    @ObservationIgnored var mapZoneFrames: [StageZone: CGRect] = [:]
}
