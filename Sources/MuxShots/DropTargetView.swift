import AppKit
import MuxShotsCore

/// Where a window dropped on the tray goes.
enum DropTarget: Equatable {
    case group(GroupId)
    case newGroup
    case release
}

/// One drop target on the tray: a labelled tile that lights up while the cursor is over it.
final class DropTargetView: NSView {
    private static let minimumWidth: CGFloat = 96
    private static let height: CGFloat = 52
    private static let cornerRadius: CGFloat = 10
    private static let horizontalPadding: CGFloat = 14
    private static let restingAlpha: CGFloat = 0.12
    private static let highlightedAlpha: CGFloat = 0.9

    let target: DropTarget

    /// Whether the cursor is over this target.
    var isHighlighted = false {
        didSet {
            updateBackground()
        }
    }

    init(target: DropTarget, title: String, subtitle: String?) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(subtitleLabel)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalPadding),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateBackground() {
        let color: NSColor = switch (target, isHighlighted) {
        case (.release, true):
            .systemRed.withAlphaComponent(Self.highlightedAlpha)
        case (_, true):
            .controlAccentColor.withAlphaComponent(Self.highlightedAlpha)
        case (_, false):
            .labelColor.withAlphaComponent(Self.restingAlpha)
        }
        layer?.backgroundColor = color.cgColor
    }
}
