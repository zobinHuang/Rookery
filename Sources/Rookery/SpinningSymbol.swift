import AppKit
import SwiftUI

/// A symbol in the secondary label color that turns while something is in progress and finishes its turn
/// when it ends. Core Animation turns it, so the stage draws nothing while it spins: a SwiftUI animation
/// redraws the whole stage on every frame, a full core's worth while the limits are read.
struct SpinningSymbol: NSViewRepresentable {
    let systemName: String
    let pointSize: CGFloat
    let weight: NSFont.Weight
    let isSpinning: Bool

    func makeNSView(context: Context) -> SpinningSymbolView {
        SpinningSymbolView(systemName: systemName, pointSize: pointSize, weight: weight)
    }

    func updateNSView(_ nsView: SpinningSymbolView, context: Context) {
        nsView.isSpinning = isSpinning
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinningSymbolView, context: Context) -> CGSize? {
        nsView.symbolSize
    }
}

/// The view behind `SpinningSymbol`: a layer in the label color, masked to the symbol's shape.
final class SpinningSymbolView: NSView {
    private static let turnSeconds: CFTimeInterval = 1
    private static let fullTurn = -2 * CGFloat.pi
    private static let rotationKeyPath = "transform.rotation.z"
    private static let animationKey = "spin"

    /// The symbol's size at its point size and weight.
    let symbolSize: CGSize
    private let symbol = CALayer()

    /// Whether the symbol turns; it finishes the turn it is in when this becomes false.
    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else {
                return
            }
            if isSpinning {
                startSpinning()
            } else {
                finishTurn()
            }
        }
    }

    init(systemName: String, pointSize: CGFloat, weight: NSFont.Weight) {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        symbolSize = image?.size ?? .zero
        super.init(frame: CGRect(origin: .zero, size: symbolSize))
        wantsLayer = true
        let mask = CALayer()
        mask.frame = CGRect(origin: .zero, size: symbolSize)
        mask.contents = image
        mask.contentsGravity = .resizeAspect
        symbol.frame = CGRect(origin: .zero, size: symbolSize)
        symbol.mask = mask
        layer?.addSublayer(symbol)
    }

    required init?(coder: NSCoder) {
        nil
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
        symbol.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            symbol.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func startSpinning() {
        let animation = CABasicAnimation(keyPath: Self.rotationKeyPath)
        animation.fromValue = 0
        animation.toValue = Self.fullTurn
        animation.duration = Self.turnSeconds
        animation.repeatCount = .infinity
        symbol.add(animation, forKey: Self.animationKey)
    }

    /// Turn on from where the symbol is to the end of its turn, at the same speed, and stop there.
    private func finishTurn() {
        let angle = symbol.presentation()?.value(forKeyPath: Self.rotationKeyPath) as? CGFloat ?? 0
        symbol.removeAnimation(forKey: Self.animationKey)
        guard angle != 0 else {
            return
        }
        let animation = CABasicAnimation(keyPath: Self.rotationKeyPath)
        animation.fromValue = angle
        animation.toValue = Self.fullTurn
        animation.duration = Self.turnSeconds * Double((Self.fullTurn - angle) / Self.fullTurn)
        symbol.add(animation, forKey: Self.animationKey)
    }
}
