import RookeryControl
import RookeryCore
import SwiftUI

/// The mixer in the stage's sidebar: a strip for every application connected to the audio system, then
/// one for every browser tab playing or taken over through the Rookery browser extension. A strip takes
/// its sound over with its switch, then offers a meter and volume, and opens to show pan, stereo,
/// equalizer and reverb.
struct MixerView: View {
    private static let expandAnimation = Animation.spring(response: 0.32, dampingFraction: 0.86)
    private static let chromeBundleId = "com.google.Chrome"

    let mixer: MixerController
    let isCollapsed: Bool
    @State private var expandedStripId: MixerStripId?

    var body: some View {
        content
            .onAppear(perform: mixer.beginShowingMeters)
            .onDisappear(perform: mixer.endShowingMeters)
    }

    @ViewBuilder
    private var content: some View {
        if mixer.listTracks.isEmpty && mixer.browserTabs.listTabs.isEmpty {
            if !isCollapsed {
                emptyState
            }
        } else if isCollapsed {
            VStack(spacing: 6) {
                ForEach(mixer.listTracks, id: \.bundleId) { track in
                    collapsedStrip(track)
                    if track.bundleId == Self.chromeBundleId {
                        collapsedTabs
                    }
                }
                if !isChromeListed {
                    collapsedTabs
                }
            }
            .padding(.horizontal, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(mixer.listTracks, id: \.bundleId) { track in
                    applicationStrip(track)
                    if track.bundleId == Self.chromeBundleId {
                        tabsSection
                    }
                }
                if !isChromeListed {
                    tabsSection
                }
            }
            .padding(.horizontal, 8)
            .animation(Self.expandAnimation, value: mixer.listTracks.map(\.bundleId))
            .animation(Self.expandAnimation, value: mixer.browserTabs.listTabs.map(\.id))
        }
    }

    private var isChromeListed: Bool {
        mixer.listTracks.contains { $0.bundleId == Self.chromeBundleId }
    }

    /// Chrome's tabs, right under Chrome's own strip, or a hint to add the extension.
    @ViewBuilder
    private var tabsSection: some View {
        if !mixer.browserTabs.listTabs.isEmpty {
            sectionHeader("Chrome Tabs")
            ForEach(mixer.browserTabs.listTabs) { browserTab in
                tabStrip(browserTab)
                    .padding(.leading, 10)
            }
        } else if mixer.browserTabs.sessionCount == 0 && isChromeListed {
            Text("Add the Rookery extension to Chrome to mix its tabs one by one.")
                .font(.system(size: 10.5))
                .foregroundStyle(StageColors.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        }
    }

    /// Chrome's tabs in the collapsed sidebar: each one's icon, ringed while taken over.
    private var collapsedTabs: some View {
        ForEach(mixer.browserTabs.listTabs) { browserTab in
            let browserTabs = mixer.browserTabs
            let settings = browserTabs.settings(of: browserTab.key)
            Button {
                browserTabs.update(browserTab.key) { $0.isTakenOver.toggle() }
            } label: {
                MixerStripIconView(icon: .website(url: browserTab.tab.favIconUrl.flatMap(URL.init(string:))))
                    .opacity(browserTab.tab.isMuted ? 0.45 : 1)
                    .padding(2)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: settings.isTakenOver ? 2 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(browserTab.tab.title)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            PixelIconView(.speaker, scale: 2)
                .foregroundStyle(StageColors.tertiaryText)
            Text("No app is using sound")
                .font(.system(size: 12, weight: .medium))
            Text("Apps show up here once they play or connect to audio.")
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(StageColors.secondaryText)
            .padding(.horizontal, 6)
            .padding(.top, 6)
    }

    private func applicationStrip(_ track: MixerTrackStatus) -> some View {
        let stripId = MixerStripId.application(track.bundleId)
        let settings = mixer.settings(of: track.bundleId)
        return MixerStrip(
            title: track.name,
            icon: .application(bundleId: track.bundleId),
            status: Self.status(of: track, settings: settings),
            settings: settings,
            readLevels: { mixer.mapLevels[track.bundleId] ?? MixerLevels() },
            isExpanded: expandedStripId == stripId,
            onToggleExpanded: { toggleExpanded(stripId) },
            onUpdate: { change in mixer.update(track.bundleId, change) }
        )
    }

    private func tabStrip(_ browserTab: MixerBrowserTab) -> some View {
        let stripId = MixerStripId.tab(browserTab.key)
        let browserTabs = mixer.browserTabs
        return MixerStrip(
            title: browserTab.tab.title.isEmpty ? browserTab.tab.url : browserTab.tab.title,
            icon: .website(url: browserTab.tab.favIconUrl.flatMap(URL.init(string:))),
            status: Self.status(of: browserTab.tab),
            settings: browserTabs.settings(of: browserTab.key),
            readLevels: { browserTabs.mapLevels[browserTab.key] ?? MixerLevels() },
            isExpanded: expandedStripId == stripId,
            onToggleExpanded: { toggleExpanded(stripId) },
            onUpdate: { change in browserTabs.update(browserTab.key, change) },
            pictureToggle: pictureToggle(of: browserTab)
        )
    }

    /// The button for showing a tab's video in the sidebar, while the tab plays one or shows it already.
    private func pictureToggle(of browserTab: MixerBrowserTab) -> MixerPictureToggle? {
        let browserTabs = mixer.browserTabs
        let isShowing = browserTabs.pictures.contains(browserTab.key)
        guard browserTab.tab.hasVideo || isShowing else {
            return nil
        }
        return MixerPictureToggle(isShowing: isShowing) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                browserTabs.togglePicture(of: browserTab)
            }
        }
    }

    private func toggleExpanded(_ stripId: MixerStripId) {
        withAnimation(Self.expandAnimation) {
            expandedStripId = expandedStripId == stripId ? nil : stripId
        }
    }

    /// A track in the collapsed sidebar: its icon, ringed while taken over, with a meter below.
    private func collapsedStrip(_ track: MixerTrackStatus) -> some View {
        Button {
            mixer.update(track.bundleId) { $0.isTakenOver.toggle() }
        } label: {
            VStack(spacing: 4) {
                ApplicationIconView(bundleId: track.bundleId, size: 28)
                    .opacity(track.settings.isMuted ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if track.settings.isMuted {
                            PixelIconView(.speakerOff)
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Color.red, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                    .padding(3)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: track.settings.isTakenOver ? 2 : 0)
                    }
                LiveStereoMeter { mixer.mapLevels[track.bundleId] ?? MixerLevels() }
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

    private static func status(of track: MixerTrackStatus, settings: MixerTrackSettings) -> MixerStripStatus {
        if let error = track.error {
            return MixerStripStatus(text: "Couldn't take over: \(error)", color: .red)
        }
        if settings.isMuted {
            return MixerStripStatus(text: "Muted", color: .red)
        }
        switch (settings.isTakenOver, track.isCapturing, track.isPlaying) {
        case (true, true, _):
            return MixerStripStatus(text: "Mixing", color: .accentColor)
        case (true, false, _):
            return MixerStripStatus(text: "Waiting for sound", color: .secondary)
        case (false, _, true):
            return MixerStripStatus(text: "Playing", color: .green)
        case (false, _, false):
            return MixerStripStatus(text: "Silent", color: .secondary)
        }
    }

    private static func status(of tab: BrowserTab) -> MixerStripStatus {
        if tab.isMuted {
            return MixerStripStatus(text: "Muted", color: .red)
        }
        return switch tab.mode {
        case .idle:
            tab.isAudible
                ? MixerStripStatus(text: "Playing", color: .green)
                : MixerStripStatus(text: "Silent", color: .secondary)
        case .waiting:
            MixerStripStatus(text: "Waiting for sound", color: .secondary)
        case .page:
            MixerStripStatus(text: "Mixing", color: .accentColor)
        case .blocked:
            MixerStripStatus(
                text: "Needs a tab capture",
                color: .orange,
                help: "This page's sound can't be mixed from inside it; capture the whole tab with the Rookery button in Chrome's toolbar"
            )
        case .captured:
            MixerStripStatus(text: "Mixing the whole tab", color: .accentColor)
        }
    }
}

/// Which strip of the mixer, so one at a time can be open.
enum MixerStripId: Hashable {
    case application(String)
    case tab(BrowserTabKey)
}

/// What a strip says it is doing, under its title.
struct MixerStripStatus {
    let text: String
    let color: Color
    /// More about the status, shown when the pointer rests on it.
    var help: String?
}

/// A tab strip's button for showing the tab's video in the sidebar.
struct MixerPictureToggle {
    let isShowing: Bool
    let action: () -> Void
}

/// What a strip shows as its picture.
enum MixerStripIcon {
    case application(bundleId: String)
    case website(url: URL?)
}

/// A strip's picture: an application's icon, or a website's on a small tile.
struct MixerStripIconView: View {
    let icon: MixerStripIcon

    var body: some View {
        switch icon {
        case .application(let bundleId):
            ApplicationIconView(bundleId: bundleId, size: 24)
        case .website(let url):
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .interpolation(.high)
            } placeholder: {
                PixelIconView(.globe)
                    .foregroundStyle(StageColors.secondaryText)
            }
            .frame(width: 16, height: 16)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StageColors.tile)
            }
        }
    }
}

/// One track's strip in the mixer: an application's or a browser tab's.
private struct MixerStrip: View {
    private static let reverbRooms = ReverbRoom.allCases

    let title: String
    let icon: MixerStripIcon
    let status: MixerStripStatus
    let settings: MixerTrackSettings
    /// The track's levels now, read by its meter alone so a new level redraws only the meter.
    let readLevels: () -> MixerLevels
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    /// Change the track's settings.
    let onUpdate: ((inout MixerTrackSettings) -> Void) -> Void
    /// The button for showing the track's video in the sidebar, for a tab playing one.
    var pictureToggle: MixerPictureToggle?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let pictureToggle {
                pictureButton(pictureToggle)
            }
            if settings.isTakenOver {
                VStack(alignment: .leading, spacing: 8) {
                    LiveStereoMeter(readLevels: readLevels)
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
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 5, height: 5)
                    Text(status.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(1)
                }
                .help(status.help ?? status.text)
            }
            Spacer(minLength: 4)
            MixerMuteButton(
                isMuted: settings.isMuted,
                help: settings.isMuted ? "Unmute \(title)" : "Mute \(title)"
            ) {
                onUpdate { $0.isMuted.toggle() }
            }
            MixerSwitch(
                isOn: binding(\.isTakenOver),
                help: settings.isTakenOver ? "Give the sound back to \(title)" : "Take over the sound of \(title)"
            )
        }
    }

    private var iconView: some View {
        MixerStripIconView(icon: icon)
    }

    private func pictureButton(_ toggle: MixerPictureToggle) -> some View {
        Button(action: toggle.action) {
            PixelLabel(
                toggle.isShowing ? "Showing in Sidebar" : "Show in Sidebar",
                icon: toggle.isShowing ? .pip : .pipEnter
            )
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(toggle.isShowing ? AnyShapeStyle(.white) : AnyShapeStyle(StageColors.secondaryText))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(toggle.isShowing ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(StageColors.groove.opacity(0.6)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(toggle.isShowing ? "Stop showing this tab's video in the sidebar" : "Show this tab's video in the sidebar")
    }

    private var volumeSymbol: PixelIcon {
        switch settings.volume {
        case 0: .speakerOff
        case ..<0.4: .speakerLow
        case ..<1.1: .speaker
        default: .speaker
        }
    }

    private var expandButton: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 4) {
                Text(isExpanded ? "Less" : "Pan, Stereo, EQ, Reverb")
                    .font(.system(size: 10.5, weight: .medium))
                PixelIconView(.chevronDown)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(StageColors.secondaryText)
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
                    symbol: .width,
                    value: binding(\.pan),
                    range: MixerTrackSettings.panRange,
                    restValue: 0,
                    valueText: panText
                )
                labeledSlider(
                    symbol: .width,
                    value: binding(\.width),
                    range: MixerTrackSettings.widthRange,
                    restValue: 1,
                    valueText: settings.width == 0 ? "Mono" : "\(Int((settings.width * 100).rounded()))%"
                )
                HStack(spacing: 5) {
                    MixerChip(title: "Ø L", isOn: settings.isLeftInverted, help: "Invert the left channel's phase") {
                        onUpdate { $0.isLeftInverted.toggle() }
                    }
                    MixerChip(title: "Ø R", isOn: settings.isRightInverted, help: "Invert the right channel's phase") {
                        onUpdate { $0.isRightInverted.toggle() }
                    }
                    MixerChip(title: "L ⇄ R", isOn: settings.isSwapped, help: "Swap the left and right channels") {
                        onUpdate { $0.isSwapped.toggle() }
                    }
                }
            }
            section("Equalizer", accessory: equalizerAccessory) {
                equalizerPresets
                equalizer
            }
            section("Reverb") {
                Menu {
                    ForEach(Self.reverbRooms, id: \.self) { room in
                        Button(room.title) {
                            onUpdate { $0.reverbRoom = room }
                        }
                    }
                } label: {
                    Text(settings.reverbRoom.title)
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                labeledSlider(
                    symbol: .radio,
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
        MixerSwitch(
            isOn: binding(\.isEqualizerEnabled),
            help: settings.isEqualizerEnabled ? "Bypass the equalizer" : "Turn the equalizer on"
        )
    }

    /// The ready-made curves, one click each to set and again to go back to flat, the current one lit.
    private var equalizerPresets: some View {
        HStack(spacing: 4) {
            ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                EqualizerPresetChip(
                    title: preset.title,
                    symbol: Self.symbol(of: preset),
                    isSelected: settings.isEqualizerEnabled && settings.equalizerPreset == preset
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        onUpdate { $0.toggleEqualizerPreset(preset) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func symbol(of preset: EqualizerPreset) -> PixelIcon {
        switch preset {
        case .walkieTalkie: .radio
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
                                set: { gain in onUpdate { $0.listEqualizerGains[index] = gain } }
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
                        .foregroundStyle(StageColors.tertiaryText)
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
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(StageColors.secondaryText)
                Spacer(minLength: 0)
                accessory
            }
            content()
        }
    }

    private func labeledSlider(
        symbol: PixelIcon,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        restValue: Float,
        valueText: String
    ) -> some View {
        HStack(spacing: 7) {
            PixelIconView(symbol)
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 16)
            MixerSlider(value: value, range: range, restValue: restValue)
            Text(valueText)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 44, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MixerTrackSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in onUpdate { $0[keyPath: keyPath] = value } }
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
            PixelIconView(.appPlaceholder)
                .frame(width: size, height: size)
                .foregroundStyle(StageColors.secondaryText)
        }
    }
}
