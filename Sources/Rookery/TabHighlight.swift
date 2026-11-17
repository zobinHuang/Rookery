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

/// The outline of a tab, a folder's tab standing on the content below it: square at the bottom, where it
/// meets the window, with a small round corner at the top left and a large one at the top right.
struct FolderTabShape: Shape {
    static let leadingRadius: CGFloat = 6
    static let trailingRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        Path(Self.outline(in: rect))
    }

    /// The outline in a rectangle whose top is its minimum y, left open along the bottom so a stroke
    /// leaves the edge the tab stands on undrawn.
    static func outline(in rect: CGRect) -> CGPath {
        let leading = min(leadingRadius, rect.width / 2, rect.height)
        let trailing = min(trailingRadius, rect.width - leading, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + leading))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + leading, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - trailing, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + trailing),
            control1: CGPoint(x: rect.maxX - trailing * 0.45, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + trailing * 0.55)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// The view behind `TabHighlight`: one shape layer whose outline springs from tab to tab, an animation
/// the render server runs.
final class TabHighlightView: NSView {
    private static let shadowOpacity: Float = 0.1
    private static let shadowRadius: CGFloat = 4
    private static let shadowOffset = CGSize(width: 0, height: -1)
    /// Matches the spring the stage's other motion uses: a quarter second, barely overshooting.
    private static let springDuration: TimeInterval = 0.26
    private static let springBounce: CGFloat = 0.12
    /// The selected outline, drawn only by the high-contrast themes.
    private static let borderWidth: CGFloat = 1

    private let highlight = CAShapeLayer()
    private var shownFrame: CGRect?

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
        highlight.lineWidth = Self.borderWidth
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        highlight.fillColor = StageColors.activeTab.color(in: theme).cgColor
        highlight.strokeColor = StageColors.contrastActiveBorder.color(in: theme).cgColor
    }

    /// Put the highlight over a tab, sliding there from the tab it was over.
    ///
    /// - Parameter frame: the tab's frame, or nil to hide the highlight
    func move(to frame: CGRect?) {
        guard let frame else {
            highlight.isHidden = true
            shownFrame = nil
            return
        }
        let oldFrame = highlight.isHidden ? nil : shownFrame
        guard oldFrame != frame else {
            return
        }
        let oldPath = highlight.path
        let newPath = FolderTabShape.outline(in: frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = false
        highlight.path = newPath
        highlight.shadowPath = newPath
        CATransaction.commit()
        shownFrame = frame
        guard oldFrame != nil, let oldPath else {
            return
        }
        highlight.add(Self.slide(keyPath: "path", from: oldPath), forKey: "path")
        highlight.add(Self.slide(keyPath: "shadowPath", from: oldPath), forKey: "shadowPath")
    }

    private static func slide(keyPath: String, from fromValue: CGPath) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: springDuration, bounce: springBounce)
        animation.keyPath = keyPath
        animation.fromValue = fromValue
        animation.duration = animation.settlingDuration
        return animation
    }
}
