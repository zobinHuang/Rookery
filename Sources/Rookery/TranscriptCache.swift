import CryptoKit
import Foundation
import os
import RookeryCore

/// The transcripts the app has read, kept so an agent's page opens on what it had and asks roost only for
/// what the transcript grew by since: each agent's reader in memory while the app runs, and the bytes read
/// in the user's caches directory across launches, from the byte reading began at.
@MainActor
final class TranscriptCache {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    private static let directoryName = "Rookery/transcripts"
    private static let startKey = "start_offset"

    private var mapReaders: [String: TranscriptReader] = [:]
    private let directory: URL

    init(directory: URL = URL.cachesDirectory.appending(path: TranscriptCache.directoryName, directoryHint: .isDirectory)) {
        self.directory = directory
    }

    /// The reader an agent's page left, or one rebuilt from the bytes kept on disk; nil when neither is.
    func reader(for agentId: String) async -> TranscriptReader? {
        if let reader = mapReaders[agentId] {
            return reader
        }
        guard
            let header = try? Data(contentsOf: headerUrl(for: agentId)),
            let map = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
            let startOffset = map[Self.startKey] as? Int
        else {
            return nil
        }
        let bytesUrl = bytesUrl(for: agentId)
        let reader = await Task.detached(priority: .userInitiated) { () -> TranscriptReader? in
            guard let data = try? Data(contentsOf: bytesUrl) else {
                return nil
            }
            var reader = TranscriptReader(startOffset: startOffset)
            reader.append(data)
            return reader
        }.value
        if let reader {
            mapReaders[agentId] = reader
        }
        return reader
    }

    /// Keep the bytes a reader just took in, after those kept already.
    ///
    /// - Parameters:
    ///   - data: the bytes, which follow those kept
    ///   - reader: the reader after taking them
    ///   - agentId: whose transcript it is
    func append(_ data: Data, after reader: TranscriptReader, for agentId: String) {
        mapReaders[agentId] = reader
        let headerUrl = headerUrl(for: agentId)
        let bytesUrl = bytesUrl(for: agentId)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if reader.byteCount == data.count || !FileManager.default.fileExists(atPath: bytesUrl.path) {
                let header = try JSONSerialization.data(withJSONObject: [Self.startKey: reader.startOffset])
                try header.write(to: headerUrl, options: .atomic)
                try data.write(to: bytesUrl, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: bytesUrl)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Self.logger.error("cannot keep the transcript of \(agentId, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Forget an agent's transcript, to read it again from wherever the page starts.
    func forget(_ agentId: String) {
        mapReaders[agentId] = nil
        try? FileManager.default.removeItem(at: headerUrl(for: agentId))
        try? FileManager.default.removeItem(at: bytesUrl(for: agentId))
    }

    /// Where an agent's kept bytes begin in its transcript.
    private func headerUrl(for agentId: String) -> URL {
        directory.appending(path: "\(Self.key(for: agentId)).json")
    }

    /// The bytes kept of an agent's transcript.
    private func bytesUrl(for agentId: String) -> URL {
        directory.appending(path: "\(Self.key(for: agentId)).jsonl")
    }

    private static func key(for agentId: String) -> String {
        SHA256.hash(data: Data(agentId.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
