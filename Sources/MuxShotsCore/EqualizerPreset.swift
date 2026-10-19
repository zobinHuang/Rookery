/// Ready-made equalizer curves, one click away in the mixer.
public enum EqualizerPreset: String, CaseIterable, Codable, Sendable {
    case flat
    case bassBoost
    case bassCut
    case trebleBoost
    case voice
    case loudness
    case lateNight
    case electronic
    case acoustic

    /// The preset's name as the mixer shows it.
    public var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .bassCut: "Bass Cut"
        case .trebleBoost: "Treble Boost"
        case .voice: "Voice"
        case .loudness: "Loudness"
        case .lateNight: "Late Night"
        case .electronic: "Electronic"
        case .acoustic: "Acoustic"
        }
    }

    /// Each band's gain in decibels, matching `MixerTrackSettings.listEqualizerFrequencies`.
    public var listGains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .bassCut: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 0, 1, 3, 5, 6]
        // Lifts the range speech carries in and thins out rumble, for talk and calls.
        case .voice: [-4, -3, -2, 0, 2, 4, 4, 3, 1, 0]
        case .loudness: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        // Tames booming lows and sharp highs, so quiet listening stays clear.
        case .lateNight: [-4, -3, -2, 0, 0, 1, 2, 1, -1, -2]
        case .electronic: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]
        case .acoustic: [3, 3, 2, 1, 1, 1, 2, 2, 2, 1]
        }
    }
}
