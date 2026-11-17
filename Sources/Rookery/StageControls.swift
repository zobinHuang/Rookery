import AppKit
import SwiftUI

/// The stage's buttons: a soft filled shape in the regular themes, outlined in the high-contrast ones; the
/// prominent kind in the accent color; the destructive kind tinted red. They light on hover and dim when
/// pressed or disabled, and size by the control size, rather than the system's grey bezels, which read as
/// inactive in the stage's panel, never the key window.
struct StageButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case prominent
        case destructive
    }

    var kind = Kind.normal

    func makeBody(configuration: Configuration) -> some View {
        StageButtonBody(configuration: configuration, kind: configuration.role == .destructive ? .destructive : kind)
    }
}

private struct StageButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: StageButtonStyle.Kind

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.stageTheme) private var theme
    @State private var isHovered = false

    private var isHighContrast: Bool {
        theme == .highContrastLight || theme == .highContrastDark
    }

    private var isSmall: Bool {
        controlSize == .small || controlSize == .mini
    }

    var body: some View {
        configuration.label
            .font(.system(size: isSmall ? 11.5 : 12.5, weight: kind == .prominent ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, isSmall ? 9 : 12)
            .padding(.vertical, isSmall ? 3.5 : 5.5)
            .background(fill, in: RoundedRectangle(cornerRadius: isSmall ? 6 : 7.5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isSmall ? 6 : 7.5, style: .continuous)
                    .strokeBorder(border, lineWidth: isHighContrast ? 1.5 : 0.75)
            }
            .shadow(color: kind == .prominent && !isHighContrast ? Color.accentColor.opacity(0.25) : .clear, radius: 2, y: 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
            .onHover { isInside in
                isHovered = isInside && isEnabled
            }
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .prominent:
            isHighContrast ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(Color.white)
        case .destructive:
            AnyShapeStyle(Color.red)
        case .normal:
            AnyShapeStyle(StageColors.primaryText)
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .prominent:
            if isHighContrast {
                return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.3 : 0.18))
            }
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.88 : 1))
        case .destructive:
            return AnyShapeStyle(Color.red.opacity(isHovered ? 0.18 : 0.1))
        case .normal:
            return AnyShapeStyle(isHovered ? StageColors.controlHovered : StageColors.control)
        }
    }

    private var border: AnyShapeStyle {
        if isHighContrast {
            return kind == .prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.separator)
        }
        switch kind {
        case .prominent: return AnyShapeStyle(Color.clear)
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.3))
        case .normal: return AnyShapeStyle(StageColors.controlBorder)
        }
    }
}

/// A row of choices, one chosen, as the stage's tabs look: the chosen one on a raised, accent-tinted
/// segment that slides between them.
struct StageSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let listOptions: [Value]
    let title: (Value) -> String
    var isSmall = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(listOptions, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.system(size: isSmall ? 10.5 : 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
                        .padding(.horizontal, isSmall ? 7 : 10)
                        .padding(.vertical, isSmall ? 2.5 : 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: isSmall ? 5 : 6, style: .continuous)
                                    .fill(StageColors.selectedSegment)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: isSmall ? 5 : 6, style: .continuous)
                                            .strokeBorder(StageColors.contrastActiveBorder)
                                    }
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(StageColors.segmentGroove, in: RoundedRectangle(cornerRadius: isSmall ? 7 : 8, style: .continuous))
        .fixedSize()
    }
}
