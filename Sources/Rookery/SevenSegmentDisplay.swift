import SwiftUI

/// Text drawn as a segment display in one color, unlit segments faintly showing in it and lit ones glowing
/// in the dark theme, as on a digital clock: digits on seven segments, letters on fourteen as an
/// alphanumeric display draws them, colons and dashes between. Drawn rather than set in a font so it is
/// crisp at any size and follows the theme.
///
/// The colons blink with the seconds, lit on even ones, in a layer of their own that the system animates,
/// so a blink costs the app nothing; the rest is drawn again only when the text changes.
struct SevenSegmentDisplay: View {
    let text: String
    let digitHeight: CGFloat
    let color: Color
    var isBlinking = false

    /// The width some text takes on a display of some height, for lining displays up in columns.
    static func width(of text: String, digitHeight: CGFloat) -> CGFloat {
        let geometry = SegmentGeometry(text: text, digitHeight: digitHeight)
        return geometry.size.width - geometry.glowPadding * 2
    }

    var body: some View {
        let geometry = SegmentGeometry(text: text, digitHeight: digitHeight)
        ZStack {
            SegmentLayer(geometry: geometry, color: color, layer: .glyphs)
                .equatable()
            if isBlinking {
                BlinkingColons(content: SegmentLayer(geometry: geometry, color: color, layer: .litColons))
            } else {
                SegmentLayer(geometry: geometry, color: color, layer: .litColons)
                    .equatable()
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .padding(-geometry.glowPadding)
        .accessibilityLabel(text)
    }
}

/// The lit colons, fading in on every even second and out on every odd one as the system animates their
/// layer.
private struct BlinkingColons: NSViewRepresentable {
    private static let periodSeconds: CFTimeInterval = 2
    private static let animationKey = "blink"

    let content: SegmentLayer

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        container.layer?.add(Self.makeAnimation(), forKey: Self.animationKey)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.subviews.first as? NSHostingView<SegmentLayer>)?.rootView = content
        if nsView.layer?.animation(forKey: Self.animationKey) == nil {
            nsView.layer?.add(Self.makeAnimation(), forKey: Self.animationKey)
        }
    }

    /// Fade in over the start of each even second, stay lit, fade out over the start of the odd one, stay
    /// dark; started on an even second of the wall clock so the blink keeps time with it. The window server
    /// draws a frame only while the opacity changes, so the fades are kept short.
    private static func makeAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0, 0]
        animation.keyTimes = [0, 0.04, 0.5, 0.54, 1]
        animation.duration = periodSeconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let wallSeconds = Date().timeIntervalSince1970
        let untilEvenSecond = periodSeconds - wallSeconds.truncatingRemainder(dividingBy: periodSeconds)
        animation.beginTime = CACurrentMediaTime() + untilEvenSecond - periodSeconds
        return animation
    }
}

/// One layer of a segment display, drawn again only when what it shows changes.
private struct SegmentLayer: View, Equatable {
    enum Layer {
        /// Every glyph lit as the text says, and every segment and colon dot faintly unlit.
        case glyphs
        /// The colon dots lit.
        case litColons
    }

    private static let unlitOpacity = 0.1
    private static let glowOpacity = 0.55

    let geometry: SegmentGeometry
    let color: Color
    let layer: Layer
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: SegmentLayer, rhs: SegmentLayer) -> Bool {
        lhs.geometry == rhs.geometry && lhs.color == rhs.color && lhs.layer == rhs.layer
    }

    var body: some View {
        Canvas { context, _ in
            let paths = geometry.paths()
            if layer == .glyphs {
                context.fill(paths.unlit, with: .color(color.opacity(Self.unlitOpacity)))
                context.fill(paths.colons, with: .color(color.opacity(Self.unlitOpacity)))
            }
            context.drawLayer { lit in
                if colorScheme == .dark {
                    lit.addFilter(.shadow(color: color.opacity(Self.glowOpacity), radius: geometry.glowRadius))
                }
                lit.fill(layer == .glyphs ? paths.lit : paths.colons, with: .color(color))
            }
        }
    }
}

/// Where a segment display's segments lie, for some text at some height.
private struct SegmentGeometry: Equatable {
    /// The segments of one character cell: the seven of a digit, and for letters the middle split in two,
    /// the two halves of a center stroke and four diagonals.
    enum Segment: CaseIterable {
        case top, topRight, bottomRight, bottom, bottomLeft, topLeft
        case middle
        case middleLeft, middleRight
        case centerTop, centerBottom
        case diagonalTopLeft, diagonalTopRight, diagonalBottomLeft, diagonalBottomRight
    }

    /// The paths to fill: lit segments, unlit ones, and the colon dots.
    struct Paths {
        var lit = Path()
        var unlit = Path()
        var colons = Path()
    }

    private static let digitSegments: Set<Segment> = [.top, .topRight, .bottomRight, .bottom, .bottomLeft, .topLeft, .middle]
    private static let letterSegments = Set(Segment.allCases).subtracting([.middle])
    private static let mapGlyphSegments: [Character: Set<Segment>] = [
        "0": [.top, .topRight, .bottomRight, .bottom, .bottomLeft, .topLeft],
        "1": [.topRight, .bottomRight],
        "2": [.top, .topRight, .middle, .bottomLeft, .bottom],
        "3": [.top, .topRight, .middle, .bottomRight, .bottom],
        "4": [.topLeft, .middle, .topRight, .bottomRight],
        "5": [.top, .topLeft, .middle, .bottomRight, .bottom],
        "6": [.top, .topLeft, .middle, .bottomLeft, .bottomRight, .bottom],
        "7": [.top, .topRight, .bottomRight],
        "8": digitSegments,
        "9": [.top, .topRight, .bottomRight, .bottom, .topLeft, .middle],
        "a": [.top, .topRight, .middle, .bottomLeft, .bottom, .bottomRight],
        "d": [.topRight, .bottomRight, .bottom, .bottomLeft, .middle],
        "e": [.top, .topRight, .topLeft, .middle, .bottomLeft, .bottom],
        "h": [.topLeft, .bottomLeft, .middle, .bottomRight],
        "i": [.centerBottom],
        "n": [.middle, .bottomLeft, .bottomRight],
        "o": [.middle, .bottomLeft, .bottom, .bottomRight],
        "r": [.middle, .bottomLeft],
        "t": [.topLeft, .middle, .bottomLeft, .bottom],
        "u": [.bottomLeft, .bottom, .bottomRight],
        "A": [.top, .topRight, .bottomRight, .topLeft, .bottomLeft, .middleLeft, .middleRight],
        "D": [.top, .topRight, .bottomRight, .bottom, .centerTop, .centerBottom],
        "E": [.top, .topLeft, .bottomLeft, .bottom, .middleLeft],
        "F": [.top, .topLeft, .bottomLeft, .middleLeft],
        "H": [.topLeft, .bottomLeft, .topRight, .bottomRight, .middleLeft, .middleRight],
        "I": [.top, .bottom, .centerTop, .centerBottom],
        "M": [.topLeft, .bottomLeft, .topRight, .bottomRight, .diagonalTopLeft, .diagonalTopRight],
        "N": [.topLeft, .bottomLeft, .topRight, .bottomRight, .diagonalTopLeft, .diagonalBottomRight],
        "O": [.top, .topRight, .bottomRight, .bottom, .bottomLeft, .topLeft],
        "R": [.top, .topRight, .topLeft, .bottomLeft, .middleLeft, .middleRight, .diagonalBottomRight],
        "S": [.top, .topLeft, .middleLeft, .middleRight, .bottomRight, .bottom],
        "T": [.top, .centerTop, .centerBottom],
        "U": [.topLeft, .bottomLeft, .bottom, .bottomRight, .topRight],
        "W": [.topLeft, .bottomLeft, .topRight, .bottomRight, .diagonalBottomLeft, .diagonalBottomRight],
    ]
    private static let widthRatio: CGFloat = 0.58
    private static let thicknessRatio: CGFloat = 0.115
    /// The thinnest a segment gets, so small displays stay legible.
    private static let minimumThickness: CGFloat = 1.1
    private static let digitSpacingRatio: CGFloat = 0.2
    private static let colonWidthRatio: CGFloat = 0.26
    /// A dash's cell, narrower than a digit's, so a date reads as numbers apart rather than a row of digits.
    private static let dashWidthRatio: CGFloat = 0.34
    /// How far the display leans, as a share of its height, like the slanted digits of a real display.
    private static let slant: CGFloat = 0.08
    private static let glowRadiusRatio: CGFloat = 0.18
    private static let gapRatio: CGFloat = 0.3

    let text: String
    let digitHeight: CGFloat

    var glowRadius: CGFloat {
        digitHeight * Self.glowRadiusRatio
    }

    /// Room around the glyphs for their glow.
    var glowPadding: CGFloat {
        glowRadius * 2
    }

    var size: CGSize {
        let listWidths = text.map(cellWidth(of:))
        let width = listWidths.reduce(0, +) + digitSpacing * CGFloat(max(listWidths.count - 1, 0))
        return CGSize(
            width: width + Self.slant * digitHeight + glowPadding * 2,
            height: digitHeight + glowPadding * 2
        )
    }

    func paths() -> Paths {
        let lean = CGAffineTransform(a: 1, b: 0, c: -Self.slant, d: 1, tx: Self.slant * digitHeight, ty: 0)
            .concatenating(CGAffineTransform(translationX: glowPadding, y: glowPadding))
        var paths = Paths()
        var x: CGFloat = 0
        for character in text {
            if character == ":" {
                paths.colons.addPath(colonPath(at: x).applying(lean))
                x += colonWidth + digitSpacing
                continue
            }
            if character == "-" {
                paths.lit.addPath(horizontal(fromX: x, toX: x + dashWidth, y: digitHeight / 2, gap: 0).applying(lean))
                x += dashWidth + digitSpacing
                continue
            }
            let setLit = Self.mapGlyphSegments[character] ?? []
            let setCell = setLit.isSubset(of: Self.digitSegments) ? Self.digitSegments : Self.letterSegments
            for segment in Segment.allCases where setCell.contains(segment) {
                let path = segmentPath(segment, originX: x).applying(lean)
                if setLit.contains(segment) {
                    paths.lit.addPath(path)
                } else {
                    paths.unlit.addPath(path)
                }
            }
            x += digitWidth + digitSpacing
        }
        return paths
    }

    private var digitWidth: CGFloat {
        digitHeight * Self.widthRatio
    }

    private var thickness: CGFloat {
        max(digitHeight * Self.thicknessRatio, Self.minimumThickness)
    }

    private var digitSpacing: CGFloat {
        digitHeight * Self.digitSpacingRatio
    }

    private var colonWidth: CGFloat {
        digitHeight * Self.colonWidthRatio
    }

    private var dashWidth: CGFloat {
        digitHeight * Self.dashWidthRatio
    }

    private func cellWidth(of character: Character) -> CGFloat {
        switch character {
        case ":": colonWidth
        case "-": dashWidth
        default: digitWidth
        }
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

    /// A segment: a long hexagon with pointed ends, the shape of a real display's segment, or a thin bar
    /// for a letter's diagonals.
    private func segmentPath(_ segment: Segment, originX: CGFloat) -> Path {
        let gap = thickness * Self.gapRatio
        let half = thickness / 2
        let left = originX + half
        let right = originX + digitWidth - half
        let center = originX + digitWidth / 2
        let top = half
        let middle = digitHeight / 2
        let bottom = digitHeight - half
        switch segment {
        case .top:
            return horizontal(fromX: left, toX: right, y: top, gap: gap)
        case .middle:
            return horizontal(fromX: left, toX: right, y: middle, gap: gap)
        case .middleLeft:
            return horizontal(fromX: left, toX: center, y: middle, gap: gap)
        case .middleRight:
            return horizontal(fromX: center, toX: right, y: middle, gap: gap)
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
        case .centerTop:
            return vertical(fromY: top, toY: middle, x: center, gap: gap)
        case .centerBottom:
            return vertical(fromY: middle, toY: bottom, x: center, gap: gap)
        case .diagonalTopLeft:
            return diagonal(from: CGPoint(x: left, y: top), to: CGPoint(x: center, y: middle))
        case .diagonalTopRight:
            return diagonal(from: CGPoint(x: right, y: top), to: CGPoint(x: center, y: middle))
        case .diagonalBottomLeft:
            return diagonal(from: CGPoint(x: left, y: bottom), to: CGPoint(x: center, y: middle))
        case .diagonalBottomRight:
            return diagonal(from: CGPoint(x: right, y: bottom), to: CGPoint(x: center, y: middle))
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

    /// A diagonal bar between two corners of a cell, kept clear of the strokes it meets.
    private func diagonal(from start: CGPoint, to end: CGPoint) -> Path {
        let inset = thickness * 1.2
        let length = hypot(end.x - start.x, end.y - start.y)
        let unitX = (end.x - start.x) / length
        let unitY = (end.y - start.y) / length
        var path = Path()
        path.move(to: CGPoint(x: start.x + unitX * inset, y: start.y + unitY * inset))
        path.addLine(to: CGPoint(x: end.x - unitX * inset * 0.6, y: end.y - unitY * inset * 0.6))
        return path.strokedPath(StrokeStyle(lineWidth: thickness * 0.85, lineCap: .round))
    }
}
