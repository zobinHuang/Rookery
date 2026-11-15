import SwiftUI

/// The themes side by side, each as a small picture of the stage drawn in it, as the system's own
/// appearance setting shows them. Following the system comes first, drawn half light and half dark; the
/// chosen theme is ringed in the accent color.
struct ThemePicker: View {
    private static let previewAspectRatio: CGFloat = 1.45
    private static let previewCornerRadius: CGFloat = 7
    private static let ringWidth: CGFloat = 2.5
    /// How far the ring stands off the picture.
    private static let ringGap: CGFloat = 3
    private static let ringFadeDuration: TimeInterval = 0.15
    private static let choiceSpacing: CGFloat = 12
    private static let captionSpacing: CGFloat = 7
    private static let captionLineCount = 2
    private static let systemTitle = "Auto"
    /// The picture's sidebar, against the picture's width.
    private static let sidebarFraction: CGFloat = 0.34
    private static let inset: CGFloat = 4
    private static let rowCount = 3
    private static let rowHeight: CGFloat = 6
    private static let rowSpacing: CGFloat = 3
    private static let rowCornerRadius: CGFloat = 2
    private static let contentCornerRadius: CGFloat = 4
    private static let textBarHeight: CGFloat = 2
    private static let textBarOpacity = 0.55
    /// The widths of the text a row of the picture holds, against the row's width.
    private static let listTextBarFractions: [CGFloat] = [0.7, 0.5, 0.6]
    private static let hairlineWidth: CGFloat = 0.5

    /// The chosen theme, or nil to follow the system's.
    @Binding var theme: Theme?

    var body: some View {
        HStack(alignment: .top, spacing: Self.choiceSpacing) {
            choice(nil)
            ForEach(Theme.allCases, id: \.self) { option in
                choice(option)
            }
        }
    }

    private func choice(_ option: Theme?) -> some View {
        let isChosen = theme == option
        return Button {
            theme = option
        } label: {
            VStack(spacing: Self.captionSpacing) {
                preview(of: option)
                    .aspectRatio(Self.previewAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.previewCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.previewCornerRadius, style: .continuous)
                            .strokeBorder(StageColors.separator, lineWidth: Self.hairlineWidth)
                    }
                    .padding(Self.ringGap)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: Self.previewCornerRadius + Self.ringGap,
                            style: .continuous
                        )
                        .strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: Self.ringWidth)
                    }
                Text(option?.title ?? Self.systemTitle)
                    .font(.system(size: 11, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
                    .multilineTextAlignment(.center)
                    .lineLimit(Self.captionLineCount, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: Self.ringFadeDuration), value: isChosen)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(of option: Theme?) -> some View {
        if let option {
            stage(in: option)
        } else {
            stage(in: .light)
                .overlay {
                    stage(in: .dark)
                        .mask(alignment: .trailing) {
                            GeometryReader { proxy in
                                Rectangle()
                                    .frame(width: proxy.size.width / 2)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                }
        }
    }

    /// A small picture of the stage in a theme: the sidebar with a selected row and two others, beside
    /// the content area.
    private func stage(in theme: Theme) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(0..<Self.rowCount, id: \.self) { rowIndex in
                        row(isSelected: rowIndex == 0, textFraction: Self.listTextBarFractions[rowIndex])
                    }
                    Spacer(minLength: 0)
                }
                .padding(Self.inset)
                .frame(width: proxy.size.width * Self.sidebarFraction)
                .frame(maxHeight: .infinity)
                .background(StageColors.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(width: Self.hairlineWidth)
                }
                RoundedRectangle(cornerRadius: Self.contentCornerRadius, style: .continuous)
                    .fill(StageColors.content)
                    .strokeBorder(StageColors.contrastBorder)
                    .padding(Self.inset)
            }
            .background(StageColors.window)
        }
        .environment(\.chosenTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func row(isSelected: Bool, textFraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
            .fill(isSelected ? StageColors.selectedTab : .clear)
            .strokeBorder(isSelected ? StageColors.contrastActiveBorder : .clear)
            .frame(height: Self.rowHeight)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(Self.textBarOpacity))
                        .frame(width: proxy.size.width * textFraction, height: Self.textBarHeight)
                        .frame(maxHeight: .infinity)
                        .padding(.leading, Self.rowSpacing)
                }
            }
    }
}
