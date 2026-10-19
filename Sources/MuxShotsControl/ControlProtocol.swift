import Foundation
import MuxShotsCore

/// A request `muxctl` sends to the running app.
public enum ControlRequest: Codable, Sendable {
    /// Reply once with every tracked window.
    case list
    /// Reply with every tracked window, then stream every change until the client disconnects.
    case watch
}

/// A message the running app sends back.
public enum ControlMessage: Codable, Sendable {
    case windows(listWindows: [WindowRecord])
    case change(WindowChange)
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
