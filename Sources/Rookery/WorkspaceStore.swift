import Foundation
import RookeryCore

/// Persists the workspace between launches.
enum WorkspaceStore {
    private static let fileName = "workspace.json"

    private static var url: URL {
        DataDirectory.file(named: fileName)
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
