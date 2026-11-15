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

/// How the mixer treats one application's sound: whether Rookery takes it over, and the stereo, equalizer
/// and reverb settings applied while it does, and whether it is muted, which holds whether or not it is
/// taken over.
public struct MixerTrackSettings: Codable, Equatable, Sendable {
    /// The equalizer's band centers, in hertz.
    public static let listEqualizerFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let volumeRange: ClosedRange<Float> = 0...2
    public static let panRange: ClosedRange<Float> = -1...1
    public static let widthRange: ClosedRange<Float> = 0...2
    public static let equalizerGainRange: ClosedRange<Float> = -12...12
    public static let reverbMixRange: ClosedRange<Float> = 0...100

    /// Whether Rookery takes the sound over; while it does not, the application plays as it always would.
    public var isTakenOver = false
    /// Whether the sound is silenced, keeping every other setting for when it is unmuted.
    public var isMuted = false
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

    /// Read settings, taking the default for any setting they were saved without.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MixerTrackSettings()
        isTakenOver = try container.decodeIfPresent(Bool.self, forKey: .isTakenOver) ?? defaults.isTakenOver
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? defaults.isMuted
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? defaults.volume
        pan = try container.decodeIfPresent(Float.self, forKey: .pan) ?? defaults.pan
        isLeftInverted = try container.decodeIfPresent(Bool.self, forKey: .isLeftInverted) ?? defaults.isLeftInverted
        isRightInverted = try container.decodeIfPresent(Bool.self, forKey: .isRightInverted) ?? defaults.isRightInverted
        isSwapped = try container.decodeIfPresent(Bool.self, forKey: .isSwapped) ?? defaults.isSwapped
        width = try container.decodeIfPresent(Float.self, forKey: .width) ?? defaults.width
        isEqualizerEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEqualizerEnabled) ?? defaults.isEqualizerEnabled
        listEqualizerGains = try container.decodeIfPresent([Float].self, forKey: .listEqualizerGains) ?? defaults.listEqualizerGains
        reverbRoom = try container.decodeIfPresent(ReverbRoom.self, forKey: .reverbRoom) ?? defaults.reverbRoom
        reverbMix = try container.decodeIfPresent(Float.self, forKey: .reverbMix) ?? defaults.reverbMix
    }

    /// The preset the equalizer is set to, if its gains are exactly one.
    public var equalizerPreset: EqualizerPreset? {
        EqualizerPreset.allCases.first { $0.listGains == listEqualizerGains }
    }

    /// Set the equalizer to a preset, turning it on.
    public mutating func applyEqualizerPreset(_ preset: EqualizerPreset) {
        listEqualizerGains = preset.listGains
        isEqualizerEnabled = true
    }

    /// Set the equalizer to a preset, or back to flat when it is set to that preset already.
    public mutating func toggleEqualizerPreset(_ preset: EqualizerPreset) {
        if isEqualizerEnabled && equalizerPreset == preset {
            listEqualizerGains = MixerTrackSettings().listEqualizerGains
        } else {
            applyEqualizerPreset(preset)
        }
    }

    /// Whether the sound has to be captured: to be treated, or to be silenced.
    public var isCaptureNeeded: Bool {
        isTakenOver || isMuted
    }

    /// The settings as they act on the sound: themselves while taken over, else none of the treatment,
    /// keeping only whether the sound is muted.
    public var effective: MixerTrackSettings {
        guard !isTakenOver else {
            return self
        }
        var neutral = MixerTrackSettings()
        neutral.isMuted = isMuted
        return neutral
    }

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
