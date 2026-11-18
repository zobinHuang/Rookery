import AppKit
import Observation
import SwiftUI

/// The widths the user dragged the columns of Rookery's pages to, and which of their sidebars the user
/// hid, kept across launches.
@MainActor
@Observable
final class PageColumns {
    /// A column of a page that the user can widen or narrow.
    enum Column: String, CaseIterable {
        case mailFolders
        case mailMessages
        case calendarList
        case ravenConversations
        case mailRaven

        var defaultWidth: CGFloat {
            switch self {
            case .mailFolders: 210
            case .mailMessages: 340
            case .calendarList: 210
            case .ravenConversations: 220
            case .mailRaven: 360
            }
        }

        var range: ClosedRange<CGFloat> {
            switch self {
            case .mailFolders: 150...360
            case .mailMessages: 240...620
            case .calendarList: 150...360
            case .ravenConversations: 160...420
            case .mailRaven: 280...600
            }
        }

        /// Whether the column starts hidden until the user shows it, as one that would crowd the page.
        var isHiddenByDefault: Bool {
            self == .mailRaven
        }
    }

    private static let widthsKey = "pageColumnWidths"
    private static let hiddenKey = "pageHiddenColumns"
    private static let shownKey = "pageShownColumns"

    @ObservationIgnored private let defaults: UserDefaults
    private var mapWidths: [Column: CGFloat] = [:]
    private var setHiddenColumns: Set<Column> = []
    /// The columns hidden by default that the user showed.
    private var setShownColumns: Set<Column> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mapStored = defaults.dictionary(forKey: Self.widthsKey) as? [String: Double] ?? [:]
        for (name, width) in mapStored {
            if let column = Column(rawValue: name) {
                mapWidths[column] = CGFloat(width)
            }
        }
        let listHidden = defaults.stringArray(forKey: Self.hiddenKey) ?? []
        setHiddenColumns = Set(listHidden.compactMap(Column.init(rawValue:)))
        let listShown = defaults.stringArray(forKey: Self.shownKey) ?? []
        setShownColumns = Set(listShown.compactMap(Column.init(rawValue:)))
    }

    /// A column's width, as the user left it.
    func width(of column: Column) -> CGFloat {
        mapWidths[column] ?? column.defaultWidth
    }

    /// Widen or narrow a column, within its range, while the user drags; `save()` keeps it.
    func resize(_ column: Column, to width: CGFloat) {
        mapWidths[column] = min(max(width, column.range.lowerBound), column.range.upperBound)
    }

    func isHidden(_ column: Column) -> Bool {
        column.isHiddenByDefault ? !setShownColumns.contains(column) : setHiddenColumns.contains(column)
    }

    /// Hide a column, or show it again.
    func toggle(_ column: Column) {
        if column.isHiddenByDefault {
            if setShownColumns.contains(column) {
                setShownColumns.remove(column)
            } else {
                setShownColumns.insert(column)
            }
        } else if setHiddenColumns.contains(column) {
            setHiddenColumns.remove(column)
        } else {
            setHiddenColumns.insert(column)
        }
        save()
    }

    /// Keep the widths and the hidden columns for the next launch.
    func save() {
        var mapStored: [String: Double] = [:]
        for (column, width) in mapWidths {
            mapStored[column.rawValue] = Double(width)
        }
        defaults.set(mapStored, forKey: Self.widthsKey)
        defaults.set(setHiddenColumns.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
        defaults.set(setShownColumns.map(\.rawValue).sorted(), forKey: Self.shownKey)
    }
}

/// The line between a column and the next, which the user drags to widen or narrow the column; it lights
/// while under the pointer or dragged.
struct ColumnDivider: View {
    private static let grabWidth: CGFloat = 9

    let columns: PageColumns
    let column: PageColumns.Column
    /// Whether the column is to the divider's right, so dragging left widens it.
    var isTrailing = false

    @State private var startWidth: CGFloat?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered || startWidth != nil ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(StageColors.separator))
            .frame(width: isHovered || startWidth != nil ? 2 : 1)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: Self.grabWidth)
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            isHovered = isInside
                        }
                        if isInside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? columns.width(of: column)
                                startWidth = start
                                columns.resize(column, to: start + (isTrailing ? -1 : 1) * value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                columns.save()
                            }
                    )
            }
            .zIndex(1)
    }
}

/// The button that hides a page's sidebar column or shows it again.
struct ColumnToggle: View {
    let columns: PageColumns
    let column: PageColumns.Column
    let title: String

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                columns.toggle(column)
            }
        } label: {
            RookeryIconView(.sidebar)
                .foregroundStyle(columns.isHidden(column) ? AnyShapeStyle(StageColors.secondaryText) : AnyShapeStyle(Color.accentColor))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(columns.isHidden(column) ? "Show \(title)" : "Hide \(title)")
    }
}
