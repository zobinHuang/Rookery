import Foundation
import RookeryCore

/// A failure talking to rookd.
public enum RookdError: Error, CustomStringConvertible, Sendable {
    /// The address set is not an http or https URL.
    case invalidAddress(String)
    /// rookd could not be reached.
    case unreachable(String)
    /// rookd answered with an error status.
    case rejected(status: Int, message: String)
    /// rookd answered with something that is not what its API promises.
    case malformed(String)

    public var description: String {
        switch self {
        case .invalidAddress(let address): "\(address) is not an http:// or https:// address"
        case .unreachable(let reason): "can't reach rookd: \(reason)"
        case .rejected(401, _): "rookd didn't accept the token"
        case .rejected(let status, let message): "rookd answered \(status): \(message)"
        case .malformed(let reason): "rookd sent something unexpected: \(reason)"
        }
    }
}

/// Where a rookd server is and the token it asks for.
public struct RookdEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    /// An endpoint from an address as the user typed it, with or without a scheme or `/v1`.
    ///
    /// - Parameters:
    ///   - address: as `rookd.example.com:8787` or `https://rookd.example.com:8787`
    ///   - token: the server's token
    /// - Throws: `RookdError.invalidAddress`
    public init(address: String, token: String) throws {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed.removeLast(3)
        }
        guard
            let url = URL(string: trimmed),
            url.scheme == "http" || url.scheme == "https",
            url.host() != nil
        else {
            throw RookdError.invalidAddress(address)
        }
        self.baseURL = url
        self.token = token
    }
}

/// What rookd's health check says about it.
public struct RookdHealth: Decodable, Equatable, Sendable {
    public let version: String
    /// The port of the live link, or nil for a rookd without one.
    public let linkPort: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case linkPort = "link_port"
    }
}

/// A stretch of a transcript as rookd stored it.
public struct RookdTranscriptChunk: Sendable {
    public let data: Data
    /// Where the stretch starts in the transcript.
    public let offset: Int
    /// The whole stored transcript's length; smaller than what the reader holds when the agent rewrote it.
    public let total: Int
}

/// rookd's API as the app uses it: the agents and rooks, an agent's transcript, sending it text, and the
/// live link, over which the app follows the event log as a desktop. See `server/API.md`.
public final class RookdClient: Sendable {
    private static let requestTimeout: TimeInterval = 20
    private static let resourceLimit = 1000
    private static let transcriptChunkBytes = 4 * 1024 * 1024

    public let endpoint: RookdEndpoint
    private let session: URLSession

    public init(endpoint: RookdEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// The server's version and live link port; needs no token.
    public func health() async throws -> RookdHealth {
        try decode(RookdHealth.self, from: try await request("GET", path: "/v1/healthz"))
    }

    /// The resources of one kind, those last used first.
    public func resources(kind: String) async throws -> [FleetResource] {
        let data = try await request("GET", path: "/v1/resources", query: [
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "limit", value: String(Self.resourceLimit)),
        ])
        return try decode(ResourcePage.self, from: data).resources
    }

    /// One resource.
    public func resource(_ ref: FleetRef) async throws -> FleetResource {
        try decode(FleetResource.self, from: try await request("GET", path: "/v1/resources/\(ref.kind)/\(ref.id)"))
    }

    /// The sequence number of the last event logged, 0 when none is.
    public func lastSeq() async throws -> Int {
        let data = try await request("GET", path: "/v1/events", query: [URLQueryItem(name: "limit", value: "1")])
        return try decode(EventPage.self, from: data).events.last?.seq ?? 0
    }

    /// Send an agent text from the user, typed into its pane once it is ready.
    ///
    /// - Returns: the delivery, to follow
    public func send(_ text: String, to agentId: String) async throws -> FleetDelivery {
        let body = try JSONSerialization.data(withJSONObject: ["to": agentId, "text": text])
        return try decode(FleetDelivery.self, from: try await request("POST", path: "/v1/messages", body: body))
    }

    /// The latest deliveries to an agent, newest first.
    public func deliveries(to agentId: String) async throws -> [FleetDelivery] {
        let data = try await request("GET", path: "/v1/messages", query: [
            URLQueryItem(name: "agent", value: agentId),
            URLQueryItem(name: "limit", value: "50"),
        ])
        return try decode(DeliveryPage.self, from: data).messages
    }

    /// A session's transcript from a byte on.
    ///
    /// - Returns: the stretch, or nil when rookd holds no transcript of the session
    public func transcript(of sessionId: String, from offset: Int) async throws -> RookdTranscriptChunk? {
        var components = URLComponents(url: endpoint.baseURL.appending(path: "/v1/sessions/\(sessionId)/transcript"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(Self.transcriptChunkBytes)),
        ]
        guard let url = components?.url else {
            throw RookdError.invalidAddress(endpoint.baseURL.absoluteString)
        }
        let (data, response) = try await perform(authorized(URLRequest(url: url)))
        if response.statusCode == 404 {
            return nil
        }
        try check(response, data: data)
        let total = Int(response.value(forHTTPHeaderField: "X-Rook-Total") ?? "") ?? offset + data.count
        let start = Int(response.value(forHTTPHeaderField: "X-Rook-Offset") ?? "") ?? offset
        return RookdTranscriptChunk(data: data, offset: start, total: total)
    }

    /// Follow the event log over the live link, from after an event on, until the stream is cancelled or the
    /// link drops, when it throws.
    ///
    /// - Parameter seq: the last event already seen
    /// - Returns: the events, in order
    public func events(after seq: Int) -> AsyncThrowingStream<FleetEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let socket = try await openLink()
                    defer { socket.cancel(with: .goingAway, reason: nil) }
                    let hello = try JSONSerialization.data(withJSONObject: ["type": "hello", "role": "desktop", "after": seq])
                    try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
                    while !Task.isCancelled {
                        if let event = try Self.event(in: try await socket.receive()) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openLink() async throws -> URLSessionWebSocketTask {
        guard let linkPort = try await health().linkPort else {
            throw RookdError.malformed("this rookd has no live link; upgrade it")
        }
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components?.port = linkPort
        components?.path = "/v1/link"
        guard let url = components?.url else {
            throw RookdError.invalidAddress(endpoint.baseURL.absoluteString)
        }
        let socket = session.webSocketTask(with: authorized(URLRequest(url: url)))
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        return socket
    }

    private static func event(in message: URLSessionWebSocketTask.Message) throws -> FleetEvent? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        let envelope = try JSONDecoder().decode(LinkEnvelope.self, from: data)
        return envelope.type == "event" ? envelope.event : nil
    }

    private func request(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: endpoint.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw RookdError.invalidAddress(endpoint.baseURL.absoluteString)
        }
        var urlRequest = authorized(URLRequest(url: url))
        urlRequest.httpMethod = method
        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(urlRequest)
        try check(response, data: data)
        return data
    }

    private func authorized(_ urlRequest: URLRequest) -> URLRequest {
        var urlRequest = urlRequest
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private func perform(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw RookdError.unreachable(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RookdError.malformed("not an HTTP answer")
        }
        return (data, httpResponse)
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else {
            return
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw RookdError.rejected(status: response.statusCode, message: message)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw RookdError.malformed(String(describing: error))
        }
    }

    private struct ResourcePage: Decodable {
        let resources: [FleetResource]
    }

    private struct EventPage: Decodable {
        let events: [FleetEvent]
    }

    private struct DeliveryPage: Decodable {
        let messages: [FleetDelivery]
    }

    private struct ErrorBody: Decodable {
        let message: String
    }

    private struct LinkEnvelope: Decodable {
        let type: String
        let event: FleetEvent?
    }
}
