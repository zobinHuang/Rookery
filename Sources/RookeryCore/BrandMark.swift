import CoreGraphics
import CoreText
import Foundation

/// Why Rookery's mark could not be drawn.
public enum BrandMarkError: Error, Equatable {
    /// The wordmark's typeface could not be read from where it was looked for.
    case fontUnreadable(URL)
}

/// Rookery's mark: the wordmark `rookery` in a wide geometric face, its two o's a crow's eyes glaring
/// under brows that drop toward each other, and its y a rook: its arm a wing swept back into the
/// trajectory that sweeps under the whole word, the trajectory rising on as the neck into a head and
/// beak drawn in one line, facing on; for the app icon and the menu bar, the pair of eyes alone over the
/// same sweep. Everything is drawn in one color, in a context whose y axis points down.
public enum BrandMark {
    /// The word the mark spells.
    public static let word = "rookery"
    /// The typeface's file in the app's resources.
    public static let fontResource = "Michroma-Regular"
    public static let fontExtension = "ttf"
    public static let fontDirectory = "Fonts"

    /// The space between letters, as a share of the type size.
    static let letterSpacing: CGFloat = 0.14
    /// A stroke's weight, as a share of the x-height, the same in the letters and in the eyes.
    static let strokeShare: CGFloat = 0.15
    /// The side of the square the icon's mark is laid out in.
    static let markSide: CGFloat = 100
    /// The rook's head's scale, as a share of the x-height.
    static let headShare: CGFloat = 0.62

    /// Read the wordmark's typeface at a size.
    ///
    /// - Parameters:
    ///   - url: the typeface's file
    ///   - size: the type size in points
    /// - Returns: the font
    /// - Throws: `BrandMarkError.fontUnreadable` when the file holds no font
    public static func font(at url: URL, size: CGFloat) throws -> CTFont {
        guard
            let listDescriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = listDescriptors.first
        else {
            throw BrandMarkError.fontUnreadable(url)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Draw the wordmark with the left edge of its first letter at `x` on a baseline.
    ///
    /// - Parameters:
    ///   - context: a context whose y axis points down
    ///   - x: where the first letter starts
    ///   - baseline: the baseline's y
    ///   - font: the wordmark's typeface at its size
    ///   - ink: the one color it is drawn in
    ///   - isDrawingEyes: whether the o's eyes are drawn; left out where they are drawn apart, to move
    public static func drawWordmark(
        in context: CGContext,
        x: CGFloat,
        baseline: CGFloat,
        font: CTFont,
        ink: CGColor,
        isDrawingEyes: Bool = true
    ) {
        layOutWordmark(in: context, x: x, baseline: baseline, font: font, ink: ink, isDrawingEyes: isDrawingEyes)
    }

    /// The box the wordmark fills when its first letter starts at the origin on a baseline at y 0,
    /// trajectory and the rook's head included.
    public static func wordmarkBounds(font: CTFont) -> CGRect {
        let size = CTFontGetSize(font)
        let xHeight = CTFontGetXHeight(font)
        let stroke = xHeight * strokeShare
        let head = xHeight * headShare
        let width = layOutWordmark(in: nil, x: 0, baseline: 0, font: font, ink: nil, isDrawingEyes: false)
        let top = min(-CTFontGetCapHeight(font) * 1.08, -xHeight - head * 0.72 - stroke)
        let left = -size * 0.5
        let right = width + head * 1.8 + stroke * 3
        return CGRect(x: left, y: top, width: right - left, height: size * 0.82 - top)
    }

    /// Where the centres of the o's eyes fall when the first letter starts at the origin on a baseline at
    /// y 0, left eye first.
    public static func eyeCenters(font: CTFont) -> [CGPoint] {
        let size = CTFontGetSize(font)
        let xHeight = CTFontGetXHeight(font)
        let spacing = size * letterSpacing
        let first = advance(of: "r", font: font) + spacing + xHeight / 2
        return [
            CGPoint(x: first, y: -xHeight / 2),
            CGPoint(x: first + xHeight + spacing, y: -xHeight / 2),
        ]
    }

    /// Draw the icon's mark, the pair of eyes over the trajectory, filling a square.
    ///
    /// - Parameters:
    ///   - context: a context whose y axis points down
    ///   - rect: the square to fill
    ///   - ink: the one color it is drawn in
    ///   - hasTrajectory: whether the sweep is drawn under the eyes; left out at menu bar size
    public static func drawMark(in context: CGContext, rect: CGRect, ink: CGColor, hasTrajectory: Bool = true) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / markSide, y: rect.height / markSide)
        let xHeight: CGFloat = 34
        let gap: CGFloat = 9
        let left = (markSide - (xHeight * 2 + gap)) / 2
        let centerY: CGFloat = hasTrajectory ? 50 : 54
        drawEye(in: context, center: CGPoint(x: left + xHeight / 2, y: centerY), xHeight: xHeight, side: 1, ink: ink)
        drawEye(in: context, center: CGPoint(x: left + xHeight * 1.5 + gap, y: centerY), xHeight: xHeight, side: -1, ink: ink)
        if hasTrajectory {
            drawTrajectory(
                in: context,
                through: [CGPoint(x: 16, y: 74), CGPoint(x: 44, y: 80), CGPoint(x: 70, y: 76), CGPoint(x: 86, y: 60)],
                width: 3,
                isBlunt: false,
                ink: ink
            )
        }
    }

    /// Draw one eye, as `BrandEye` shapes it.
    ///
    /// - Parameters:
    ///   - context: a context whose y axis points down
    ///   - center: the ring's centre
    ///   - xHeight: the ring's diameter, the letters' x-height
    ///   - side: 1 for the eye on the left, whose inner side is to its right; -1 for the other
    ///   - ink: the one color it is drawn in
    static func drawEye(in context: CGContext, center: CGPoint, xHeight: CGFloat, side: CGFloat, ink: CGColor) {
        let eye = BrandEye(xHeight: xHeight, side: side)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.setFillColor(ink)
        context.saveGState()
        context.addPath(eye.opening)
        context.clip()
        context.addPath(eye.ring)
        context.fillPath(using: .evenOdd)
        context.fillEllipse(in: CGRect(
            x: eye.pupilCenter.x - eye.pupilRadius,
            y: eye.pupilCenter.y - eye.pupilRadius,
            width: eye.pupilRadius * 2,
            height: eye.pupilRadius * 2
        ))
        context.restoreGState()
        context.addPath(eye.brow)
        context.fillPath()
    }

    /// Draw the trajectory: a cubic curve through four control points that swells from nothing toward
    /// its leading end, where it stops in a point, or, blunt, at its full width as a letter's stroke.
    static func drawTrajectory(in context: CGContext, through listPoints: [CGPoint], width: CGFloat, isBlunt: Bool, ink: CGColor) {
        guard listPoints.count == 4 else {
            return
        }
        let stepCount = 72
        let point: (CGFloat) -> CGPoint = { u in
            cubicPoint(listPoints, at: u)
        }
        var listUpper: [CGPoint] = []
        var listLower: [CGPoint] = []
        for step in 0...stepCount {
            let u = CGFloat(step) / CGFloat(stepCount)
            let here = point(u)
            let ahead = point(min(1, u + 0.01))
            let behind = point(max(0, u - 0.01))
            let dx = ahead.x - behind.x
            let dy = ahead.y - behind.y
            let length = max(hypot(dx, dy), 0.0001)
            let taper = !isBlunt && u > 0.9 ? (1 - u) / 0.1 : 1
            let half = width * pow(u, isBlunt ? 0.55 : 0.7) * taper / 2
            listUpper.append(CGPoint(x: here.x - dy / length * half, y: here.y + dx / length * half))
            listLower.append(CGPoint(x: here.x + dy / length * half, y: here.y - dx / length * half))
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(ink)
        context.addLines(between: listUpper + listLower.reversed())
        context.closePath()
        context.fillPath()
    }

    /// The point a cubic curve through four control points reaches at `u`, from 0 to 1.
    static func cubicPoint(_ listPoints: [CGPoint], at u: CGFloat) -> CGPoint {
        let v = 1 - u
        let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
        return CGPoint(
            x: a * listPoints[0].x + b * listPoints[1].x + c * listPoints[2].x + d * listPoints[3].x,
            y: a * listPoints[0].y + b * listPoints[1].y + c * listPoints[2].y + d * listPoints[3].y
        )
    }

    private static func advance(of letter: String, font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: letter,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Set the wordmark, or with no context only measure it. Returns where its last letter ends.
    @discardableResult
    private static func layOutWordmark(
        in context: CGContext?,
        x: CGFloat,
        baseline: CGFloat,
        font: CTFont,
        ink: CGColor?,
        isDrawingEyes: Bool
    ) -> CGFloat {
        let size = CTFontGetSize(font)
        let xHeight = CTFontGetXHeight(font)
        let stroke = xHeight * strokeShare
        let spacing = size * letterSpacing
        var cursor = x
        for (index, character) in word.enumerated() {
            if index == 1 || index == 2 {
                if let context, let ink, isDrawingEyes {
                    drawEye(in: context, center: CGPoint(x: cursor + xHeight / 2, y: baseline - xHeight / 2), xHeight: xHeight, side: index == 1 ? 1 : -1, ink: ink)
                }
                cursor += xHeight + spacing
                continue
            }
            let advance = advance(of: String(character), font: font)
            if let context, let ink {
                if character == "y" {
                    drawJoinedY(in: context, start: x, cursor: cursor, baseline: baseline, advance: advance, size: size, xHeight: xHeight, stroke: stroke, ink: ink)
                } else {
                    context.saveGState()
                    context.translateBy(x: cursor, y: baseline)
                    context.scaleBy(x: 1, y: -1)
                    context.textPosition = .zero
                    let colored = CTLineCreateWithAttributedString(NSAttributedString(
                        string: String(character),
                        attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): font,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                        ]
                    ))
                    CTLineDraw(colored, context)
                    context.restoreGState()
                }
            }
            cursor += advance + spacing
        }
        return cursor - spacing
    }

    /// The y as a rook: in place of its long stroke the trajectory, which comes in under the word and runs
    /// up through the arm's foot to the letter's top right; its arm a wing swept back, fine at its tip and
    /// widening into the trajectory where it meets it; and from the trajectory's end, in one line of its
    /// weight, the neck rising on over a low crown and down the forehead into a long beak facing on, back
    /// along its underside and into the chin.
    private static func drawJoinedY(
        in context: CGContext,
        start: CGFloat,
        cursor: CGFloat,
        baseline: CGFloat,
        advance: CGFloat,
        size: CGFloat,
        xHeight: CGFloat,
        stroke: CGFloat,
        ink: CGColor
    ) {
        let foot = CGPoint(x: cursor + advance * 0.47, y: baseline)
        let top = CGPoint(x: cursor + advance * 0.96, y: baseline - xHeight)
        let below = CGPoint(x: foot.x + (foot.x - top.x) * 0.75, y: foot.y + (foot.y - top.y) * 0.75)
        let listSweep = [
            CGPoint(x: start - size * 0.5, y: baseline + size * 0.58),
            CGPoint(x: start + (cursor - start) * 0.45, y: baseline + size * 0.8),
            below,
            top,
        ]
        drawTrajectory(in: context, through: listSweep, width: stroke * 1.08, isBlunt: true, ink: ink)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(ink)
        context.addPath(wing(sweptInto: listSweep, armTop: CGPoint(x: cursor + advance * 0.04, y: baseline - xHeight), foot: foot, stroke: stroke))
        context.fillPath()
        context.addPath(head(from: top, below: below, xHeight: xHeight))
        context.setStrokeColor(ink)
        context.setLineWidth(stroke * 1.08)
        context.setLineJoin(.miter)
        context.setMiterLimit(12)
        context.setLineCap(.butt)
        context.strokePath()
    }

    /// The y's arm as a wing: from a fine tip up at the left, its leading edge bowed out and its trailing
    /// edge drawn in, down to where its centre line meets the trajectory's, so it runs into the trajectory
    /// rather than through it.
    private static func wing(sweptInto listSweep: [CGPoint], armTop: CGPoint, foot: CGPoint, stroke: CGFloat) -> CGPath {
        let from = CGPoint(x: armTop.x + stroke * 0.55, y: armTop.y)
        let side: (CGPoint) -> CGFloat = { point in
            (foot.x - from.x) * (point.y - from.y) - (foot.y - from.y) * (point.x - from.x)
        }
        var meet = foot
        var previous = cubicPoint(listSweep, at: 0.5)
        let stepCount = 400
        for step in 1...stepCount {
            let here = cubicPoint(listSweep, at: 0.5 + CGFloat(step) / CGFloat(stepCount) * 0.5)
            if (side(here) < 0) != (side(previous) < 0) {
                meet = here
                break
            }
            previous = here
        }
        let share = (meet.y - from.y) / (foot.y - from.y)
        let root = CGPoint(x: from.x + (foot.x - from.x) * share, y: meet.y)
        let tip = CGPoint(x: armTop.x - stroke * 0.7, y: armTop.y - stroke * 0.9)
        let rootFront = CGPoint(x: root.x + stroke * 0.75, y: root.y)
        let rootBack = CGPoint(x: root.x - stroke * 0.75, y: root.y)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addCurve(
            to: rootFront,
            control1: CGPoint(x: tip.x + stroke * 2.4, y: tip.y + stroke * 0.1),
            control2: CGPoint(x: rootFront.x + stroke * 0.2, y: rootFront.y - stroke * 2.2)
        )
        path.addLine(to: rootBack)
        path.addCurve(
            to: tip,
            control1: CGPoint(x: rootBack.x - stroke * 0.5, y: rootBack.y - stroke * 1.7),
            control2: CGPoint(x: tip.x + stroke * 1.1, y: tip.y + stroke * 1.5)
        )
        path.closeSubpath()
        return path
    }

    /// The rook's head as one line from the trajectory's end, going on the way the trajectory goes; it
    /// starts a little inside the trajectory so the two meet without a seam.
    private static func head(from top: CGPoint, below: CGPoint, xHeight: CGFloat) -> CGPath {
        let scale = xHeight * headShare
        let length = max(hypot(top.x - below.x, top.y - below.y), 0.0001)
        let direction = CGPoint(x: (top.x - below.x) / length, y: (top.y - below.y) / length)
        let at: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: top.x + x * scale, y: top.y + y * scale)
        }
        let overlap = xHeight * strokeShare * 0.6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: top.x - direction.x * overlap, y: top.y - direction.y * overlap))
        path.addLine(to: top)
        path.addCurve(
            to: at(0.38, -0.66),
            control1: CGPoint(x: top.x + direction.x * scale * 0.3, y: top.y + direction.y * scale * 0.3),
            control2: at(0.12, -0.62)
        )
        path.addCurve(to: at(1.05, -0.45), control1: at(0.6, -0.68), control2: at(0.85, -0.55))
        path.addLine(to: at(1.78, -0.16))
        path.addLine(to: at(1.0, -0.15))
        path.addCurve(to: at(0.77, 0.05), control1: at(0.9, -0.12), control2: at(0.82, -0.05))
        return path
    }
}

/// One of the mark's eyes, as shapes about its centre in a space whose y axis points down: a ring the
/// weight of the letters showing only under a heavy brow that drops steeply toward the other eye and
/// ends in a point past the ring, and a small pupil pressed up under the brow, looking inward. It also
/// says how the eye moves: the pupil slides along under the brow to look aside, and the brow comes down
/// over the ring to shut it.
public struct BrandEye {
    /// The ring, to fill even-odd.
    public let ring: CGPath
    /// The region under the brow the ring and the pupil show in.
    public let opening: CGPath
    /// The brow.
    public let brow: CGPath
    public let pupilCenter: CGPoint
    public let pupilRadius: CGFloat
    /// How far the pupil moves either way to look aside.
    public let lookReach: CGFloat
    /// How far the pupil drops for each point it moves right, keeping to the brow.
    public let pupilSlope: CGFloat
    /// How far the brow and the opening come down to shut the eye.
    public let closingDrop: CGFloat

    /// The shapes of an eye.
    ///
    /// - Parameters:
    ///   - xHeight: the ring's diameter, the letters' x-height
    ///   - side: 1 for the eye on the left, whose inner side is to its right; -1 for the other
    public init(xHeight: CGFloat, side: CGFloat) {
        let radius = xHeight / 2
        let stroke = xHeight * BrandMark.strokeShare
        let outerY = -radius * 0.78
        let innerY = -radius * 0.02
        let browY: (CGFloat) -> CGFloat = { x in
            outerY + (innerY - outerY) * ((x * side + radius) / (radius * 2))
        }
        let reach = radius * 1.4
        let opening = CGMutablePath()
        opening.addLines(between: [
            CGPoint(x: -reach, y: browY(-reach)),
            CGPoint(x: reach, y: browY(reach)),
            CGPoint(x: reach, y: reach),
            CGPoint(x: -reach, y: reach),
        ])
        opening.closeSubpath()
        self.opening = opening
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        let inner = radius - stroke
        ring.addEllipse(in: CGRect(x: -inner, y: -inner, width: inner * 2, height: inner * 2))
        self.ring = ring
        let pupilX = radius * 0.2 * side
        pupilCenter = CGPoint(x: pupilX, y: browY(pupilX) + radius * 0.36)
        pupilRadius = radius * 0.27
        let outerX = -radius * 1.02 * side
        let innerX = radius * 1.32 * side
        let lid = stroke * 1.15
        let brow = CGMutablePath()
        brow.addLines(between: [
            CGPoint(x: outerX, y: browY(outerX)),
            CGPoint(x: innerX, y: browY(innerX) + lid * 0.15),
            CGPoint(x: radius * 0.55 * side, y: browY(radius * 0.55 * side) + lid),
            CGPoint(x: outerX, y: browY(outerX) + lid),
        ])
        brow.closeSubpath()
        self.brow = brow
        lookReach = radius * 0.34
        pupilSlope = (innerY - outerY) * side / (radius * 2)
        closingDrop = radius * 1.85
    }
}
