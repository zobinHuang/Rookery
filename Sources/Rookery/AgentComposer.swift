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
    private static let closedCornerRadius: CGFloat = 19
    private static let openCornerRadius: CGFloat = 14

    @Binding var text: String
    let placeholder: String
    var isEnabled = true
    /// Sending, or the agent working on what was sent.
    var isBusy = false
    var fontSize: CGFloat = 13
    /// Stops what is running; when given, the button stops while busy rather than waiting.
    var onStop: (() -> Void)?
    let onSend: () -> Void
    /// Takes a key press before the box does; `.handled` keeps it from the box.
    var onKey: ((KeyPress) -> KeyPress.Result)?
    var isFocused: FocusState<Bool>.Binding

    @Namespace private var namespace
    /// Whether the box closed after sending while keeping the focus, until the user writes again.
    @State private var isResting = false

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

    private var field: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .lineLimit(isOpen ? 3...10 : 1...1)
            .frame(minHeight: isOpen ? Self.openMinHeight : Self.closedHeight, alignment: isOpen ? .topLeading : .leading)
            .focused(isFocused)
            .disabled(!isEnabled)
            .onKeyPress(phases: .down) { keyPress in
                guard !Self.isComposing else {
                    return .ignored
                }
                if let onKey, onKey(keyPress) == .handled {
                    return .handled
                }
                guard keyPress.key == .return, !keyPress.modifiers.contains(.shift) else {
                    return .ignored
                }
                if !isEmpty, !isBusy {
                    onSend()
                    isResting = true
                }
                return .handled
            }
    }

    /// Whether an input method is composing in the focused field, as Pinyin does before its candidate is
    /// chosen: Return then commits the candidate and the arrows move among candidates, so neither sends or
    /// works the suggestions.
    static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    @ViewBuilder
    private var button: some View {
        if isBusy, let onStop {
            Button(action: onStop) {
                RookeryIconView(.stop)
                    .foregroundStyle(.white)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button {
                onSend()
                isResting = true
            } label: {
                Group {
                    if isBusy {
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
            .disabled(isEmpty || !isEnabled || isBusy)
            .help("Send (Return)")
        }
    }
}
