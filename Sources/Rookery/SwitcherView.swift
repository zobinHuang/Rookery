import AppKit
import SwiftUI

/// The switcher: its cards in as many rows as the area it fits in needs, with a selection that slides
/// between them, scrolling to keep it in view when there are more rows than fit.
struct SwitcherView: View {
    private static let selectionAnimation = Animation.spring(response: 0.26, dampingFraction: 0.82)
    private static let appearAnimation = Animation.spring(response: 0.24, dampingFraction: 0.9)

    let model: SwitcherModel
    @Namespace private var selectionNamespace

    /// An AppKit view hosting the switcher.
    static func makeHostingView(model: SwitcherModel) -> NSView {
        NSHostingView(rootView: SwitcherView(model: model))
    }

    var body: some View {
        VStack(spacing: SwitcherLayout.hintSpacing) {
            cards
            Text("⇥ or arrow keys to move   release \(model.holdSymbols) to switch   esc to cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: SwitcherLayout.hintHeight)
        }
        .padding(SwitcherLayout.padding)
        .modifier(TraySurface(cornerRadius: 26))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .scaleEffect(model.isVisible ? 1 : 0.94)
        .opacity(model.isVisible ? 1 : 0)
        .animation(Self.appearAnimation, value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cards: some View {
        let columns = model.grid.columns
        let listEntries = model.listEntries
        let listRows = stride(from: 0, to: listEntries.count, by: columns).map { start in
            Array(listEntries[start..<min(start + columns, listEntries.count)])
        }
        let selectedId = listEntries.indices.contains(model.selectedIndex) ? listEntries[model.selectedIndex].id : nil
        let visibleHeight = CGFloat(model.grid.visibleRows) * SwitcherLayout.cardSize.height
            + CGFloat(model.grid.visibleRows - 1) * SwitcherLayout.spacing
            + SwitcherLayout.cardInset * 2
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SwitcherLayout.spacing) {
                    ForEach(listRows.indices, id: \.self) { rowIndex in
                        HStack(spacing: SwitcherLayout.spacing) {
                            ForEach(listRows[rowIndex]) { entry in
                                card(for: entry, isSelected: entry.id == selectedId)
                            }
                        }
                        .id(rowIndex)
                    }
                }
                .padding(SwitcherLayout.cardInset)
            }
            .scrollDisabled(model.grid.rows <= model.grid.visibleRows)
            .frame(height: visibleHeight)
            .onChange(of: model.selectedIndex) { _, selectedIndex in
                withAnimation(Self.selectionAnimation) {
                    proxy.scrollTo(selectedIndex / max(columns, 1))
                }
            }
            .onAppear {
                proxy.scrollTo(model.selectedIndex / max(columns, 1))
            }
        }
        .animation(Self.selectionAnimation, value: model.selectedIndex)
    }

    private func card(for entry: SwitcherEntry, isSelected: Bool) -> some View {
        SwitcherCardView(entry: entry, isSelected: isSelected)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.9))
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
    }
}

/// One group card: its applications' icons, its name and its size.
struct SwitcherCardView: View {
    private static let iconSize: CGFloat = 44
    private static let iconOverlap: CGFloat = -18
    private static let maximumIcons = 3

    let entry: SwitcherEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            artwork
                .frame(height: Self.iconSize)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    if entry.isActive {
                        Circle()
                            .fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                            .frame(width: 6, height: 6)
                    }
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(entry.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: SwitcherLayout.cardSize.width, height: SwitcherLayout.cardSize.height)
        .scaleEffect(isSelected ? 1.04 : 1)
    }


    @ViewBuilder
    private var artwork: some View {
        if let symbolName = entry.symbolName {
            RookeryIconView(symbolName, scale: 3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        } else {
            HStack(spacing: Self.iconOverlap) {
                ForEach(Array(entry.listBundleIds.prefix(Self.maximumIcons).enumerated()), id: \.offset) { _, bundleId in
                    if let icon = ApplicationIcon.icon(forBundleId: bundleId) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    } else {
                        RookeryIconView(.window, scale: 3)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                    }
                }
            }
        }
    }
}
