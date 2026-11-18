import AppKit
import CoreText
import os
import RookeryCore
import SwiftUI

/// Rookery's logo at the top of the sidebar: the wordmark, its two o's a crow's glaring eyes that look
/// about and blink, and its y a rook, in the theme's text color at the screen's full resolution. A build
/// without the typeface shows the name in text.
struct RookeryLogo: View {
    private static let name = "Rookery"
    private static let fallbackFontSize: CGFloat = 15

    var body: some View {
        if let font = BrandArt.wordmarkFont {
            let size = BrandMark.wordmarkBounds(font: font).integral.size
            AnimatedWordmark(font: font)
                .frame(width: size.width, height: size.height)
                .accessibilityElement()
                .accessibilityLabel(Self.name)
        } else {
            Text(Self.name)
                .font(.system(size: Self.fallbackFontSize, weight: .bold))
        }
    }
}

/// Rookery's mark as one-color template images the interface tints: the wordmark for the sidebar and the
/// pair of eyes for the menu bar, each drawn by `BrandMark` whenever AppKit renders it, so it is sharp at
/// any scale.
@MainActor
enum BrandArt {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "stage")
    /// The wordmark's type size in the sidebar.
    private static let wordmarkSize: CGFloat = 19
    /// The menu bar mark's side, as the menu bar sizes its icons.
    private static let menuBarSide: CGFloat = 18

    /// The sidebar's wordmark typeface at its size, or nil when the typeface is missing from the app.
    static let wordmarkFont: CTFont? = makeWordmarkFont()

    /// The menu bar's mark: the pair of eyes as a template the menu bar tints.
    static func menuBarImage() -> NSImage {
        let side = menuBarSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            BrandMark.drawMark(in: context, rect: rect.insetBy(dx: -1, dy: -1), ink: NSColor.black.cgColor, hasTrajectory: false)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rookery"
        return image
    }

    private static func makeWordmarkFont() -> CTFont? {
        guard let url = Bundle.main.url(forResource: BrandMark.fontResource, withExtension: BrandMark.fontExtension, subdirectory: BrandMark.fontDirectory) else {
            logger.error("no wordmark typeface in the app")
            return nil
        }
        do {
            return try BrandMark.font(at: url, size: wordmarkSize)
        } catch {
            logger.error("cannot read the wordmark typeface: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// The wordmark with eyes that move, in the theme's text color.
struct AnimatedWordmark: NSViewRepresentable {
    let font: CTFont

    func makeNSView(context: Context) -> AnimatedWordmarkView {
        AnimatedWordmarkView(font: font)
    }

    func updateNSView(_ view: AnimatedWordmarkView, context: Context) {
        view.ink = StageColors.primaryText.color(in: context.environment.stageTheme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedWordmarkView, context: Context) -> CGSize? {
        BrandMark.wordmarkBounds(font: font).integral.size
    }
}

/// The wordmark drawn as layers: the word without its eyes as a mask over the ink, and each eye as its
/// ring and pupil showing under its brow. Every seven seconds the eyes look left, then right, then ahead
/// again, and blink twice, as animations the render server plays, so the app does no work for them;
/// with reduced motion they stay still.
final class AnimatedWordmarkView: NSView {
    /// How long one round of looking about and blinking takes, in seconds.
    private static let loopDuration: CFTimeInterval = 7
    /// Where the eyes look through the round, from -1 left to 1 right, at each moment in seconds.
    private static let listLookKeys: [(time: CFTimeInterval, look: CGFloat)] = [
        (0, 0), (1.6, 0), (1.9, -1), (2.8, -1), (3.3, 1), (4.0, 1), (4.4, 0), (7, 0),
    ]
    /// How far the eyes are shut through the round, from 0 open to 1 shut, at each moment in seconds.
    private static let listBlinkKeys: [(time: CFTimeInterval, closing: CGFloat)] = [
        (0, 0), (4.9, 0), (4.97, 1), (5.01, 1), (5.13, 0), (5.3, 0), (5.37, 1), (5.41, 1), (5.53, 0), (7, 0),
    ]

    var ink: NSColor = .labelColor {
        didSet {
            if ink != oldValue {
                applyInk()
            }
        }
    }

    private let font: CTFont
    private let wordBounds: CGRect
    private let inkLayer = CALayer()
    private let wordMask = CALayer()
    private var listShapes: [CAShapeLayer] = []

    init(font: CTFont) {
        self.font = font
        wordBounds = BrandMark.wordmarkBounds(font: font).integral
        super.init(frame: CGRect(origin: .zero, size: wordBounds.size))
        wantsLayer = true
        inkLayer.mask = wordMask
        layer?.addSublayer(inkLayer)
        let xHeight = CTFontGetXHeight(font)
        for (index, center) in BrandMark.eyeCenters(font: font).enumerated() {
            addEye(
                BrandEye(xHeight: xHeight, side: index == 0 ? 1 : -1),
                at: CGPoint(x: center.x - wordBounds.minX, y: center.y - wordBounds.minY),
                radius: xHeight / 2
            )
        }
        applyInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.frame = bounds
        wordMask.frame = inkLayer.bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawWord()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawWord()
    }

    /// Draw the word without its eyes into the mask, at the screen's resolution.
    private func drawWord() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((wordBounds.width * scale).rounded(.up))
        let height = Int((wordBounds.height * scale).rounded(.up))
        guard
            width > 0,
            height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        BrandMark.drawWordmark(
            in: context,
            x: -wordBounds.minX,
            baseline: -wordBounds.minY,
            font: font,
            ink: CGColor(gray: 0, alpha: 1),
            isDrawingEyes: false
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wordMask.contents = context.makeImage()
        wordMask.contentsScale = scale
        CATransaction.commit()
    }

    /// Lay out one eye about its centre: its ring and pupil in a holder cut to the opening under the
    /// brow, the brow over them, and the round of looking about and blinking on the pupil, the opening
    /// and the brow.
    private func addEye(_ eye: BrandEye, at center: CGPoint, radius: CGFloat) {
        let box = CGRect(x: -radius * 2, y: -radius * 2, width: radius * 4, height: radius * 4)
        let holder = CALayer()
        holder.bounds = box
        holder.position = center
        let shown = CALayer()
        shown.bounds = box
        shown.position = .zero
        let opening = CAShapeLayer()
        opening.bounds = box
        opening.position = .zero
        opening.path = eye.opening
        shown.mask = opening
        let ring = CAShapeLayer()
        ring.bounds = box
        ring.position = .zero
        ring.path = eye.ring
        ring.fillRule = .evenOdd
        let pupil = CAShapeLayer()
        pupil.path = CGPath(
            ellipseIn: CGRect(x: -eye.pupilRadius, y: -eye.pupilRadius, width: eye.pupilRadius * 2, height: eye.pupilRadius * 2),
            transform: nil
        )
        pupil.position = eye.pupilCenter
        shown.addSublayer(ring)
        shown.addSublayer(pupil)
        let brow = CAShapeLayer()
        brow.bounds = box
        brow.position = .zero
        brow.path = eye.brow
        holder.addSublayer(shown)
        holder.addSublayer(brow)
        layer?.addSublayer(holder)
        listShapes += [ring, pupil, brow]
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }
        pupil.add(Self.loop(
            keyPath: "position",
            listKeys: Self.listLookKeys.map { key in
                (key.time, NSValue(point: CGPoint(
                    x: eye.pupilCenter.x + key.look * eye.lookReach,
                    y: eye.pupilCenter.y + key.look * eye.lookReach * eye.pupilSlope
                )))
            }
        ), forKey: "look")
        for shutting in [opening, brow] {
            shutting.add(Self.loop(
                keyPath: "position.y",
                listKeys: Self.listBlinkKeys.map { key in (key.time, NSNumber(value: Double(key.closing * eye.closingDrop))) }
            ), forKey: "blink")
        }
    }

    /// An animation that runs through values at moments of the round, easing between them, forever.
    private static func loop(keyPath: String, listKeys: [(CFTimeInterval, Any)]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = listKeys.map(\.1)
        animation.keyTimes = listKeys.map { NSNumber(value: $0.0 / loopDuration) }
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: max(listKeys.count - 1, 1)
        )
        animation.duration = loopDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk()
    }

    /// Color the word and the eyes, the ink taken in the view's own appearance.
    private func applyInk() {
        var color = ink.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = ink.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.backgroundColor = color
        for shape in listShapes {
            shape.fillColor = color
        }
        CATransaction.commit()
    }
}

