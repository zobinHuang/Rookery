import AppKit
import CoreText
import ImageIO
import os
import RookeryCore
import SwiftUI

/// Rookery's logo at the top of the sidebar: the wordmark, its two o's a crow's glaring eyes and its y
/// running on into the sweep under the word, in the theme's text color at the screen's full resolution.
/// A build without the typeface shows the name in text.
struct RookeryLogo: View {
    private static let name = "Rookery"
    private static let fallbackFontSize: CGFloat = 15

    var body: some View {
        if let image = BrandArt.wordmark {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(StageColors.primaryText)
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

    /// The sidebar's wordmark, or nil when the typeface is missing from the app.
    static let wordmark: NSImage? = makeWordmark()

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

    private static func makeWordmark() -> NSImage? {
        guard let url = Bundle.main.url(forResource: BrandMark.fontResource, withExtension: BrandMark.fontExtension, subdirectory: BrandMark.fontDirectory) else {
            logger.error("no wordmark typeface in the app")
            return nil
        }
        let font: CTFont
        do {
            font = try BrandMark.font(at: url, size: wordmarkSize)
        } catch {
            logger.error("cannot read the wordmark typeface: \(String(describing: error), privacy: .public)")
            return nil
        }
        let bounds = BrandMark.wordmarkBounds(font: font).integral
        let image = NSImage(size: bounds.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            BrandMark.drawWordmark(in: context, x: -bounds.minX, baseline: -bounds.minY, font: font, ink: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A looping pixel animation: its distinct frames for a screen scale, the order they show in, and how fast.
struct PixelAnimation {
    /// The distinct frames drawn for a screen scale, 1 or 2; art drawn once returns the same for both.
    let framesForScale: @MainActor (Int) -> [CGImage]
    let listSequence: [Int]
    let framesPerSecond: Double
}

/// A view that plays a pixel animation in one layer: a discrete keyframe animation steps its contents
/// through the frames, scaled to the view without smoothing, in the render server, so the app does no work
/// while it loops. Set up again whenever the view lands in a window or on a screen of another scale; holds
/// still under Reduce Motion.
final class PixelAnimationView: NSView {
    private static let animationKey = "frames"
    private static let retinaScale = 2

    private let frameLayer = CALayer()
    private var animation: PixelAnimation?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.magnificationFilter = .nearest
        frameLayer.minificationFilter = .nearest
        frameLayer.contentsGravity = .resize
        layer?.addSublayer(frameLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Play another animation, from its start.
    func show(_ animation: PixelAnimation) {
        self.animation = animation
        play()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        play()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        play()
    }

    /// Show the frames drawn for this screen's scale, looping them unless Reduce Motion is on.
    private func play() {
        guard let window, let animation else {
            frameLayer.removeAnimation(forKey: Self.animationKey)
            return
        }
        let scale = window.backingScaleFactor > 1 ? Self.retinaScale : 1
        let listFrames = animation.framesForScale(scale)
        let listShown = animation.listSequence.compactMap { listFrames.indices.contains($0) ? listFrames[$0] : nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contentsScale = CGFloat(scale)
        frameLayer.contents = listShown.first
        CATransaction.commit()
        frameLayer.removeAnimation(forKey: Self.animationKey)
        guard
            listShown.count > 1,
            animation.framesPerSecond > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            return
        }
        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = listShown
        keyframes.calculationMode = .discrete
        keyframes.keyTimes = (0...listShown.count).map { NSNumber(value: Double($0) / Double(listShown.count)) }
        keyframes.duration = Double(listShown.count) / animation.framesPerSecond
        keyframes.repeatCount = .infinity
        frameLayer.add(keyframes, forKey: Self.animationKey)
    }
}
