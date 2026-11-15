import Foundation

/// The directory Rookery keeps its files in, inside the user's Application Support directory: the
/// workspace, the quick notes and the control socket.
public enum DataDirectory {
    /// The directory's name, the app's own.
    public static let name = "Rookery"

    /// Where the directory is.
    public static var url: URL {
        URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// A file inside the directory.
    ///
    /// - Parameter fileName: the file's name
    /// - Returns: where the file is
    public static func file(named fileName: String) -> URL {
        url.appending(path: fileName, directoryHint: .notDirectory)
    }
}
