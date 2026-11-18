import AppKit
import CoreText
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
