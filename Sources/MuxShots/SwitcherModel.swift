import MuxShotsCore
import Observation

/// One choice in the group switcher: a group, or every window.
struct SwitcherEntry: Identifiable {
    /// The group, or nil for the entry that shows every managed window.
    let groupId: GroupId?
    let title: String
    /// The bundle identifiers of the group's members, front to back.
    let listBundleIds: [String?]
    let isActive: Bool

    var id: String {
        groupId?.rawValue ?? "all"
    }
}

/// The state the switcher view renders.
@MainActor
@Observable
final class SwitcherModel {
    var isVisible = false
    var listEntries: [SwitcherEntry] = []
    var selectedIndex = 0
}
