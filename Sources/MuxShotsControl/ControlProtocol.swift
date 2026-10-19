import Foundation
import MuxShotsCore

/// A request `muxctl` sends to the running app.
public enum ControlRequest: Codable, Sendable {
    /// Reply once with the groups and the observed state of their windows.
    case list
    /// Reply with the groups and their windows, then stream every window change until the client disconnects.
    case watch
    /// Manage a window in a group, named or by 1-based position, or in a new group when nil.
    case manage(windowId: WindowId, groupNameOrPosition: String?)
    /// Stop managing a window.
    case release(windowId: WindowId)
    /// Act on a managed window.
    case act(action: WindowAction, windowId: WindowId)
    /// Show a group, named or by 1-based position, hiding the others; nil shows every managed window.
    case switchGroup(nameOrPosition: String?)
    /// Open or close the stage.
    case stage(isOpen: Bool)
    /// Reply with the mixer's tracks.
    case mixer
    /// Change how the mixer treats an application's sound, taking it over or giving it back as the settings
    /// say, then reply with the mixer's tracks.
    case mixerApply(bundleId: String, settings: MixerTrackSettings)
}

/// An application's sound as the mixer sees it.
public struct MixerTrackStatus: Codable, Equatable, Sendable {
    public let bundleId: String
    public let name: String
    /// Whether the application, or a helper of it, is playing sound.
    public let isPlaying: Bool
    /// Whether MuxShots is capturing the sound right now, rather than waiting for it to play.
    public let isCapturing: Bool
    /// Why taking the sound over last failed.
    public let error: String?
    public let settings: MixerTrackSettings

    public init(bundleId: String, name: String, isPlaying: Bool, isCapturing: Bool, error: String?, settings: MixerTrackSettings) {
        self.bundleId = bundleId
        self.name = name
        self.isPlaying = isPlaying
        self.isCapturing = isCapturing
        self.error = error
        self.settings = settings
    }
}

/// A message the running app sends back.
public enum ControlMessage: Codable, Sendable {
    case workspace(listGroups: [WindowGroup], setActiveGroupIds: Set<GroupId>, listWindows: [WindowRecord])
    case change(WindowChange)
    /// The mixer's tracks, with how loud each captured one has been since last asked, 0 to 1, by bundle id.
    case mixer(listTracks: [MixerTrackStatus], mapLevels: [String: Float])
    case done
    case failure(message: String)
}

/// Where the running app listens for control connections.
public enum ControlSocket {
    private static let directoryName = "MuxShots"
    private static let fileName = "control.sock"

    /// The socket path, inside the user's Application Support directory.
    public static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }
}
