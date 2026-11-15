import AppKit
import SwiftUI

/// The tray surface: a pill while collapsed, a row of drop targets while expanded.
struct TrayView: View {
    private static let morphAnimation = Animation.spring(response: 0.38, dampingFraction: 0.78)
    private static let appearAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private static let hiddenOffset: CGFloat = -28
    private static let topPadding: CGFloat = 10

    let model: TrayModel

    /// An AppKit view hosting the tray.
    static func makeHostingView(model: TrayModel) -> NSView {
        NSHostingView(rootView: TrayView(model: model))
    }

    var body: some View {
        VStack {
            ZStack {
                if model.isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    pillContent
                        .transition(.opacity.combined(with: .scale(scale: 1.08, anchor: .top)))
                }
            }
            .modifier(TraySurface(cornerRadius: model.isExpanded ? 22 : 18))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .animation(Self.morphAnimation, value: model.isExpanded)
            .opacity(model.isVisible ? 1 : 0)
            .offset(y: model.isVisible ? 0 : Self.hiddenOffset)
            .animation(Self.appearAnimation, value: model.isVisible)
            Spacer(minLength: 0)
        }
        .padding(.top, Self.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var pillContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            Text(model.draggedGroupName.map { "Move from \($0)" } ?? "Add to MuxShots")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var expandedContent: some View {
        HStack(spacing: 8) {
            ForEach(model.listTiles) { tile in
                TrayTileView(
                    tile: tile,
                    isHovered: model.hoveredTarget == tile.target,
                    isLanded: model.landedTarget == tile.target
                )
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    model.mapTileFrames[tile.target] = frame
                }
            }
        }
        .padding(10)
    }
}

/// The tray's material: Liquid Glass where available, a translucent material before it.
struct TraySurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// One drop target: the group's application icons over its name.
struct TrayTileView: View {
    private static let iconSize: CGFloat = 30
    private static let iconOverlap: CGFloat = -12
    private static let maximumIcons = 3
    private static let hoverAnimation = Animation.spring(response: 0.24, dampingFraction: 0.62)

    let tile: TrayTile
    let isHovered: Bool
    let isLanded: Bool

    var body: some View {
        VStack(spacing: 6) {
            artwork
                .frame(height: Self.iconSize)
            Text(tile.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 92)
        .background(background)
        .scaleEffect(isLanded ? 1.14 : (isHovered ? 1.07 : 1))
        .animation(Self.hoverAnimation, value: isHovered)
        .animation(Self.hoverAnimation, value: isLanded)
    }

    @ViewBuilder
    private var artwork: some View {
        switch tile.target {
        case .newGroup:
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        case .release:
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.red))
        case .group:
            HStack(spacing: 4) {
                HStack(spacing: Self.iconOverlap) {
                    ForEach(Array(tile.listBundleIds.prefix(Self.maximumIcons).enumerated()), id: \.offset) { _, bundleId in
                        iconImage(forBundleId: bundleId)
                    }
                }
                if tile.listBundleIds.count > Self.maximumIcons {
                    Text("+\(tile.listBundleIds.count - Self.maximumIcons)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(isHovered ? 0.25 : 0.1), in: .capsule)
                        .foregroundStyle(isHovered ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
        }
    }

    @ViewBuilder
    private func iconImage(forBundleId bundleId: String?) -> some View {
        if let icon = ApplicationIcon.icon(forBundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 20))
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        switch (tile.target, isHovered) {
        case (.release, true):
            shape.fill(Color.red.gradient)
        case (_, true):
            shape.fill(Color.accentColor.gradient)
        case (.newGroup, false):
            shape.strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        case (_, false):
            shape.fill(Color.primary.opacity(0.07))
        }
    }
}
