import AppKit
import QuartzCore

/// Animates a window-shaped ghost flying from a dropped window into its tray target.
@MainActor
final class DropGhostAnimator {
    private static let duration: CFTimeInterval = 0.42
    private static let cornerRadius: CGFloat = 14
    private static let iconSize: CGFloat = 72
    private static let finalOpacity: Float = 0.15
    private static let flightTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)

    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let contentView = NSView()
        contentView.wantsLayer = true
        panel.contentView = contentView
    }

    /// Fly a ghost of a window into a target.
    ///
    /// - Parameters:
    ///   - windowFrame: the window's frame, in AppKit screen coordinates
    ///   - targetFrame: the target's frame, in AppKit screen coordinates
    ///   - icon: the window's application icon, drawn at the ghost's center
    ///   - completion: called once the ghost has landed
    func fly(
        from windowFrame: CGRect,
        to targetFrame: CGRect,
        icon: NSImage?,
        completion: @escaping @MainActor () -> Void
    ) {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main,
            let rootLayer = panel.contentView?.layer
        else {
            completion()
            return
        }
        panel.setFrame(screen.frame, display: false)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let startFrame = windowFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let endFrame = targetFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)

        let ghost = CALayer()
        ghost.frame = startFrame
        ghost.cornerRadius = Self.cornerRadius
        ghost.cornerCurve = .continuous
        ghost.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        ghost.borderColor = NSColor.separatorColor.cgColor
        ghost.borderWidth = 1
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowOpacity = 0.3
        ghost.shadowRadius = 24
        ghost.shadowOffset = CGSize(width: 0, height: -10)
        if let icon {
            let iconLayer = CALayer()
            iconLayer.contents = icon
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.frame = CGRect(
                x: (startFrame.width - Self.iconSize) / 2,
                y: (startFrame.height - Self.iconSize) / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            ghost.addSublayer(iconLayer)
        }
        rootLayer.addSublayer(ghost)
        panel.orderFrontRegardless()

        let scale = min(endFrame.width / startFrame.width, endFrame.height / startFrame.height)
        let position = CABasicAnimation(keyPath: "position")
        position.toValue = CGPoint(x: endFrame.midX, y: endFrame.midY)
        let transform = CABasicAnimation(keyPath: "transform.scale")
        transform.toValue = scale
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.toValue = Self.finalOpacity
        let group = CAAnimationGroup()
        group.animations = [position, transform, opacity]
        group.duration = Self.duration
        group.timingFunction = Self.flightTiming
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                ghost.removeFromSuperlayer()
                completion()
            }
        }
        ghost.add(group, forKey: "fly")
        CATransaction.commit()
    }
}
