import MuxShotsControl
import MuxShotsCore
import SwiftUI

/// The mixer in the stage's sidebar: a strip for every application connected to the audio system. A strip
/// takes its application's sound over with its switch, then offers a meter and volume, and opens to show
/// pan, stereo, equalizer and reverb.
struct MixerView: View {
    private static let expandAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)

    let mixer: MixerController
    let isCollapsed: Bool
    @State private var expandedBundleId: String?

    var body: some View {
        if mixer.listTracks.isEmpty {
            if !isCollapsed {
                emptyState
            }
        } else if isCollapsed {
            VStack(spacing: 6) {
                ForEach(mixer.listTracks, id: \.bundleId) { track in
                    collapsedStrip(track)
                }
            }
            .padding(.horizontal, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(mixer.listTracks, id: \.bundleId) { track in
                    MixerStrip(
                        track: track,
                        mixer: mixer,
                        isExpanded: expandedBundleId == track.bundleId
                    ) {
                        withAnimation(Self.expandAnimation) {
                            expandedBundleId = expandedBundleId == track.bundleId ? nil : track.bundleId
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .animation(Self.expandAnimation, value: mixer.listTracks.map(\.bundleId))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No app is using sound")
                .font(.system(size: 12, weight: .medium))
            Text("Apps show up here once they play or connect to audio.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    /// A track in the collapsed sidebar: its icon, ringed while taken over, with a meter below.
    private func collapsedStrip(_ track: MixerTrackStatus) -> some View {
        Button {
            mixer.update(track.bundleId) { $0.isTakenOver.toggle() }
        } label: {
            VStack(spacing: 4) {
                ApplicationIconView(bundleId: track.bundleId, size: 28)
                    .padding(3)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: track.settings.isTakenOver ? 2 : 0)
                    }
                StereoMeter(levels: mixer.mapLevels[track.bundleId] ?? MixerLevels())
                    .frame(width: 30)
                    .opacity(track.isCapturing ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(track.settings.isTakenOver ? "\(track.name): taken over; click to give it back" : "\(track.name): click to take over its sound")
    }
}

/// One application's strip in the mixer.
private struct MixerStrip: View {
    private static let reverbRooms = ReverbRoom.allCases

    let track: MixerTrackStatus
    let mixer: MixerController
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    private var settings: MixerTrackSettings {
        mixer.settings(of: track.bundleId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if settings.isTakenOver {
                VStack(alignment: .leading, spacing: 8) {
                    StereoMeter(levels: mixer.mapLevels[track.bundleId] ?? MixerLevels())
                    labeledSlider(
                        symbol: volumeSymbol,
                        value: binding(\.volume),
                        range: MixerTrackSettings.volumeRange,
                        restValue: 1,
                        valueText: "\(Int((settings.volume * 100).rounded()))%"
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                if isExpanded {
                    details
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                expandButton
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(StageColors.card)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(StageColors.separator, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: settings.isTakenOver)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ApplicationIconView(bundleId: track.bundleId, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            MixerSwitch(
                isOn: binding(\.isTakenOver),
                help: settings.isTakenOver ? "Give the sound back to \(track.name)" : "Take over the sound of \(track.name)"
            )
        }
    }

    private var statusText: String {
        if let error = track.error {
            return "Couldn't take over: \(error)"
        }
        switch (settings.isTakenOver, track.isCapturing, track.isPlaying) {
        case (true, true, _): return "Mixing"
        case (true, false, _): return "Waiting for sound"
        case (false, _, true): return "Playing"
        case (false, _, false): return "Silent"
        }
    }

    private var statusColor: Color {
        if track.error != nil {
            return .red
        }
        if track.isCapturing {
            return .accentColor
        }
        return track.isPlaying ? .green : Color.secondary.opacity(0.5)
    }

    private var volumeSymbol: String {
        switch settings.volume {
        case 0: "speaker.slash.fill"
        case ..<0.4: "speaker.wave.1.fill"
        case ..<1.1: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private var expandButton: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 4) {
                Text(isExpanded ? "Less" : "Pan, Stereo, EQ, Reverb")
                    .font(.system(size: 10.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pan & Stereo") {
                labeledSlider(
                    symbol: "arrow.left.and.right",
                    value: binding(\.pan),
                    range: MixerTrackSettings.panRange,
                    restValue: 0,
                    valueText: panText
                )
                labeledSlider(
                    symbol: "arrow.left.and.right.square",
                    value: binding(\.width),
                    range: MixerTrackSettings.widthRange,
                    restValue: 1,
                    valueText: settings.width == 0 ? "Mono" : "\(Int((settings.width * 100).rounded()))%"
                )
                HStack(spacing: 5) {
                    MixerChip(title: "Ø L", isOn: settings.isLeftInverted, help: "Invert the left channel's phase") {
                        mixer.update(track.bundleId) { $0.isLeftInverted.toggle() }
                    }
                    MixerChip(title: "Ø R", isOn: settings.isRightInverted, help: "Invert the right channel's phase") {
                        mixer.update(track.bundleId) { $0.isRightInverted.toggle() }
                    }
                    MixerChip(title: "L ⇄ R", isOn: settings.isSwapped, help: "Swap the left and right channels") {
                        mixer.update(track.bundleId) { $0.isSwapped.toggle() }
                    }
                }
            }
            section("Equalizer", accessory: equalizerAccessory) {
                equalizer
            }
            section("Reverb") {
                Menu {
                    ForEach(Self.reverbRooms, id: \.self) { room in
                        Button(room.title) {
                            mixer.update(track.bundleId) { $0.reverbRoom = room }
                        }
                    }
                } label: {
                    Text(settings.reverbRoom.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                labeledSlider(
                    symbol: "dot.radiowaves.left.and.right",
                    value: binding(\.reverbMix),
                    range: MixerTrackSettings.reverbMixRange,
                    restValue: 0,
                    valueText: settings.reverbMix == 0 ? "Off" : "\(Int(settings.reverbMix.rounded()))% wet"
                )
            }
        }
        .padding(.top, 2)
    }

    private var panText: String {
        let percent = Int((abs(settings.pan) * 100).rounded())
        if percent == 0 {
            return "Center"
        }
        return settings.pan < 0 ? "L \(percent)" : "R \(percent)"
    }

    private var equalizerAccessory: some View {
        HStack(spacing: 8) {
            if settings.listEqualizerGains.contains(where: { $0 != 0 }) {
                Button("Reset") {
                    mixer.update(track.bundleId) { settings in
                        settings.listEqualizerGains = MixerTrackSettings().listEqualizerGains
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            MixerSwitch(
                isOn: binding(\.isEqualizerEnabled),
                help: settings.isEqualizerEnabled ? "Bypass the equalizer" : "Turn the equalizer on"
            )
        }
    }

    private var equalizer: some View {
        let listFrequencies = MixerTrackSettings.listEqualizerFrequencies
        return VStack(spacing: 4) {
            ZStack {
                // The zero line, across every band.
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(listFrequencies.indices, id: \.self) { index in
                        EqualizerBandSlider(
                            gain: Binding(
                                get: { settings.listEqualizerGains[index] },
                                set: { gain in mixer.update(track.bundleId) { $0.listEqualizerGains[index] = gain } }
                            ),
                            range: MixerTrackSettings.equalizerGainRange,
                            isEnabled: settings.isEqualizerEnabled
                        )
                        .help("\(Self.frequencyText(listFrequencies[index]))Hz: \(String(format: "%+.0f", settings.listEqualizerGains[index])) dB")
                    }
                }
            }
            .frame(height: 78)
            HStack(spacing: 0) {
                ForEach(listFrequencies.indices, id: \.self) { index in
                    Text(Self.frequencyText(listFrequencies[index]))
                        .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .opacity(settings.isEqualizerEnabled ? 1 : 0.5)
    }

    private static func frequencyText(_ frequency: Float) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }

    private func section<Content: View, Accessory: View>(
        _ title: String,
        accessory: Accessory = EmptyView(),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            content()
        }
    }

    private func labeledSlider(
        symbol: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        restValue: Float,
        valueText: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            MixerSlider(value: value, range: range, restValue: restValue)
            Text(valueText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MixerTrackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in mixer.update(track.bundleId) { $0[keyPath: keyPath] = value } }
        )
    }
}

/// An application's icon, or a generic one when it cannot be found.
struct ApplicationIconView: View {
    let bundleId: String?
    let size: CGFloat

    var body: some View {
        if let icon = ApplicationIcon.icon(forBundleId: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
