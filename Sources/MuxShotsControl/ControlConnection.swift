import Foundation
import Network

/// A failure on a control connection.
public enum ControlConnectionError: Error, Sendable, CustomStringConvertible {
    case unreachable(path: String, reason: String)
    case transport(reason: String)

    public var description: String {
        switch self {
        case .unreachable(let path, let reason):
            "cannot connect to \(path) (is MuxShots running?): \(reason)"
        case .transport(let reason):
            "control connection failed: \(reason)"
        }
    }
}

/// One end of a control connection, carrying newline-delimited JSON messages.
public final class ControlConnection: @unchecked Sendable {
    // `buffer` is touched only by `receive`, which a single consumer calls one at a time.
    private static let delimiter = UInt8(ascii: "\n")
    private static let maximumReadLength = 64 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MuxShots.control.connection")
    private var buffer = Data()

    /// Wrap a connection the listener accepted and start it.
    public init(accepted connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
    }

    private init(outgoing connection: NWConnection) {
        self.connection = connection
    }

    /// Connect to the running app's control socket.
    public static func connect(to url: URL) async throws -> ControlConnection {
        let connection = ControlConnection(outgoing: NWConnection(to: .unix(path: url.path), using: .tcp))
        try await connection.waitUntilReady(path: url.path)
        return connection
    }

    /// Send one message.
    public func send<Message: Encodable>(_ message: Message) async throws {
        var data = try JSONEncoder().encode(message)
        data.append(Self.delimiter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ControlConnectionError.transport(reason: "\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receive the next message.
    ///
    /// - Returns: the message, or nil once the peer has closed the connection
    public func receive<Message: Decodable>(_ type: Message.Type) async throws -> Message? {
        while true {
            if let delimiterIndex = buffer.firstIndex(of: Self.delimiter) {
                let line = buffer[buffer.startIndex..<delimiterIndex]
                buffer.removeSubrange(buffer.startIndex...delimiterIndex)
                return try JSONDecoder().decode(type, from: line)
            }
            guard let chunk = try await readChunk() else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    /// Close the connection.
    public func cancel() {
        connection.cancel()
    }

    private func readChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReadLength) {
                content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if let error {
                    continuation.resume(throwing: ControlConnectionError.transport(reason: "\(error)"))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func waitUntilReady(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .waiting(let error), .failed(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(throwing: ControlConnectionError.unreachable(path: path, reason: "\(error)"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
