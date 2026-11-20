import AppKit
import SwiftUI

/// The box to write to an agent in. At rest it is one line in a capsule, its button at the end; once the
/// user is in it, or has written something, it opens with a spring into a taller box with the button
/// gliding to its lower corner, and closes the same way. Return sends,
/// Shift-Return breaks the line; a caller may take keys first, as Raven's suggestions do.
struct AgentComposer: View {
    private static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private static let buttonSize: CGFloat = 26
    private static let closedHeight: CGFloat = 26
    private static let openMinHeight: CGFloat = 64
    /// The tallest the open box grows before it scrolls, about ten lines.
    private static let openMaxHeight: CGFloat = 170
    private static let closedCornerRadius: CGFloat = 19
    private static let openCornerRadius: CGFloat = 14

    @Binding var text: String
    let placeholder: String
    var isEnabled = true
    /// Sending, or the agent working on what was sent.
    var isBusy = false
    /// Whether what is sent while busy waits its turn rather than being refused.
    var isQueueing = false
    var fontSize: CGFloat = 13
    /// Stops what is running; when given, the button stops while busy rather than waiting.
    var onStop: (() -> Void)?
    let onSend: () -> Void
    /// Takes a key before the box does; true keeps it from the box.
    var onKey: ((ComposerKey) -> Bool)?
    var isFocused: FocusState<Bool>.Binding

    @Namespace private var namespace
    /// Whether the box closed after sending while keeping the focus, until the user writes again.
    @State private var isResting = false
    /// The height the field's text needs, as it reports it.
    @State private var contentHeight: CGFloat = 0

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isOpen: Bool {
        isEnabled && (!text.isEmpty || (isFocused.wrappedValue && !isResting))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                field
                if !isOpen {
                    button
                        .matchedGeometryEffect(id: "button", in: namespace)
                }
            }
            if isOpen {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    button
                        .matchedGeometryEffect(id: "button", in: namespace)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isOpen ? 8 : 6)
        .padding(.vertical, isOpen ? 10 : 6)
        .background(
            StageColors.tile,
            in: RoundedRectangle(cornerRadius: isOpen ? Self.openCornerRadius : Self.closedCornerRadius, style: .circular)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isOpen ? Self.openCornerRadius : Self.closedCornerRadius, style: .circular)
                .strokeBorder(isFocused.wrappedValue ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(StageColors.separator))
        }
        .shadow(color: .black.opacity(isOpen ? 0.12 : 0), radius: isOpen ? 10 : 0, y: isOpen ? 3 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            isResting = false
            isFocused.wrappedValue = true
        }
        .animation(Self.openAnimation, value: isOpen)
        .onChange(of: text) { _, newText in
            if !newText.isEmpty {
                isResting = false
            }
        }
        .onChange(of: isFocused.wrappedValue) { _, isNowFocused in
            if !isNowFocused {
                isResting = false
            }
        }
    }

    /// One line of the field's text, as tall as the closed box shows it.
    private var lineHeight: CGFloat {
        max(contentHeight, ceil(fontSize * 1.25))
    }

    private var field: some View {
        let minHeight = isOpen ? Self.openMinHeight : Self.closedHeight
        let maxHeight = isOpen ? Self.openMaxHeight : Self.closedHeight
        return ComposerField(
            text: $text,
            placeholder: placeholder,
            fontSize: fontSize,
            isEnabled: isEnabled,
            isFocused: isFocused,
            contentHeight: $contentHeight,
            maxHeight: maxHeight,
            onKey: take
        )
        .frame(
            minHeight: isOpen ? minHeight : lineHeight,
            maxHeight: isOpen ? min(max(contentHeight, minHeight), maxHeight) : lineHeight,
            alignment: .topLeading
        )
        .frame(height: isOpen ? nil : Self.closedHeight, alignment: .center)
    }

    /// A key the field offers: the caller's first, then Send.
    private func take(_ key: ComposerKey) -> Bool {
        if let onKey, onKey(key) {
            return true
        }
        guard key == .send else {
            return false
        }
        if !isEmpty, !isBusy || isQueueing {
            onSend()
            isResting = true
        }
        return true
    }

    /// Whether an input method is composing in the focused field, as Pinyin does before its candidate is
    /// chosen: Return then commits the candidate and the arrows move among candidates, so neither sends or
    /// works the suggestions.
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    /// Whether a key starts a new line in a box where Return sends: ⇧Return, or ⌃J as terminals have it.
    static func insertsNewline(_ keyPress: KeyPress) -> Bool {
        if keyPress.key == .return {
            return keyPress.modifiers.contains(.shift)
        }
        return keyPress.modifiers.contains(.control) && (keyPress.key.character == "j" || keyPress.key.character == "\n")
    }

    /// Start a new line at the caret of the focused box, in place of what is selected.
    static func insertNewline() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return
        }
        textView.insertText("\n", replacementRange: textView.selectedRange())
    }

    @ViewBuilder
    private var button: some View {
        if isBusy, isQueueing, !isEmpty, onStop != nil {
            HStack(spacing: 6) {
                stopButton
                sendButton
            }
        } else if isBusy, onStop != nil {
            stopButton
        } else {
            sendButton
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if let onStop {
            Button(action: onStop) {
                RookeryIconView(.stop)
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var sendButton: some View {
        let isWaiting = isBusy && !isQueueing
        return Button {
                onSend()
                isResting = true
            } label: {
                Group {
                    if isWaiting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        RookeryIconView(.arrowUp)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(isEmpty || !isEnabled ? Color.gray.opacity(0.5) : Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isEmpty || !isEnabled || isWaiting)
            .help(isBusy ? "Send once the answer under way is done (Return)" : "Send (Return)")
            .transition(.scale.combined(with: .opacity))
    }
}
