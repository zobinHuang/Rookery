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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let mixer = AudioMixer()
    @ObservationIgnored private var processObservation: AudioProcessObservation?
    @ObservationIgnored private var applicationObservers: [NSObjectProtocol] = []
    /// The settings of every application ever adjusted, by bundle id.
    private var mapSettings: [String: MixerTrackSettings]
    /// The applications that can be mixed: those connected to the audio system, and those taken over.
    private(set) var listTracks: [MixerTrackStatus] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mapSettings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: MixerTrackSettings].self, from: $0) } ?? [:]
    }

    /// Take over the sound of the applications taken over before, and keep the track list current.
    func start() {
        mixer.onChange = { [weak self] in
            self?.reloadTracks()
        }
        for (bundleId, settings) in mapSettings where settings.isTakenOver {
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

    /// How loud each channel of an application's track has been since this was last asked, 0 to 1.
    func takeLevels(of bundleId: String) -> (left: Float, right: Float) {
        mixer.takeLevels(ofApplication: bundleId)
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
            guard !listOwned.isEmpty || settings.isTakenOver else {
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
    }

    private func store() {
        do {
            defaults.set(try JSONEncoder().encode(mapSettings), forKey: Self.settingsKey)
        } catch {
            Self.logger.error("cannot store mixer settings: \(error)")
        }
    }
}
