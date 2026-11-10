import SwiftUI

/// The screen saver: the user's text, large and centred in the content area, shrinking to fit when it is
/// long. A click anywhere on it closes it.
struct ScreenSaverView: View {
    private static let margin: CGFloat = 48
    /// How far long text shrinks to fit before it is cut short.
    private static let minimumScale: CGFloat = 0.2

    let text: String
    let textSize: Double
    let onClose: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: textSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(Self.minimumScale)
            .foregroundStyle(.primary)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
    }
}
