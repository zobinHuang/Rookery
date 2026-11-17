import Darwin
import Foundation

/// A failure to catch a sign-in coming back to the Mac.
public enum LoopbackError: Error, CustomStringConvertible {
    case socketFailed(String)
    case timedOut
    case cancelled

    public var description: String {
        switch self {
        case .socketFailed(let reason): "cannot listen for the sign-in: \(reason)"
        case .timedOut: "the sign-in did not come back in time"
        case .cancelled: "the sign-in was cancelled"
        }
    }
}

/// One request a browser makes to a port on the Mac's loopback address, as a provider's sign-in returns
/// there: it listens on a port the system picks, takes the first request, answers it with a page saying
/// the browser can be closed, and hands back the request's query.
public final class LoopbackReceiver: Sendable {
    private static let pollIntervalMilliseconds: Int32 = 200
    private static let requestBytes = 16 * 1024
    private static let page = """
        <!doctype html><meta charset="utf-8"><title>Rookery</title>
        <body style="font: 15px -apple-system; text-align: center; padding-top: 80px">
        <p>Signed in. You can close this tab and go back to Rookery.</p></body>
        """

    private let socket: Int32
    /// The port it listens on.
    public let port: Int

    /// Listen on a port of 127.0.0.1 the system picks.
    ///
    /// - Throws: `LoopbackError.socketFailed`
    public init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw LoopbackError.socketFailed(String(cString: strerror(errno)))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isBound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(socket, generic, length) == 0
                    && Darwin.listen(socket, 1) == 0
                    && getsockname(socket, generic, &length) == 0
            }
        }
        guard isBound else {
            let reason = String(cString: strerror(errno))
            close(socket)
            throw LoopbackError.socketFailed(reason)
        }
        self.socket = socket
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        close(socket)
    }

    /// Wait for the browser's request, off the calling thread, and answer it.
    ///
    /// - Parameter timeout: how long to wait
    /// - Returns: the request's query, without the `?`
    /// - Throws: `LoopbackError`
    public func receiveQuery(timeout: Duration) async throws -> String {
        let deadline = Date.now.addingTimeInterval(Double(timeout.components.seconds))
        return try await Task.detached(priority: .userInitiated) { [self] in
            try self.acceptQuery(until: deadline)
        }.value
    }

    private func acceptQuery(until deadline: Date) throws -> String {
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        while Date.now < deadline {
            if Task.isCancelled {
                throw LoopbackError.cancelled
            }
            guard poll(&descriptor, 1, Self.pollIntervalMilliseconds) > 0 else {
                continue
            }
            let client = accept(socket, nil, nil)
            guard client >= 0 else {
                continue
            }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: Self.requestBytes)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                continue
            }
            let requestLine = String(decoding: buffer[0..<count], as: UTF8.self).split(separator: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n"
                + "Content-Length: \(Self.page.utf8.count)\r\n\r\n" + Self.page
            _ = response.withCString { pointer in
                write(client, pointer, strlen(pointer))
            }
            guard let queryStart = target.firstIndex(of: "?") else {
                continue
            }
            return String(target[target.index(after: queryStart)...])
        }
        throw LoopbackError.timedOut
    }
}
