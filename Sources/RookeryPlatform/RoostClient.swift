import Foundation
import RookeryCore

/// A failure talking to roost.
public enum RoostError: Error, CustomStringConvertible, Sendable {
    /// The address set is not an http or https URL.
    case invalidAddress(String)
    /// roost could not be reached.
    case unreachable(String)
    /// roost answered with an error status.
    case rejected(status: Int, message: String)
    /// roost answered with something that is not what its API promises.
    case malformed(String)

    public var description: String {
        switch self {
        case .invalidAddress(let address): "\(address) is not an http:// or https:// address"
        case .unreachable(let reason): "can't reach roost: \(reason)"
        case .rejected(401, _): "roost didn't accept the token"
        case .rejected(let status, let message): "roost answered \(status): \(message)"
        case .malformed(let reason): "roost sent something unexpected: \(reason)"
        }
    }
}

/// Where a roost server is and the token it asks for.
public struct RoostEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    /// An endpoint from an address as the user typed it, with or without a scheme or `/v1`.
    ///
    /// - Parameters:
    ///   - address: as `roost.example.com:8787` or `https://roost.example.com:8787`
    ///   - token: the server's token
    /// - Throws: `RoostError.invalidAddress`
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
            throw RoostError.invalidAddress(address)
        }
        self.baseURL = url
        self.token = token
    }
}

/// What roost's health check says about it.
public struct RoostHealth: Decodable, Equatable, Sendable {
    public let version: String
    /// The port of the live link, or nil for a roost without one.
    public let linkPort: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case linkPort = "link_port"
    }
}

/// A stretch of a transcript as roost stored it.
public struct RoostTranscriptChunk: Sendable {
    public let data: Data
    /// Where the stretch starts in the transcript.
    public let offset: Int
    /// The whole stored transcript's length; smaller than what the reader holds when the agent rewrote it.
    public let total: Int
}

/// roost's API as the app uses it: the agents and rooks, an agent's transcript, sending it text, and the
/// live link, over which the app follows the event log as a desktop. See `server/API.md`.
public final class RoostClient: Sendable {
    private static let requestTimeout: TimeInterval = 20
    private static let resourceLimit = 1000
    /// The most of a transcript one request reads.
    public static let transcriptChunkBytes = 4 * 1024 * 1024

    public let endpoint: RoostEndpoint
    private let session: URLSession

    public init(endpoint: RoostEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// The server's version and live link port; needs no token.
    public func health() async throws -> RoostHealth {
        try decode(RoostHealth.self, from: try await request("GET", path: "/v1/healthz"))
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

    /// Report events, as rook does for the agents it runs.
    ///
    /// - Parameter listEvents: the events, each an object as `POST /v1/events` takes it
    public func post(events listEvents: [[String: JSONValue]]) async throws {
        let body = try JSONEncoder().encode(["events": listEvents.map { JSONValue.object($0) }])
        _ = try await request("POST", path: "/v1/events", body: body)
    }

    /// The kinds of resource roost manages.
    public func kinds() async throws -> [FleetKind] {
        try decode(KindPage.self, from: try await request("GET", path: "/v1/kinds")).kinds
    }

    /// Every relation between resources.
    public func relations() async throws -> [FleetRelation] {
        try decode(RelationPage.self, from: try await request("GET", path: "/v1/relations")).relations
    }

    /// The latest events, oldest first.
    public func latestEvents(limit: Int) async throws -> [FleetEvent] {
        let data = try await request("GET", path: "/v1/events", query: [URLQueryItem(name: "limit", value: String(limit))])
        return try decode(EventPage.self, from: data).events
    }

    /// Add a resource, logged as the user's doing.
    ///
    /// - Parameters:
    ///   - kind: its kind
    ///   - mapBody: what roost takes for the kind: a skill's `source`, a playbook's fields, or a `name` and
    ///     `attributes`
    /// - Returns: the resource as roost keeps it
    public func create(_ kind: String, body mapBody: [String: JSONValue]) async throws -> FleetResource {
        let body = try JSONEncoder().encode(mapBody)
        return try decode(FleetResource.self, from: try await request("POST", path: "/v1/resources/\(kind)", body: body))
    }

    /// Change a resource, logged as the user's doing; fields left out are left alone, and `attributes`
    /// are merged in.
    ///
    /// - Parameters:
    ///   - ref: the resource
    ///   - mapBody: the fields to change, as roost takes them for the kind
    /// - Returns: the resource as roost keeps it now
    public func update(_ ref: FleetRef, body mapBody: [String: JSONValue]) async throws -> FleetResource {
        let body = try JSONEncoder().encode(mapBody)
        return try decode(FleetResource.self, from: try await request("PATCH", path: "/v1/resources/\(ref.kind)/\(ref.id)", body: body))
    }

    /// Ask roost to resolve a skill's tracked ref again and record what its repository has now.
    public func refreshSkill(_ skillId: String) async throws {
        _ = try await request("POST", path: "/v1/skills/\(skillId)/refresh")
    }

    /// Remove a resource and its relations, logged as the user's doing.
    public func delete(_ ref: FleetRef) async throws {
        _ = try await request("DELETE", path: "/v1/resources/\(ref.kind)/\(ref.id)")
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
        try await deliver(["to": agentId, "text": text])
    }

    /// Ask an agent's rook to stop what the agent is doing.
    public func interrupt(_ agentId: String) async throws -> FleetDelivery {
        try await deliver(["to": agentId, "kind": "interrupt"])
    }

    /// Ask an agent's rook to load a playbook into the agent's project in place of the one it follows.
    ///
    /// - Parameters:
    ///   - playbookId: the playbook
    ///   - agentId: the agent
    ///   - text: what to tell the agent once it is loaded, or empty to let it learn on its next turn
    public func loadPlaybook(_ playbookId: String, into agentId: String, text: String) async throws -> FleetDelivery {
        try await deliver(["to": agentId, "kind": "playbook", "text": text, "options": ["playbook": playbookId]])
    }

    /// Ask an agent's rook to answer the agent's approval prompt.
    ///
    /// - Parameter choice: `once`, allowing the one call, or `deny`
    public func approve(_ agentId: String, choice: String) async throws -> FleetDelivery {
        try await deliver(["to": agentId, "kind": "approve", "options": ["choice": choice]])
    }

    /// Ask a rook to start a new session.
    ///
    /// - Parameters:
    ///   - rookName: the rook
    ///   - cwd: the directory there, an absolute path
    ///   - harness: `claude` or `codex`
    ///   - prompt: the session's first prompt, or empty for none
    public func spawn(on rookName: String, cwd: String, harness: String, prompt: String) async throws -> FleetDelivery {
        try await deliver(["kind": "spawn", "rook": rookName, "text": prompt, "options": ["cwd": cwd, "harness": harness]])
    }

    /// Ask a rook to start a new agent for a launch: its directory, harness, what it installs first, its
    /// role and teams, and its first prompt.
    ///
    /// - Returns: the delivery, to follow
    public func launch(_ request: LaunchRequest) async throws -> FleetDelivery {
        let body = try JSONEncoder().encode(request.body)
        return try decode(FleetDelivery.self, from: try await self.request("POST", path: "/v1/messages", body: body))
    }

    /// Put an agent in a team with a duty, or give a member a new duty.
    public func join(_ agentId: String, team teamId: String, duty: String) async throws {
        let body = try JSONEncoder().encode(["agent": agentId, "duty": duty])
        _ = try await request("POST", path: "/v1/teams/\(teamId)/members", body: body)
    }

    /// Take an agent out of a team.
    public func leave(_ agentId: String, team teamId: String) async throws {
        _ = try await request("DELETE", path: "/v1/teams/\(teamId)/members/\(agentId)")
    }

    /// Send every other member of a team a message from the user.
    public func send(_ text: String, toTeam teamId: String) async throws {
        let body = try JSONEncoder().encode(["team": teamId, "text": text])
        _ = try await request("POST", path: "/v1/messages", body: body)
    }

    /// Let a message roost held go on, or drop it.
    ///
    /// - Parameter isReleased: true to let it go, false to cancel it
    public func decideHeld(_ deliveryId: String, isReleased: Bool) async throws -> FleetDelivery {
        let action = isReleased ? "release" : "cancel"
        return try decode(FleetDelivery.self, from: try await request("POST", path: "/v1/messages/\(deliveryId)/\(action)"))
    }

    /// The latest deliveries of every agent, newest first.
    public func recentDeliveries(limit: Int) async throws -> [FleetDelivery] {
        let data = try await request("GET", path: "/v1/messages", query: [URLQueryItem(name: "limit", value: String(limit))])
        return try decode(DeliveryPage.self, from: data).messages
    }

    private func deliver(_ mapBody: [String: Any]) async throws -> FleetDelivery {
        let body = try JSONSerialization.data(withJSONObject: mapBody)
        return try decode(FleetDelivery.self, from: try await request("POST", path: "/v1/messages", body: body))
    }

    /// The tokens registered for git hosts, each shown by its last characters.
    public func gitCredentials() async throws -> [GitCredential] {
        try decode(GitCredentialPage.self, from: try await request("GET", path: "/v1/credentials")).credentials
    }

    /// Register the token for a git host, or replace the one it has.
    ///
    /// - Parameters:
    ///   - host: the host, as `github.com` or `git.example.com:8443`
    ///   - username: the user name git gives with it, or empty for the host's usual one
    ///   - token: the token
    public func registerGitCredential(host: String, username: String, token: String) async throws -> GitCredential {
        let body = try JSONEncoder().encode(["username": username, "token": token])
        return try decode(GitCredential.self, from: try await request("PUT", path: "/v1/credentials/\(host)", body: body))
    }

    /// Forget the token for a git host.
    public func removeGitCredential(host: String) async throws {
        _ = try await request("DELETE", path: "/v1/credentials/\(host)")
    }

    /// Read a repository with the token registered for its host.
    ///
    /// - Parameter repo: a skill source or a git URL
    /// - Returns: the repository's default branch
    /// - Throws: `RoostError.rejected` with git's own words when it cannot be read
    public func checkGitAccess(repo: String) async throws -> String {
        let body = try JSONEncoder().encode(["repo": repo])
        return try decode(GitAccessCheck.self, from: try await request("POST", path: "/v1/credentials/check", body: body)).defaultBranch
    }

    /// The deliveries routed to a rook and not yet finished, oldest first, as Rookery reads those for its
    /// own agents.
    public func openDeliveries(forRook rookName: String) async throws -> [FleetDelivery] {
        let data = try await request("GET", path: "/v1/messages", query: [URLQueryItem(name: "rook", value: rookName)])
        return try decode(DeliveryPage.self, from: data).messages
    }

    /// Record what Rookery did with a delivery for one of its own agents.
    ///
    /// - Parameters:
    ///   - status: `delivered`, `waiting` or `failed`
    ///   - reason: how, or why not
    public func report(_ deliveryId: String, status: String, reason: String) async throws {
        let body = try JSONEncoder().encode(["status": status, "reason": reason])
        _ = try await request("POST", path: "/v1/messages/\(deliveryId)/report", body: body)
    }

    /// The latest deliveries to an agent, newest first.
    public func deliveries(to agentId: String) async throws -> [FleetDelivery] {
        let data = try await request("GET", path: "/v1/messages", query: [
            URLQueryItem(name: "agent", value: agentId),
            URLQueryItem(name: "limit", value: "50"),
        ])
        return try decode(DeliveryPage.self, from: data).messages
    }

    /// One delivery, as it stands now.
    public func delivery(_ deliveryId: String) async throws -> FleetDelivery {
        try decode(FleetDelivery.self, from: try await request("GET", path: "/v1/messages/\(deliveryId)"))
    }

    /// A session's transcript from a byte on.
    ///
    /// - Returns: the stretch, or nil when roost holds no transcript of the session
    public func transcript(of sessionId: String, from offset: Int, limit: Int = transcriptChunkBytes) async throws -> RoostTranscriptChunk? {
        var components = URLComponents(url: endpoint.baseURL.appending(path: "/v1/sessions/\(sessionId)/transcript"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else {
            throw RoostError.invalidAddress(endpoint.baseURL.absoluteString)
        }
        let (data, response) = try await perform(authorized(URLRequest(url: url)))
        if response.statusCode == 404 {
            return nil
        }
        try check(response, data: data)
        let total = Int(response.value(forHTTPHeaderField: "X-Rook-Total") ?? "") ?? offset + data.count
        let start = Int(response.value(forHTTPHeaderField: "X-Rook-Offset") ?? "") ?? offset
        return RoostTranscriptChunk(data: data, offset: start, total: total)
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
            throw RoostError.malformed("this roost has no live link; upgrade it")
        }
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = endpoint.baseURL.scheme == "https" ? "wss" : "ws"
        components?.port = linkPort
        components?.path = "/v1/link"
        guard let url = components?.url else {
            throw RoostError.invalidAddress(endpoint.baseURL.absoluteString)
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
            throw RoostError.invalidAddress(endpoint.baseURL.absoluteString)
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
            throw RoostError.unreachable(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoostError.malformed("not an HTTP answer")
        }
        return (data, httpResponse)
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else {
            return
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw RoostError.rejected(status: response.statusCode, message: message)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw RoostError.malformed(String(describing: error))
        }
    }

    private struct ResourcePage: Decodable {
        let resources: [FleetResource]
    }

    private struct EventPage: Decodable {
        let events: [FleetEvent]
    }

    private struct KindPage: Decodable {
        let kinds: [FleetKind]
    }

    private struct RelationPage: Decodable {
        let relations: [FleetRelation]
    }

    /// roost's listing of git credentials.
private struct GitCredentialPage: Decodable {
    let credentials: [GitCredential]
}

/// What roost answers when a repository could be read.
private struct GitAccessCheck: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
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
