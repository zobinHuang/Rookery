import CoreGraphics
import CoreText
import Foundation

/// Why Rookery's mark could not be drawn.
public enum BrandMarkError: Error, Equatable {
    /// The wordmark's typeface could not be read from where it was looked for.
    case fontUnreadable(URL)
}

/// Rookery's mark: the wordmark `rookery` in a wide geometric face, its two o's a crow's eyes glaring
/// under brows that drop toward each other, and the long stroke of its y running on into a trajectory
/// that sweeps under the whole word; for the app icon and the menu bar, the pair of eyes alone over the
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
    public static func drawWordmark(in context: CGContext, x: CGFloat, baseline: CGFloat, font: CTFont, ink: CGColor) {
        layOutWordmark(in: context, x: x, baseline: baseline, font: font, ink: ink)
    }

    /// The box the wordmark fills when its first letter starts at the origin on a baseline at y 0,
    /// trajectory included.
    public static func wordmarkBounds(font: CTFont) -> CGRect {
        let size = CTFontGetSize(font)
        let width = layOutWordmark(in: nil, x: 0, baseline: 0, font: font, ink: nil)
        let top = -CTFontGetCapHeight(font) * 1.08
        let left = -size * 0.5
        return CGRect(x: left, y: top, width: width - left, height: size * 0.82 - top)
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

    /// Draw one eye: a ring the weight of the letters, its top cut by a heavy brow that drops steeply
    /// toward the other eye and ends in a point past the ring, the small pupil pressed up under it.
    ///
    /// - Parameters:
    ///   - context: a context whose y axis points down
    ///   - center: the ring's centre
    ///   - xHeight: the ring's diameter, the letters' x-height
    ///   - side: 1 for the eye on the left, whose inner side is to its right; -1 for the other
    ///   - ink: the one color it is drawn in
    static func drawEye(in context: CGContext, center: CGPoint, xHeight: CGFloat, side: CGFloat, ink: CGColor) {
        let radius = xHeight / 2
        let stroke = xHeight * strokeShare
        let outerY = -radius * 0.78
        let innerY = -radius * 0.02
        let browY: (CGFloat) -> CGFloat = { x in
            outerY + (innerY - outerY) * ((x * side + radius) / (radius * 2))
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: center.x, y: center.y)
        context.setFillColor(ink)

        context.saveGState()
        context.addLines(between: [
            CGPoint(x: -radius * 1.4, y: browY(-radius * 1.4)),
            CGPoint(x: radius * 1.4, y: browY(radius * 1.4)),
            CGPoint(x: radius * 1.4, y: radius * 1.4),
            CGPoint(x: -radius * 1.4, y: radius * 1.4),
        ])
        context.closePath()
        context.clip()
        context.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        let inner = radius - stroke
        context.addEllipse(in: CGRect(x: -inner, y: -inner, width: inner * 2, height: inner * 2))
        context.fillPath(using: .evenOdd)
        let pupilX = radius * 0.2 * side
        let pupilRadius = radius * 0.27
        let pupilY = browY(pupilX) + radius * 0.36
        context.fillEllipse(in: CGRect(x: pupilX - pupilRadius, y: pupilY - pupilRadius, width: pupilRadius * 2, height: pupilRadius * 2))
        context.restoreGState()

        let outerX = -radius * 1.02 * side
        let innerX = radius * 1.32 * side
        let lid = stroke * 1.15
        context.addLines(between: [
            CGPoint(x: outerX, y: browY(outerX)),
            CGPoint(x: innerX, y: browY(innerX) + lid * 0.15),
            CGPoint(x: radius * 0.55 * side, y: browY(radius * 0.55 * side) + lid),
            CGPoint(x: outerX, y: browY(outerX) + lid),
        ])
        context.closePath()
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
            let v = 1 - u
            let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
            return CGPoint(
                x: a * listPoints[0].x + b * listPoints[1].x + c * listPoints[2].x + d * listPoints[3].x,
                y: a * listPoints[0].y + b * listPoints[1].y + c * listPoints[2].y + d * listPoints[3].y
            )
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

    /// Set the wordmark, or with no context only measure it. Returns where its last letter ends.
    @discardableResult
    private static func layOutWordmark(in context: CGContext?, x: CGFloat, baseline: CGFloat, font: CTFont, ink: CGColor?) -> CGFloat {
        let size = CTFontGetSize(font)
        let xHeight = CTFontGetXHeight(font)
        let stroke = xHeight * strokeShare
        let spacing = size * letterSpacing
        var cursor = x
        for (index, character) in word.enumerated() {
            if index == 1 || index == 2 {
                if let context, let ink {
                    drawEye(in: context, center: CGPoint(x: cursor + xHeight / 2, y: baseline - xHeight / 2), xHeight: xHeight, side: index == 1 ? 1 : -1, ink: ink)
                }
                cursor += xHeight + spacing
                continue
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(character),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            ))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
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

    /// The y: its short arm, and in place of its long stroke the trajectory, which comes in under the
    /// word, runs straight up through the arm's foot and ends at the letter's top right.
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
        context.saveGState()
        context.setFillColor(ink)
        context.addLines(between: [
            CGPoint(x: cursor + advance * 0.04, y: baseline - xHeight),
            CGPoint(x: cursor + advance * 0.04 + stroke * 1.1, y: baseline - xHeight),
            CGPoint(x: foot.x + stroke * 0.55, y: foot.y),
            CGPoint(x: foot.x - stroke * 0.55, y: foot.y),
        ])
        context.closePath()
        context.fillPath()
        context.restoreGState()
        let top = CGPoint(x: cursor + advance * 0.96, y: baseline - xHeight)
        let below = CGPoint(x: foot.x + (foot.x - top.x) * 0.75, y: foot.y + (foot.y - top.y) * 0.75)
        drawTrajectory(
            in: context,
            through: [
                CGPoint(x: start - size * 0.5, y: baseline + size * 0.58),
                CGPoint(x: start + (cursor - start) * 0.45, y: baseline + size * 0.8),
                below,
                top,
            ],
            width: stroke * 1.08,
            isBlunt: true,
            ink: ink
        )
    }
}
