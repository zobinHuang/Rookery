import AppKit
import MuxShotsControl
import MuxShotsCore
import MuxShotsPlatform
import Observation
import os

/// The mixer as the app runs it: which applications can be mixed, the settings of each, remembered across
/// launches, and the audio mixer that applies them.
@MainActor
@Observable
final class MixerController {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "mixer")
    private static let settingsKey = "mixerTracks"
    private static let meterInterval: TimeInterval = 1 / 30
    /// How much of its level a meter keeps from one reading to the next, so it falls back smoothly.
    private static let meterDecay: Float = 0.8

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let mixer = AudioMixer()
    /// The browser tabs, mixed one by one through the browser extension.
    @ObservationIgnored let browserTabs = BrowserTabMixer()
    @ObservationIgnored private var processObservation: AudioProcessObservation?
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var meterTimer: Timer?
    /// How many mixers are on screen, which are the only ones whose meters need reading.
    @ObservationIgnored private var meterViewerCount = 0
    /// The settings of every application ever adjusted, by bundle id.
    private var mapSettings: [String: MixerTrackSettings]
    /// Whether the mixer runs, between `start()` and `stop()`.
    private(set) var isRunning = false
    /// The applications that can be mixed: those connected to the audio system, and those taken over.
    private(set) var listTracks: [MixerTrackStatus] = []
    /// How loud each captured track is now, for its meter, by bundle id.
    private(set) var mapLevels: [String: MixerLevels] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mapSettings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: MixerTrackSettings].self, from: $0) } ?? [:]
    }

    /// Take over the sound of the applications taken over before, and keep the track list current.
    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        mixer.onChange = { [weak self] in
            self?.reloadTracks()
        }
        for (bundleId, settings) in mapSettings where settings.isCaptureNeeded {
            mixer.apply(settings, toApplication: bundleId)
        }
        processObservation = AudioProcessDirectory.observeChanges { [weak self] in
            self?.reloadTracks()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            applicationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadTracks()
                }
            })
        }
        reloadTracks()
    }

    /// Give every application its sound back.
    func stop() {
        isRunning = false
        meterTimer?.invalidate()
        meterTimer = nil
        mixer.releaseAll()
        processObservation?.invalidate()
        processObservation = nil
        for observer in applicationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        applicationObservers = []
    }

    func settings(of bundleId: String) -> MixerTrackSettings {
        mapSettings[bundleId] ?? MixerTrackSettings()
    }

    /// Change an application's settings, apply them and remember them.
    func update(_ bundleId: String, _ change: (inout MixerTrackSettings) -> Void) {
        var settings = settings(of: bundleId)
        change(&settings)
        apply(settings, to: bundleId)
    }

    /// Replace an application's settings, apply them and remember them.
    func apply(_ settings: MixerTrackSettings, to bundleId: String) {
        let settings = settings.clamped
        mapSettings[bundleId] = settings
        mixer.apply(settings, toApplication: bundleId)
        store()
        reloadTracks()
    }

    /// Start reading levels for a mixer that came on screen.
    func beginShowingMeters() {
        meterViewerCount += 1
        browserTabs.isMeterWanted = true
        updateMeterTimer()
    }

    /// Stop reading levels for a mixer that went off screen, once no mixer shows any.
    func endShowingMeters() {
        meterViewerCount = max(meterViewerCount - 1, 0)
        browserTabs.isMeterWanted = meterViewerCount > 0
        updateMeterTimer()
    }

    /// Read the captured tracks' levels for their meters while any track is captured and a mixer shows them.
    private func updateMeterTimer() {
        let isReading = meterViewerCount > 0 && listTracks.contains(where: \.isCapturing)
        if isReading, meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readLevels()
                }
            }
        } else if !isReading {
            meterTimer?.invalidate()
            meterTimer = nil
            if !mapLevels.isEmpty {
                mapLevels = [:]
            }
        }
    }

    private func readLevels() {
        var mapLevels: [String: MixerLevels] = [:]
        for track in listTracks where track.isCapturing {
            let raw = mixer.takeLevels(ofApplication: track.bundleId)
            let previous = self.mapLevels[track.bundleId] ?? MixerLevels()
            mapLevels[track.bundleId] = MixerLevels(
                left: max(raw.left, previous.left * Self.meterDecay),
                right: max(raw.right, previous.right * Self.meterDecay)
            )
        }
        if mapLevels != self.mapLevels {
            self.mapLevels = mapLevels
        }
    }

    private func reloadTracks() {
        let listProcesses = AudioProcessDirectory.listProcesses()
        let listApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        var setSeen = Set<String>()
        var listTracks: [MixerTrackStatus] = []
        for application in listApplications {
            guard let bundleId = application.bundleIdentifier, setSeen.insert(bundleId).inserted else {
                continue
            }
            let listOwned = listProcesses.filter { $0.belongs(toApplication: bundleId) }
            let settings = settings(of: bundleId)
            guard !listOwned.isEmpty || settings.isCaptureNeeded else {
                continue
            }
            listTracks.append(MixerTrackStatus(
                bundleId: bundleId,
                name: application.localizedName ?? bundleId,
                isPlaying: listOwned.contains(where: \.isPlaying),
                isCapturing: mixer.isCapturing(bundleId),
                error: mixer.mapErrors[bundleId],
                settings: settings
            ))
        }
        listTracks.sort { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying {
                return lhs.isPlaying
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if listTracks != self.listTracks {
            self.listTracks = listTracks
        }
        updateMeterTimer()
    }

    private func store() {
        do {
            defaults.set(try JSONEncoder().encode(mapSettings), forKey: Self.settingsKey)
        } catch {
            Self.logger.error("cannot store mixer settings: \(error)")
        }
    }
}

/// How loud a track's channels are, 0 silent to 1 full scale.
struct MixerLevels: Equatable {
    var left: Float = 0
    var right: Float = 0
}
