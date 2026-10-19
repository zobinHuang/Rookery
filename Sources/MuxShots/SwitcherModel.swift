import CoreGraphics
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
    /// The area the switcher fits in, in AppKit screen coordinates, as the stage the user works in; nil for
    /// the display under the cursor.
    let fitFrame: CGRect?
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
    var grid = SwitcherGrid()
}

/// How the switcher's cards are laid out: in rows, some of which show at once while the rest scroll.
struct SwitcherGrid: Equatable {
    var columns = 1
    var rows = 1
    var visibleRows = 1
}

/// The switcher's measurements, shared by its view and the panel sized around it.
enum SwitcherLayout {
    static let cardSize = CGSize(width: 132, height: 118)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let hintHeight: CGFloat = 14
    static let hintSpacing: CGFloat = 12
    /// Room around the cards for the selected one, which grows a little.
    static let cardInset: CGFloat = 4
    /// Room around the switcher for its shadow.
    static let shadowMargin: CGFloat = 40
    /// How far the switcher stays inside the area it fits in.
    static let fitInset: CGFloat = 24

    /// The columns and rows the switcher takes for some cards inside an area.
    static func grid(count: Int, fitting area: CGSize) -> SwitcherGrid {
        let usableWidth = area.width - (fitInset + shadowMargin + padding + cardInset) * 2
        let maxColumns = max(1, Int((usableWidth + spacing) / (cardSize.width + spacing)))
        let columns = max(1, min(count, maxColumns))
        let rows = (count + columns - 1) / columns
        let usableHeight = area.height - (fitInset + shadowMargin + padding + cardInset) * 2 - hintHeight - hintSpacing
        let maxRows = max(1, Int((usableHeight + spacing) / (cardSize.height + spacing)))
        return SwitcherGrid(columns: columns, rows: rows, visibleRows: min(rows, maxRows))
    }

    /// The panel's size around a grid.
    static func panelSize(around grid: SwitcherGrid) -> CGSize {
        CGSize(
            width: CGFloat(grid.columns) * cardSize.width + CGFloat(grid.columns - 1) * spacing
                + (padding + shadowMargin + cardInset) * 2,
            height: CGFloat(grid.visibleRows) * cardSize.height + CGFloat(grid.visibleRows - 1) * spacing
                + hintSpacing + hintHeight + (padding + shadowMargin + cardInset) * 2
        )
    }
}
