import AppKit
import SwiftUI

/// A key a composer offers whoever holds it before acting on it itself, as Raven's suggestions take the
/// arrows and the launcher Escape.
enum ComposerKey {
    case up
    case down
    case tab
    case send
    case escape
    case deleteBackward
}

/// The text a composer is written in: AppKit's text view, which lays out only what shows, so a long paste
/// costs nothing while typing. Plain text only; Return is offered as Send, Shift-Return and Control-J
/// break the line, and while an input method composes every key is the input method's. It grows with
/// its text between two heights, scrolling past the taller.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    let isEnabled: Bool
    var isFocused: FocusState<Bool>.Binding
    /// The height the text needs, up to `maxHeight`, for the composer to size the field to.
    @Binding var contentHeight: CGFloat
    let maxHeight: CGFloat
    /// Takes a key; true when it acted on it, so the text view does not.
    let onKey: (ComposerKey) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onFocusChange = { [weak coordinator = context.coordinator] isFocused in
            coordinator?.noteFocus(isFocused)
        }
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        context.coordinator.textView = textView
        apply(to: textView, theme: context.environment.stageTheme, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else {
            return
        }
        apply(to: textView, theme: context.environment.stageTheme, coordinator: context.coordinator)
        if isFocused.wrappedValue, let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    private func apply(to textView: ComposerTextView, theme: Theme, coordinator: Coordinator) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let ink = StageColors.primaryText.color(in: theme)
        if textView.font != font || textView.textColor != ink {
            textView.font = font
            textView.textColor = ink
            textView.insertionPointColor = ink
            textView.typingAttributes = [.font: font, .foregroundColor: ink]
        }
        textView.placeholderColor = StageColors.tertiaryText.color(in: theme)
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.measure()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?

        init(parent: ComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }
            parent.text = textView.string
            textView.needsDisplay = true
            measure()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else {
                return false
            }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    _ = parent.onKey(.send)
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.deleteBackward(_:)):
                return parent.onKey(.deleteBackward)
            default:
                return false
            }
        }

        func noteFocus(_ isFocused: Bool) {
            guard parent.isFocused.wrappedValue != isFocused else {
                return
            }
            Task { @MainActor [weak self] in
                self?.parent.isFocused.wrappedValue = isFocused
            }
        }

        /// Report the height the text needs, laying out only as far as the tallest the field grows.
        func measure() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return
            }
            let width = max(textView.bounds.width, 1)
            layoutManager.ensureLayout(forBoundingRect: CGRect(x: 0, y: 0, width: width, height: parent.maxHeight + (textView.font?.pointSize ?? parent.fontSize) * 2), in: container)
            let used = layoutManager.usedRect(for: container).height
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: parent.fontSize))
            let height = min(max(used, lineHeight), parent.maxHeight)
            guard abs(height - parent.contentHeight) > 0.5 else {
                return
            }
            Task { @MainActor [weak self] in
                self?.parent.contentHeight = height
            }
        }
    }
}

/// The text view of a composer: the placeholder drawn while it is empty, Control-J breaking the line as a
/// terminal's does, and its focus told to the composer.
final class ComposerTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let isTaken = super.becomeFirstResponder()
        if isTaken {
            onFocusChange?(true)
        }
        return isTaken
    }

    override func resignFirstResponder() -> Bool {
        let isGiven = super.resignFirstResponder()
        if isGiven {
            onFocusChange?(false)
        }
        return isGiven
    }

    override func keyDown(with event: NSEvent) {
        if
            !hasMarkedText(),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
            event.charactersIgnoringModifiers?.lowercased() == "j"
        {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: placeholderColor,
        ]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: attributes)
    }

    override func layout() {
        super.layout()
        (delegate as? ComposerField.Coordinator)?.measure()
    }
}
