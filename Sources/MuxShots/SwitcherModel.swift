import Observation

/// One choice in a switcher: a group, a window, or every window.
struct SwitcherEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// The applications to show, front to back.
    let listBundleIds: [String?]
    /// A symbol shown in place of application icons.
    let symbolName: String?
    let isActive: Bool
}

/// What one opening of a switcher offers, and what choosing does.
struct SwitcherRequest {
    let listEntries: [SwitcherEntry]
    /// The entry the user is on now; the switcher opens on the one after it.
    let currentIndex: Int
    let onCommit: @MainActor (SwitcherEntry) -> Void
}

/// The state the switcher view renders.
@MainActor
@Observable
final class SwitcherModel {
    var isVisible = false
    var listEntries: [SwitcherEntry] = []
    var selectedIndex = 0
    /// The modifiers to release to choose, as symbols.
    var holdSymbols = "⌥"
}
