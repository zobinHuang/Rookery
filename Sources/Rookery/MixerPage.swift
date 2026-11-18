import SwiftUI

/// The mixer as a page of the content area: a strip for every application connected to the audio system and
/// every browser tab playing or taken over, in a column down the middle, or a way to turn it on.
struct MixerPage: View {
    private static let columnWidth: CGFloat = 560

    let mixer: MixerController
    @Bindable var preferences: Preferences
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            if preferences.isMixerEnabled {
                ScrollView {
                    MixerView(mixer: mixer, isCollapsed: false)
                        .frame(maxWidth: Self.columnWidth)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                }
            } else {
                SidebarNotice(
                    icon: .mixer,
                    title: "The mixer is off",
                    text: "Turn it on to set each app's and each browser tab's volume, balance and sound.",
                    actionTitle: "Turn On"
                ) {
                    preferences.isMixerEnabled = true
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RookeryIconView(.sliders, scale: 1.6)
            Text("Mixer")
                .font(.system(size: 18, weight: .bold))
            Spacer(minLength: 8)
            Button(action: onClose) {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(StageColors.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
