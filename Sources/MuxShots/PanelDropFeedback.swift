import AppKit

/// The panel's feedback while a window is dragged over it: a glowing edge, a banner naming what a drop
/// would do, a card around the target group and a "New Group" zone at the bottom.
@MainActor
final class PanelDropFeedback {
    private static let fadeDuration: TimeInterval = 0.18
    private static let moveDuration: TimeInterval = 0.24
    private static let glowWidth: CGFloat = 2.5
    private static let windowCornerRadius: CGFloat = 16
    private static let cardCornerRadius: CGFloat = 10
    private static let cardOutset: CGFloat = 4
    private static let zoneHeight: CGFloat = 52
    private static let zoneMargin: CGFloat = 10
    private static let bannerTopOffset: CGFloat = 32

    private let outlineView: NSOutlineView
    private let scrollView: NSScrollView
    private let glowView = NSView()
    private let bannerView = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let cardView = NSView()
    private let zoneView = NewGroupZoneView()
    private var zoneBottomConstraint: NSLayoutConstraint?
    private var isCardShown = false
    private var resetTask: Task<Void, Never>?

    /// - Parameters:
    ///   - container: the panel's content view, which the edge, banner and zone overlay
    ///   - scrollView: the scroll view whose bottom inset makes room for the zone
    ///   - outlineView: the list the card is drawn in
    init(container: NSView, scrollView: NSScrollView, outlineView: NSOutlineView) {
        self.outlineView = outlineView
        self.scrollView = scrollView

        glowView.wantsLayer = true
        glowView.layer?.borderWidth = Self.glowWidth
        glowView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        glowView.layer?.cornerRadius = Self.windowCornerRadius
        glowView.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        glowView.layer?.shadowOpacity = 0.9
        glowView.layer?.shadowRadius = 8
        glowView.layer?.shadowOffset = .zero
        glowView.alphaValue = 0

        bannerView.wantsLayer = true
        bannerView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bannerView.layer?.cornerRadius = 13
        bannerView.alphaValue = 0
        bannerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
        bannerLabel.textColor = .white
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerView.addSubview(bannerLabel)

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = Self.cardCornerRadius
        cardView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        cardView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        cardView.layer?.borderWidth = 1.5
        cardView.alphaValue = 0
        outlineView.addSubview(cardView)

        zoneView.alphaValue = 0
        for view in [zoneView, bannerView, glowView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let zoneBottomConstraint = zoneView.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: Self.zoneHeight
        )
        self.zoneBottomConstraint = zoneBottomConstraint
        NSLayoutConstraint.activate([
            glowView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glowView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glowView.topAnchor.constraint(equalTo: container.topAnchor),
            glowView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bannerView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bannerView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.bannerTopOffset),
            bannerView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            bannerLabel.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 12),
            bannerLabel.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -12),
            bannerLabel.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 5),
            bannerLabel.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -5),
            zoneView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.zoneMargin),
            zoneView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.zoneMargin),
            zoneView.heightAnchor.constraint(equalToConstant: Self.zoneHeight),
            zoneBottomConstraint,
        ])
    }

    /// The "New Group" zone's frame on screen.
    var zoneScreenFrame: CGRect? {
        guard zoneView.alphaValue > 0, let window = zoneView.window else {
            return nil
        }
        return window.convertToScreen(zoneView.convert(zoneView.bounds, to: nil))
    }

    /// The target card's frame on screen.
    var cardScreenFrame: CGRect? {
        guard isCardShown, let window = cardView.window else {
            return nil
        }
        return window.convertToScreen(cardView.convert(cardView.bounds, to: nil))
    }

    /// Slide the "New Group" zone in as a drag begins.
    func begin() {
        resetTask?.cancel()
        scrollView.contentInsets.bottom = Self.zoneHeight + Self.zoneMargin * 2
        animate(duration: Self.moveDuration) {
            self.zoneBottomConstraint?.animator().constant = -Self.zoneMargin
            self.zoneView.animator().alphaValue = 1
        }
    }

    /// Show what a drop at the cursor would do.
    ///
    /// - Parameters:
    ///   - isInside: whether the cursor is over the panel
    ///   - message: the banner text, or nil for no banner
    ///   - cardRect: the target group's rows in the list's coordinates, or nil for no card
    ///   - isZoneHovered: whether the cursor is over the "New Group" zone
    func show(isInside: Bool, message: String?, cardRect: CGRect?, isZoneHovered: Bool) {
        zoneView.isHighlighted = isZoneHovered
        if let message {
            bannerLabel.stringValue = message
        }
        animate(duration: Self.fadeDuration) {
            self.glowView.animator().alphaValue = isInside ? 1 : 0
            self.bannerView.animator().alphaValue = message == nil ? 0 : 1
        }
        guard let cardRect else {
            isCardShown = false
            animate(duration: Self.fadeDuration) {
                self.cardView.animator().alphaValue = 0
            }
            return
        }
        let frame = cardRect.insetBy(dx: Self.cardOutset, dy: -Self.cardOutset / 2)
        if isCardShown {
            animate(duration: Self.moveDuration) {
                self.cardView.animator().frame = frame
            }
        } else {
            cardView.frame = frame
            animate(duration: Self.fadeDuration) {
                self.cardView.animator().alphaValue = 1
            }
        }
        isCardShown = true
    }

    /// Flash the card around rows that just received a window, then clear all feedback.
    ///
    /// - Parameter cardRect: the rows in the list's coordinates, or nil to clear at once
    func end(flashing cardRect: CGRect?) {
        isCardShown = false
        zoneView.isHighlighted = false
        if let cardRect {
            cardView.frame = cardRect.insetBy(dx: Self.cardOutset, dy: -Self.cardOutset / 2)
            cardView.alphaValue = 1
        }
        animate(duration: Self.moveDuration) {
            self.glowView.animator().alphaValue = 0
            self.bannerView.animator().alphaValue = 0
            self.zoneView.animator().alphaValue = 0
            self.zoneBottomConstraint?.animator().constant = Self.zoneHeight
            if cardRect == nil {
                self.cardView.animator().alphaValue = 0
            }
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else {
                return
            }
            scrollView.contentInsets.bottom = 8
            animate(duration: Self.moveDuration) {
                self.cardView.animator().alphaValue = 0
            }
        }
    }

    private func animate(duration: TimeInterval, _ changes: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            MainActor.assumeIsolated {
                changes()
                self.zoneView.superview?.layoutSubtreeIfNeeded()
            }
        }
    }
}

/// The dashed "New Group" drop zone at the bottom of the panel.
final class NewGroupZoneView: NSView {
    private let borderLayer = CAShapeLayer()
    private let label = NSTextField(labelWithString: "+  New Group")

    /// Whether the cursor is over the zone.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else {
                return
            }
            if isHighlighted {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            updateAppearance()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        layer?.addSublayer(borderLayer)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
        borderLayer.strokeColor = isHighlighted
            ? NSColor.clear.cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.6).cgColor
        CATransaction.commit()
        label.textColor = isHighlighted ? .white : .secondaryLabelColor
    }
}
