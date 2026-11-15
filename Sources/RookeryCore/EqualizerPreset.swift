/// Ready-made equalizer curves, one click away in the mixer.
public enum EqualizerPreset: String, CaseIterable, Codable, Sendable {
    /// The thin, boxy sound of a two-way radio: only the band speech needs, its middle pushed forward.
    case walkieTalkie

    /// The preset's name as the mixer shows it.
    public var title: String {
        switch self {
        case .walkieTalkie: "Walkie-Talkie"
        }
    }

    /// Each band's gain in decibels, matching `MixerTrackSettings.listEqualizerFrequencies`.
    public var listGains: [Float] {
        switch self {
        case .walkieTalkie: [-12, -12, -12, -6, 2, 6, 8, 2, -12, -12]
        }
    }
}
