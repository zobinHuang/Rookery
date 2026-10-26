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

/// What is being dragged inside the stage, as the text its drag carries.
enum StagePayload {
    case window(WindowId)
    case group(GroupId)
    case note(NoteId)

    private static let windowPrefix = "window:"
    private static let groupPrefix = "group:"
    private static let notePrefix = "note:"

    init?(_ text: String) {
        if text.hasPrefix(Self.windowPrefix), let rawId = UInt32(text.dropFirst(Self.windowPrefix.count)) {
            self = .window(WindowId(rawValue: rawId))
        } else if text.hasPrefix(Self.groupPrefix) {
            self = .group(GroupId(rawValue: String(text.dropFirst(Self.groupPrefix.count))))
        } else if text.hasPrefix(Self.notePrefix) {
            self = .note(NoteId(rawValue: String(text.dropFirst(Self.notePrefix.count))))
        } else {
            return nil
        }
    }

    var text: String {
        switch self {
        case .window(let windowId):
            Self.windowPrefix + String(windowId.rawValue)
        case .group(let groupId):
            Self.groupPrefix + groupId.rawValue
        case .note(let noteId):
            Self.notePrefix + noteId.rawValue
        }
    }
}

/// One tab: a member of the active group. Its name is in `StageModel.mapWindowNames`, so a new title
/// redraws only the text showing it.
struct StageTab: Identifiable, Equatable {
    let windowId: WindowId
    let bundleId: String?
    /// Whether the user named the tab, so editing starts from that name rather than an empty field.
    let hasCustomName: Bool

    var id: WindowId {
        windowId
    }
}

/// One group in the sidebar.
struct StageGroupRow: Identifiable, Equatable {
    let groupId: GroupId
    let name: String
    /// The applications of the group's windows, front to back.
    let listBundleIds: [String?]
    /// The group's front window, whose name is in `StageModel.mapWindowNames`.
    let frontWindowId: WindowId?
    let isActive: Bool

    var id: GroupId {
        groupId
    }
}

/// What the sidebar shows below its header.
enum SidebarMode: String, CaseIterable {
    case groups
    case mixer
    case notes

    var title: String {
        switch self {
        case .groups: "Groups"
        case .mixer: "Mixer"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .groups: "square.grid.2x2"
        case .mixer: "slider.vertical.3"
        case .notes: "note.text"
        }
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
    /// The names of the windows the tabs and the groups' rows show: the user's, else the title, else the
    /// application's. Kept apart from the tabs and rows, and read only by the texts showing a name, so a
    /// window retitling itself does not rebuild the stage.
    var mapWindowNames: [WindowId: String] = [:]
    /// The names of the managed windows that notes link to; a linked window missing from it has closed.
    var mapLinkedWindowNames: [WindowId: String] = [:]
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
    var sidebarMode = SidebarMode.groups
    /// Whether MuxShots draws dark now, which picks the theme button's symbol.
    var isDarkTheme = false
    /// The cities the world clock shows.
    var listClockCities: [WorldClockCity] = []
    /// The group whose name is being edited.
    var editingGroupId: GroupId?
    /// The tab whose name is being edited.
    var editingWindowId: WindowId?
    /// The quick note being edited.
    var editingNoteId: NoteId?
    /// The group a dragged tab is over.
    var tabDropGroupId: GroupId?
    /// Whether a dragged tab is over the sidebar's empty space.
    var isTabOverSidebar = false
    /// Whether a tab is being dragged, which reveals the "New Group" zone.
    var isDraggingTab = false
    /// The group being dragged to reorder the sidebar.
    var draggingGroupId: GroupId?
    /// The tab a dragged tab would be placed before.
    var tabInsertBeforeId: WindowId?
    /// Whether a dragged tab is over the empty end of the tab bar, which places it last.
    var isTabOverTabBarEnd = false
    /// The group a dragged group would be placed before.
    var groupInsertBeforeId: GroupId?
    /// Whether a dragged group is over the sidebar's empty space, which places it last.
    var isGroupOverSidebarEnd = false
    /// The quick note being dragged to reorder the notes.
    var draggingNoteId: NoteId?
    /// The note a dragged note would be placed before.
    var noteInsertBeforeId: NoteId?
    /// Whether a dragged note is over the sidebar's empty space, which places it last.
    var isNoteOverSidebarEnd = false

    /// Forget every drag of a tab, a group or a note, as when it drops or the mouse is released elsewhere.
    func clearDragState() {
        isDraggingTab = false
        draggingGroupId = nil
        tabDropGroupId = nil
        isTabOverSidebar = false
        tabInsertBeforeId = nil
        isTabOverTabBarEnd = false
        groupInsertBeforeId = nil
        isGroupOverSidebarEnd = false
        draggingNoteId = nil
        noteInsertBeforeId = nil
        isNoteOverSidebarEnd = false
    }

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
