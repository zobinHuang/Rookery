import SwiftUI

/// Digits and colons drawn as a seven-segment display in one color, unlit segments faintly showing in it
/// and lit ones glowing in the dark theme, as on a digital clock. Drawn rather than set in a font so it is
/// crisp at any size and follows the theme. The colons fade in and out smoothly as they blink.
struct SevenSegmentDisplay: View, Animatable {
    /// Each segment's place: top, top right, bottom right, bottom, bottom left, top left, middle.
    private enum Segment: CaseIterable {
        case top, topRight, bottomRight, bottom, bottomLeft, topLeft, middle
    }

    private static let mapDigitSegments: [Character: Set<Segment>] = [
        "0": [.top, .topRight, .bottomRight, .bottom, .bottomLeft, .topLeft],
        "1": [.topRight, .bottomRight],
        "2": [.top, .topRight, .middle, .bottomLeft, .bottom],
        "3": [.top, .topRight, .middle, .bottomRight, .bottom],
        "4": [.topLeft, .middle, .topRight, .bottomRight],
        "5": [.top, .topLeft, .middle, .bottomRight, .bottom],
        "6": [.top, .topLeft, .middle, .bottomLeft, .bottomRight, .bottom],
        "7": [.top, .topRight, .bottomRight],
        "8": Set(Segment.allCases),
        "9": [.top, .topRight, .bottomRight, .bottom, .topLeft, .middle],
    ]
    private static let widthRatio: CGFloat = 0.58
    private static let thicknessRatio: CGFloat = 0.115
    private static let digitSpacingRatio: CGFloat = 0.2
    private static let colonWidthRatio: CGFloat = 0.26
    /// How far the display leans, as a share of its height, like the slanted digits of a real display.
    private static let slant: CGFloat = 0.08
    private static let unlitOpacity = 0.1
    private static let glowRadiusRatio: CGFloat = 0.18
    private static let glowOpacity = 0.55

    let text: String
    let digitHeight: CGFloat
    let color: Color
    /// How lit the colons are, 0 dark to 1 lit.
    var colonOpacity: Double
    @Environment(\.colorScheme) private var colorScheme

    nonisolated var animatableData: Double {
        get { colonOpacity }
        set { colonOpacity = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let lean = CGAffineTransform(a: 1, b: 0, c: -Self.slant, d: 1, tx: Self.slant * digitHeight, ty: 0)
                .concatenating(CGAffineTransform(translationX: glowPadding, y: glowPadding))
            var unlitPath = Path()
            var litPath = Path()
            var colonPath = Path()
            var x: CGFloat = 0
            for character in text {
                if character == ":" {
                    colonPath.addPath(self.colonPath(at: x).applying(lean))
                    x += colonWidth + digitSpacing
                } else {
                    let setLit = Self.mapDigitSegments[character] ?? []
                    for segment in Segment.allCases {
                        let path = segmentPath(segment, originX: x).applying(lean)
                        if setLit.contains(segment) {
                            litPath.addPath(path)
                        } else {
                            unlitPath.addPath(path)
                        }
                    }
                    x += digitWidth + digitSpacing
                }
            }
            context.fill(unlitPath, with: .color(color.opacity(Self.unlitOpacity)))
            context.fill(colonPath, with: .color(color.opacity(Self.unlitOpacity)))
            context.drawLayer { layer in
                if colorScheme == .dark {
                    layer.addFilter(.shadow(
                        color: color.opacity(Self.glowOpacity),
                        radius: digitHeight * Self.glowRadiusRatio
                    ))
                }
                layer.fill(litPath, with: .color(color))
                layer.fill(colonPath, with: .color(color.opacity((1 - Self.unlitOpacity) * colonOpacity)))
            }
        }
        .frame(width: totalWidth + Self.slant * digitHeight + glowPadding * 2, height: digitHeight + glowPadding * 2)
        .padding(-glowPadding)
        .accessibilityLabel(text)
    }

    /// Room around the digits for their glow.
    private var glowPadding: CGFloat {
        digitHeight * Self.glowRadiusRatio * 2
    }

    private var digitWidth: CGFloat {
        digitHeight * Self.widthRatio
    }

    private var thickness: CGFloat {
        digitHeight * Self.thicknessRatio
    }

    private var digitSpacing: CGFloat {
        digitHeight * Self.digitSpacingRatio
    }

    private var colonWidth: CGFloat {
        digitHeight * Self.colonWidthRatio
    }

    private var totalWidth: CGFloat {
        let listWidths = text.map { $0 == ":" ? colonWidth : digitWidth }
        return listWidths.reduce(0, +) + digitSpacing * CGFloat(max(listWidths.count - 1, 0))
    }

    /// The colon's two dots.
    private func colonPath(at originX: CGFloat) -> Path {
        let dotSize = thickness
        let centerX = originX + colonWidth / 2
        var path = Path()
        for centerY in [digitHeight * 0.32, digitHeight * 0.7] {
            path.addRoundedRect(
                in: CGRect(
                    x: centerX - dotSize / 2,
                    y: centerY - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                ),
                cornerSize: CGSize(width: dotSize * 0.25, height: dotSize * 0.25)
            )
        }
        return path
    }

    /// A segment as a long hexagon with pointed ends, the shape of a real display's segment.
    private func segmentPath(_ segment: Segment, originX: CGFloat) -> Path {
        let gap = thickness * 0.3
        let half = thickness / 2
        let left = originX + half
        let right = originX + digitWidth - half
        let top = half
        let middle = digitHeight / 2
        let bottom = digitHeight - half
        switch segment {
        case .top:
            return horizontal(fromX: left, toX: right, y: top, gap: gap)
        case .middle:
            return horizontal(fromX: left, toX: right, y: middle, gap: gap)
        case .bottom:
            return horizontal(fromX: left, toX: right, y: bottom, gap: gap)
        case .topLeft:
            return vertical(fromY: top, toY: middle, x: left, gap: gap)
        case .topRight:
            return vertical(fromY: top, toY: middle, x: right, gap: gap)
        case .bottomLeft:
            return vertical(fromY: middle, toY: bottom, x: left, gap: gap)
        case .bottomRight:
            return vertical(fromY: middle, toY: bottom, x: right, gap: gap)
        }
    }

    private func horizontal(fromX startX: CGFloat, toX endX: CGFloat, y: CGFloat, gap: CGFloat) -> Path {
        let half = thickness / 2
        var path = Path()
        path.move(to: CGPoint(x: startX + gap, y: y))
        path.addLine(to: CGPoint(x: startX + gap + half, y: y - half))
        path.addLine(to: CGPoint(x: endX - gap - half, y: y - half))
        path.addLine(to: CGPoint(x: endX - gap, y: y))
        path.addLine(to: CGPoint(x: endX - gap - half, y: y + half))
        path.addLine(to: CGPoint(x: startX + gap + half, y: y + half))
        path.closeSubpath()
        return path
    }

    private func vertical(fromY startY: CGFloat, toY endY: CGFloat, x: CGFloat, gap: CGFloat) -> Path {
        let half = thickness / 2
        var path = Path()
        path.move(to: CGPoint(x: x, y: startY + gap))
        path.addLine(to: CGPoint(x: x + half, y: startY + gap + half))
        path.addLine(to: CGPoint(x: x + half, y: endY - gap - half))
        path.addLine(to: CGPoint(x: x, y: endY - gap))
        path.addLine(to: CGPoint(x: x - half, y: endY - gap - half))
        path.addLine(to: CGPoint(x: x - half, y: startY + gap + half))
        path.closeSubpath()
        return path
    }
}
