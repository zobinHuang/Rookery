/// The rooms the mixer's reverb can simulate.
public enum ReverbRoom: String, Codable, CaseIterable, Sendable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case plate
    case cathedral

    /// The room's name as the mixer shows it.
    public var title: String {
        switch self {
        case .smallRoom: "Small Room"
        case .mediumRoom: "Medium Room"
        case .largeRoom: "Large Room"
        case .mediumHall: "Medium Hall"
        case .largeHall: "Large Hall"
        case .plate: "Plate"
        case .cathedral: "Cathedral"
        }
    }
}

/// How the mixer treats one application's sound: whether MuxShots takes it over, and the stereo, equalizer
/// and reverb settings applied while it does.
public struct MixerTrackSettings: Codable, Equatable, Sendable {
    /// The equalizer's band centers, in hertz.
    public static let listEqualizerFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let volumeRange: ClosedRange<Float> = 0...2
    public static let panRange: ClosedRange<Float> = -1...1
    public static let widthRange: ClosedRange<Float> = 0...2
    public static let equalizerGainRange: ClosedRange<Float> = -12...12
    public static let reverbMixRange: ClosedRange<Float> = 0...100

    /// Whether MuxShots takes the sound over; while it does not, the application plays as it always would.
    public var isTakenOver = false
    /// The gain, 1 unchanged.
    public var volume: Float = 1
    /// The stereo position, -1 hard left to 1 hard right.
    public var pan: Float = 0
    /// Whether the left channel's polarity is inverted.
    public var isLeftInverted = false
    /// Whether the right channel's polarity is inverted.
    public var isRightInverted = false
    /// Whether the left and right channels trade places.
    public var isSwapped = false
    /// The stereo width, 0 mono, 1 unchanged, 2 twice as wide.
    public var width: Float = 1
    public var isEqualizerEnabled = true
    /// The gain of each equalizer band, in decibels, matching `listEqualizerFrequencies`.
    public var listEqualizerGains: [Float] = Array(repeating: 0, count: listEqualizerFrequencies.count)
    public var reverbRoom: ReverbRoom = .mediumHall
    /// The share of reverberated sound, 0 dry to 100 wet.
    public var reverbMix: Float = 0

    public init() {}

    /// The same settings with every value moved into its allowed range and the equalizer padded or cut to
    /// its band count, as for settings read back from disk.
    public var clamped: MixerTrackSettings {
        var settings = self
        settings.volume = Self.clamp(volume, to: Self.volumeRange)
        settings.pan = Self.clamp(pan, to: Self.panRange)
        settings.width = Self.clamp(width, to: Self.widthRange)
        settings.reverbMix = Self.clamp(reverbMix, to: Self.reverbMixRange)
        let bandCount = Self.listEqualizerFrequencies.count
        settings.listEqualizerGains = (listEqualizerGains + Array(repeating: 0, count: bandCount))
            .prefix(bandCount)
            .map { Self.clamp($0, to: Self.equalizerGainRange) }
        return settings
    }

    /// Whether the settings change the sound at all, beyond taking it over.
    public var isNeutral: Bool {
        var neutral = MixerTrackSettings()
        neutral.isTakenOver = isTakenOver
        return clamped == neutral
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
