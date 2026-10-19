import SwiftUI

/// Digits and colons drawn as a seven-segment display, unlit segments faintly showing, as on a digital
/// clock. Drawn rather than set in a font so it is crisp at any size and follows the theme.
struct SevenSegmentDisplay: View {
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
    private static let thicknessRatio: CGFloat = 0.17
    private static let digitSpacingRatio: CGFloat = 0.2
    private static let colonWidthRatio: CGFloat = 0.26
    /// How far the display leans, as a share of its height, like the slanted digits of a real display.
    private static let slant: CGFloat = 0.08
    private static let unlitOpacity = 0.07

    let text: String
    let digitHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let lean = CGAffineTransform(a: 1, b: 0, c: -Self.slant, d: 1, tx: Self.slant * size.height, ty: 0)
            var x: CGFloat = 0
            for character in text {
                if character == ":" {
                    drawColon(at: x, in: &context, transform: lean)
                    x += colonWidth + digitSpacing
                } else {
                    let setLit = Self.mapDigitSegments[character] ?? []
                    for segment in Segment.allCases {
                        let path = segmentPath(segment, originX: x).applying(lean)
                        context.fill(path, with: .color(.primary.opacity(setLit.contains(segment) ? 1 : Self.unlitOpacity)))
                    }
                    x += digitWidth + digitSpacing
                }
            }
        }
        .frame(width: totalWidth + Self.slant * digitHeight, height: digitHeight)
        .accessibilityLabel(text)
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

    private func drawColon(at originX: CGFloat, in context: inout GraphicsContext, transform: CGAffineTransform) {
        let dotSize = thickness
        let centerX = originX + colonWidth / 2
        for centerY in [digitHeight * 0.32, digitHeight * 0.7] {
            let dot = Path(roundedRect: CGRect(
                x: centerX - dotSize / 2,
                y: centerY - dotSize / 2,
                width: dotSize,
                height: dotSize
            ), cornerRadius: dotSize * 0.25)
            context.fill(dot.applying(transform), with: .color(.primary))
        }
    }

    /// A segment as a long hexagon with pointed ends, the shape of a real display's segment.
    private func segmentPath(_ segment: Segment, originX: CGFloat) -> Path {
        let gap = thickness * 0.18
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
