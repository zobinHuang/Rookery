import Foundation
import MuxShotsCore

/// Persists the workspace between launches.
enum WorkspaceStore {
    private static let directoryName = "MuxShots"
    private static let fileName = "workspace.json"

    private static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The saved workspace, or an empty one on first launch.
    static func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Workspace()
        }
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
    }

    static func save(_ workspace: Workspace) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: url, options: .atomic)
    }
}
