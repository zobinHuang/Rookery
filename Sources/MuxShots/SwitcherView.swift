import AppKit
import SwiftUI

/// The group switcher: a row of group cards with a selection that slides between them.
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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Array(model.listEntries.enumerated()), id: \.element.id) { index, entry in
                    SwitcherCardView(entry: entry, isSelected: index == model.selectedIndex)
                        .background {
                            if index == model.selectedIndex {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.9))
                                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                            }
                        }
                }
            }
            .animation(Self.selectionAnimation, value: model.selectedIndex)
            Text("⇥ next   ⇧⇥ previous   release ⌥ to switch   esc to cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .modifier(TraySurface(cornerRadius: 26))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .scaleEffect(model.isVisible ? 1 : 0.94)
        .opacity(model.isVisible ? 1 : 0)
        .animation(Self.appearAnimation, value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: 132, height: 118)
        .scaleEffect(isSelected ? 1.04 : 1)
    }

    private var subtitle: String {
        guard entry.groupId != nil else {
            return "show everything"
        }
        return entry.listBundleIds.count == 1 ? "1 window" : "\(entry.listBundleIds.count) windows"
    }

    @ViewBuilder
    private var artwork: some View {
        if entry.groupId == nil {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .medium))
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
                        Image(systemName: "macwindow")
                            .font(.system(size: 28))
                            .frame(width: Self.iconSize, height: Self.iconSize)
                    }
                }
            }
        }
    }
}
