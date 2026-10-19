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
}

/// A message the running app sends back.
public enum ControlMessage: Codable, Sendable {
    case workspace(listGroups: [WindowGroup], activeGroupId: GroupId?, listWindows: [WindowRecord])
    case change(WindowChange)
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
