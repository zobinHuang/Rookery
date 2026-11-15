import AppKit
import SwiftUI

/// The selected tab's raised background, which slides to the tab selected next. Core Animation runs the
/// slide, so the stage draws nothing while it moves: a SwiftUI animation redraws the whole stage on every
/// frame, which made each tab switch cost a third of a second.
struct TabHighlight: NSViewRepresentable {
    /// Where the selected tab lies, in this view's coordinates; nil when no tab is selected.
    let frame: CGRect?

    func makeNSView(context: Context) -> TabHighlightView {
        TabHighlightView()
    }

    func updateNSView(_ nsView: TabHighlightView, context: Context) {
        nsView.theme = context.environment.stageTheme
        nsView.move(to: frame)
    }
}

/// The view behind `TabHighlight`: one layer, moved by spring animations the render server runs.
final class TabHighlightView: NSView {
    private static let cornerRadius: CGFloat = 9
    private static let shadowOpacity: Float = 0.12
    private static let shadowRadius: CGFloat = 3
    private static let shadowOffset = CGSize(width: 0, height: 1)
    /// Matches the spring the stage's other motion uses: a quarter second, barely overshooting.
    private static let springDuration: TimeInterval = 0.26
    private static let springBounce: CGFloat = 0.15
    /// The selected outline, drawn only by the high-contrast themes.
    private static let borderWidth: CGFloat = 1

    private let highlight = CALayer()

    /// The theme the highlight is drawn in.
    var theme = Theme.light {
        didSet {
            if theme != oldValue {
                needsDisplay = true
            }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        highlight.cornerRadius = Self.cornerRadius
        highlight.cornerCurve = .continuous
        highlight.borderWidth = Self.borderWidth
        highlight.shadowColor = NSColor.black.cgColor
        highlight.shadowOpacity = Self.shadowOpacity
        highlight.shadowRadius = Self.shadowRadius
        highlight.shadowOffset = Self.shadowOffset
        highlight.isHidden = true
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateLayer() {
        highlight.backgroundColor = StageColors.selectedTab.color(in: theme).cgColor
        highlight.borderColor = StageColors.contrastActiveBorder.color(in: theme).cgColor
    }

    /// Put the highlight over a tab, sliding there from the tab it was over.
    ///
    /// - Parameter frame: the tab's frame, or nil to hide the highlight
    func move(to frame: CGRect?) {
        guard let frame else {
            highlight.isHidden = true
            return
        }
        let wasShown = !highlight.isHidden
        let oldPosition = highlight.position
        let oldBounds = highlight.bounds
        let newPosition = CGPoint(x: frame.midX, y: frame.midY)
        let newBounds = CGRect(origin: .zero, size: frame.size)
        guard !wasShown || oldPosition != newPosition || oldBounds != newBounds else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = false
        highlight.position = newPosition
        highlight.bounds = newBounds
        highlight.shadowPath = CGPath(
            roundedRect: newBounds,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        CATransaction.commit()
        guard wasShown else {
            return
        }
        highlight.add(Self.slide(keyPath: "position", from: NSValue(point: oldPosition)), forKey: "position")
        highlight.add(Self.slide(keyPath: "bounds", from: NSValue(rect: oldBounds)), forKey: "bounds")
    }

    private static func slide(keyPath: String, from fromValue: NSValue) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: springDuration, bounce: springBounce)
        animation.keyPath = keyPath
        animation.fromValue = fromValue
        animation.duration = animation.settlingDuration
        return animation
    }
}
