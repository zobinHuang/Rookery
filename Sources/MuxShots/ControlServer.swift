import Foundation
import MuxShotsControl
import MuxShotsPlatform
import Network
import os

/// Serves `muxctl` requests on the control socket.
final class ControlServer: Sendable {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "control")

    private let tracker: WindowTracker
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MuxShots.control.listener")

    /// Bind the control socket, replacing a stale one left by an earlier run.
    init(tracker: WindowTracker) throws {
        let url = ControlSocket.url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: url.path)
        self.listener = try NWListener(using: parameters)
        self.tracker = tracker
    }

    /// Start accepting connections.
    func start() {
        listener.newConnectionHandler = { [tracker] connection in
            let control = ControlConnection(accepted: connection)
            Task {
                await Self.serve(control, tracker: tracker)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("control listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    /// Stop accepting connections and remove the socket.
    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: ControlSocket.url)
    }

    private static func serve(_ connection: ControlConnection, tracker: WindowTracker) async {
        defer { connection.cancel() }
        do {
            guard let request = try await connection.receive(ControlRequest.self) else {
                return
            }
            switch request {
            case .list:
                try await connection.send(ControlMessage.windows(listWindows: await tracker.listWindows()))
            case .watch:
                let changes = await tracker.changes()
                try await connection.send(ControlMessage.windows(listWindows: await tracker.listWindows()))
                for await change in changes {
                    try await connection.send(ControlMessage.change(change))
                }
            }
        } catch {
            logger.info("control session ended: \(error)")
        }
    }
}
