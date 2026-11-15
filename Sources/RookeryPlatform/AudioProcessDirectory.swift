import CoreAudio
import Foundation

/// A process Core Audio knows about, as it plays or records sound.
public struct AudioProcess: Equatable, Sendable {
    public let objectId: AudioObjectID
    public let processId: pid_t
    /// The bundle id of the process, empty for processes without one.
    public let bundleId: String
    /// Whether the process is playing sound right now.
    public let isPlaying: Bool

    /// Whether the process plays sound on behalf of an application, as the application itself or as one
    /// of its helpers, such as a browser's audio service, whose bundle ids extend the application's.
    public func belongs(toApplication applicationBundleId: String) -> Bool {
        bundleId == applicationBundleId || bundleId.hasPrefix(applicationBundleId + ".")
    }
}

/// The processes Core Audio knows about, and word of when that list changes.
public enum AudioProcessDirectory {
    /// Every process with an audio connection, playing or not.
    public static func listProcesses() -> [AudioProcess] {
        let listObjectIds = (try? AudioObject.list(kAudioHardwarePropertyProcessObjectList, of: AudioObject.system, as: AudioObjectID.self)) ?? []
        return listObjectIds.compactMap { objectId in
            guard let processId = try? AudioObject.value(kAudioProcessPropertyPID, of: objectId, as: pid_t.self) else {
                return nil
            }
            let isPlaying = (try? AudioObject.value(kAudioProcessPropertyIsRunningOutput, of: objectId, as: UInt32.self)) ?? 0
            return AudioProcess(
                objectId: objectId,
                processId: processId,
                bundleId: (try? AudioObject.string(kAudioProcessPropertyBundleID, of: objectId)) ?? "",
                isPlaying: isPlaying != 0
            )
        }
    }

    /// The processes of one application, with its helpers.
    public static func listProcesses(ofApplication bundleId: String) -> [AudioProcess] {
        listProcesses().filter { $0.belongs(toApplication: bundleId) }
    }

    /// Call back on the main queue whenever a process gains or loses its audio connection, or starts or
    /// stops playing; keep the returned observation for as long as the callbacks are wanted.
    @MainActor
    public static func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> AudioProcessObservation {
        AudioProcessObservation(onChange: onChange)
    }
}

/// Word of changes to the audio processes, for as long as it is kept.
@MainActor
public final class AudioProcessObservation {
    private let onChange: @MainActor () -> Void
    private var systemListener: AudioObjectPropertyListenerBlock?
    /// The listener on each process, which reports starting and stopping to play on its own.
    private var listProcessListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []

    fileprivate init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.listenToProcesses()
                self?.onChange()
            }
        }
        var address = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObject.system, &address, .main, listener)
        systemListener = listener
        listenToProcesses()
    }

    /// Stop the callbacks.
    public func invalidate() {
        if let systemListener {
            var address = AudioObject.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObject.system, &address, .main, systemListener)
        }
        systemListener = nil
        removeProcessListeners()
    }

    private func listenToProcesses() {
        removeProcessListeners()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.onChange()
            }
        }
        var address = AudioObject.address(kAudioProcessPropertyIsRunningOutput)
        for process in AudioProcessDirectory.listProcesses() {
            AudioObjectAddPropertyListenerBlock(process.objectId, &address, .main, listener)
            listProcessListeners.append((process.objectId, listener))
        }
    }

    private func removeProcessListeners() {
        var address = AudioObject.address(kAudioProcessPropertyIsRunningOutput)
        for (objectId, listener) in listProcessListeners {
            AudioObjectRemovePropertyListenerBlock(objectId, &address, .main, listener)
        }
        listProcessListeners = []
    }
}
