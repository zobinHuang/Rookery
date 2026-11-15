import AVFoundation
import CoreAudio
import RookeryCore

/// Takes over the sound of chosen applications and plays it again through a track of its own for each:
/// stereo treatment, an equalizer, reverb, volume and pan, mixed out to the current output device.
///
/// An application's sound is captured with a process tap covering every process playing for it, so a
/// browser's audio helper counts, and the tap is renewed as those processes come and go.
@MainActor
public final class AudioMixer {
    private let engine = AVAudioEngine()
    private var mapTracks: [String: Track] = [:]
    private var processObservation: AudioProcessObservation?
    private var configurationObserver: NSObjectProtocol?
    /// Why taking over an application's sound last failed, by its bundle id.
    public private(set) var mapErrors: [String: String] = [:]
    /// Called when a track starts or stops capturing, or fails to.
    public var onChange: (() -> Void)?

    public init() {}

    /// The bundle ids of the applications whose sound is taken over.
    public var listTakenOverBundleIds: [String] {
        Array(mapTracks.keys)
    }

    /// Whether an application's sound is being captured right now, rather than waiting for it to play.
    public func isCapturing(_ bundleId: String) -> Bool {
        mapTracks[bundleId]?.tap != nil
    }

    /// Apply an application's track settings, capturing its sound while it is taken over or muted, and
    /// giving it back otherwise.
    public func apply(_ settings: MixerTrackSettings, toApplication bundleId: String) {
        let settings = settings.clamped
        guard settings.isCaptureNeeded else {
            release(bundleId)
            return
        }
        let track = mapTracks[bundleId] ?? makeTrack(for: bundleId)
        track.settings = settings
        track.applySettings()
        renewTap(of: track)
    }

    /// The loudest each channel of an application's track has been since this was last asked.
    public func takeLevels(ofApplication bundleId: String) -> (left: Float, right: Float) {
        guard let levels = mapTracks[bundleId]?.processor.takeLevels() else {
            return (0, 0)
        }
        return (levels.left, levels.right)
    }

    /// Give every application its sound back.
    public func releaseAll() {
        for bundleId in Array(mapTracks.keys) {
            release(bundleId)
        }
    }

    // MARK: - Tracks

    private func makeTrack(for bundleId: String) -> Track {
        let track = Track(bundleId: bundleId)
        mapTracks[bundleId] = track
        if processObservation == nil {
            processObservation = AudioProcessDirectory.observeChanges { [weak self] in
                self?.renewTaps()
            }
        }
        if configurationObserver == nil {
            // The output device changed; the taps play through the old one, so set everything up afresh.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuildAll()
                }
            }
        }
        return track
    }

    private func release(_ bundleId: String) {
        mapErrors[bundleId] = nil
        guard let track = mapTracks.removeValue(forKey: bundleId) else {
            return
        }
        stopCapturing(track)
        if mapTracks.isEmpty {
            engine.stop()
            processObservation?.invalidate()
            processObservation = nil
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
            }
            configurationObserver = nil
        }
        onChange?()
    }

    private func renewTaps() {
        for track in mapTracks.values {
            renewTap(of: track)
        }
    }

    private func rebuildAll() {
        for track in mapTracks.values {
            stopCapturing(track)
        }
        renewTaps()
    }

    /// Capture exactly the processes now playing for a track's application, starting, renewing or stopping
    /// its tap as they change. Processes that are merely connected but silent are left out, so an idle
    /// application is not tapped at all.
    private func renewTap(of track: Track) {
        let listProcesses = AudioProcessDirectory.listProcesses(ofApplication: track.bundleId)
        let listObjectIds = listProcesses.filter(\.isPlaying).map(\.objectId).sorted()
        // Keep the processes already tapped while they live, even when they pause, so a pause does not
        // tear the tap down and put it up again.
        let setAlive = Set(listProcesses.map(\.objectId))
        let listKept = track.listTappedObjectIds.filter { setAlive.contains($0) }
        let listWanted = Array(Set(listObjectIds).union(listKept)).sorted()
        guard listWanted != track.listTappedObjectIds || (track.tap == nil && !listWanted.isEmpty) else {
            return
        }
        stopCapturing(track)
        guard !listWanted.isEmpty else {
            onChange?()
            return
        }
        do {
            let tap = try ProcessTap(listProcessObjectIds: listWanted, name: "Rookery \(track.bundleId)", ringBuffer: track.ringBuffer)
            track.tap = tap
            track.listTappedObjectIds = listWanted
            try connect(track, sampleRate: tap.sampleRate)
            mapErrors[track.bundleId] = nil
        } catch {
            stopCapturing(track)
            mapErrors[track.bundleId] = String(describing: error)
        }
        onChange?()
    }

    /// Wire a track's nodes into the engine at the tap's sample rate, starting the engine if needed.
    private func connect(_ track: Track, sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return
        }
        let sourceNode = track.makeSourceNode(format: format)
        track.sourceNode = sourceNode
        for node in [sourceNode, track.equalizer, track.reverb, track.trackMixer] {
            engine.attach(node)
        }
        engine.connect(sourceNode, to: track.equalizer, format: format)
        engine.connect(track.equalizer, to: track.reverb, format: format)
        engine.connect(track.reverb, to: track.trackMixer, format: format)
        engine.connect(track.trackMixer, to: engine.mainMixerNode, format: format)
        track.applySettings()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func stopCapturing(_ track: Track) {
        track.tap?.invalidate()
        track.tap = nil
        track.listTappedObjectIds = []
        if let sourceNode = track.sourceNode {
            for node in [sourceNode, track.equalizer, track.reverb, track.trackMixer] where node.engine != nil {
                engine.detach(node)
            }
        }
        track.sourceNode = nil
        track.ringBuffer.clear()
    }
}

/// One application's sound on its way through the mixer.
@MainActor
private final class Track {
    /// The sample rate the buffer is sized for; at other common rates the times below change little.
    private static let assumedSampleRate = 48_000.0
    private static let ringBufferSeconds = 0.5
    /// How much the capture may run ahead of the playback before the oldest frames are dropped, which
    /// bounds the delay the takeover adds.
    private static let maxBufferedSeconds = 0.04

    let bundleId: String
    var settings = MixerTrackSettings()
    let ringBuffer: AudioRingBuffer
    let processor = StereoProcessor()
    let equalizer = AVAudioUnitEQ(numberOfBands: MixerTrackSettings.listEqualizerFrequencies.count)
    let reverb = AVAudioUnitReverb()
    /// The track's last node, whose pan places it in the mix.
    let trackMixer = AVAudioMixerNode()
    var sourceNode: AVAudioSourceNode?
    var tap: ProcessTap?
    var listTappedObjectIds: [AudioObjectID] = []
    private var appliedReverbRoom: ReverbRoom?

    init(bundleId: String) {
        self.bundleId = bundleId
        ringBuffer = AudioRingBuffer(
            capacity: Int(Self.assumedSampleRate * Self.ringBufferSeconds),
            maxFill: Int(Self.assumedSampleRate * Self.maxBufferedSeconds)
        )
        let listFrequencies = MixerTrackSettings.listEqualizerFrequencies
        for (index, band) in equalizer.bands.enumerated() {
            band.frequency = listFrequencies[index]
            band.filterType = index == 0 ? .lowShelf : index == listFrequencies.count - 1 ? .highShelf : .parametric
            band.bandwidth = 1
            band.bypass = false
        }
    }

    /// The node that pulls the captured frames and treats their stereo image.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(ringBuffer: ringBuffer, processor: processor))
    }

    /// The render block, built outside the main actor since it runs on the audio render thread.
    private nonisolated static func renderBlock(
        ringBuffer: AudioRingBuffer,
        processor: StereoProcessor
    ) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            let listBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard
                listBuffers.count >= 2,
                let left = listBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = listBuffers[1].mData?.assumingMemoryBound(to: Float.self)
            else {
                return noErr
            }
            ringBuffer.read(frameCount: Int(frameCount), left: left, right: right)
            processor.process(frameCount: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    func applySettings() {
        let settings = settings.effective
        processor.setParameters(StereoProcessor.Parameters(
            isLeftInverted: settings.isLeftInverted,
            isRightInverted: settings.isRightInverted,
            isSwapped: settings.isSwapped,
            width: settings.width,
            gain: settings.volume
        ))
        equalizer.bypass = !settings.isEqualizerEnabled
        for (band, gain) in zip(equalizer.bands, settings.listEqualizerGains) {
            band.gain = gain
        }
        if appliedReverbRoom != settings.reverbRoom {
            reverb.loadFactoryPreset(settings.reverbRoom.preset)
            appliedReverbRoom = settings.reverbRoom
        }
        reverb.wetDryMix = settings.reverbMix
        reverb.bypass = settings.reverbMix == 0
        trackMixer.pan = settings.pan
        trackMixer.outputVolume = settings.isMuted ? 0 : 1
    }
}

private extension ReverbRoom {
    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: .smallRoom
        case .mediumRoom: .mediumRoom
        case .largeRoom: .largeRoom
        case .mediumHall: .mediumHall
        case .largeHall: .largeHall
        case .plate: .plate
        case .cathedral: .cathedral
        }
    }
}
