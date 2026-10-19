import AppKit
import MuxShotsCore

/// A group row: its members' stacked application icons, its editable name and its size.
final class GroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("group")
    static let rowHeight: CGFloat = 34
    private static let iconSize: CGFloat = 18
    private static let iconOverlap: CGFloat = -7
    private static let maximumIcons = 3

    private let iconStack = NSStackView()
    private let nameField = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(nameDelegate: NSTextFieldDelegate) {
        super.init(frame: .zero)
        identifier = Self.identifier

        iconStack.orientation = .horizontal
        iconStack.spacing = Self.iconOverlap
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.isEditable = true
        nameField.focusRingType = .none
        nameField.delegate = nameDelegate
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        textField = nameField

        let row = NSStackView(views: [iconStack, nameField, countLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor
    func show(_ group: WindowGroup) {
        nameField.stringValue = group.name
        countLabel.stringValue = String(group.listMembers.count)
        for view in iconStack.arrangedSubviews {
            iconStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for member in group.listMembers.prefix(Self.maximumIcons) {
            let imageView = NSImageView(image: ApplicationIcon.icon(forBundleId: member.application.bundleId)
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
                ?? NSImage())
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
                imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            ])
            iconStack.addArrangedSubview(imageView)
        }
    }
}

/// A window row: the application icon beside the window title and the application name.
final class WindowCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("window")
    static let rowHeight: CGFloat = 38
    private static let iconSize: CGFloat = 22

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let applicationLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        applicationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        applicationLabel.textColor = .secondaryLabelColor
        applicationLabel.lineBreakMode = .byTruncatingTail
        imageView = iconView
        textField = titleLabel

        let labels = NSStackView(views: [titleLabel, applicationLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [iconView, labels])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @MainActor
    func show(_ window: ManagedWindow) {
        titleLabel.stringValue = window.title.isEmpty ? "Untitled" : window.title
        applicationLabel.stringValue = window.application.name
        iconView.image = ApplicationIcon.icon(forBundleId: window.application.bundleId)
    }
}
