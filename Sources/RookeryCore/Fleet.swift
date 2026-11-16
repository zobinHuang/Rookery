import Foundation

/// A JSON value of any shape, for the attributes and details roost keeps per kind of resource.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The value as text, or nil when it is not a non-empty string.
    public var stringValue: String? {
        guard case .string(let value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The value as a flag, or nil when it is not a boolean.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    /// The field of an object, or nil when this is not an object or lacks it.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let mapFields) = self else {
            return nil
        }
        return mapFields[key]
    }
}

/// A pointer at one resource on roost: its kind and its id within the kind.
public struct FleetRef: Codable, Hashable, Sendable {
    public let kind: String
    public let id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// One resource as roost serves it: an agent, a skill, a playbook, a memory or a rook.
public struct FleetResource: Decodable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public let name: String
    public let mapAttributes: [String: JSONValue]
    public let lastUsedAt: String

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case name
        case mapAttributes = "attributes"
        case lastUsedAt = "last_used_at"
    }

    public init(kind: String, id: String, name: String, mapAttributes: [String: JSONValue], lastUsedAt: String) {
        self.kind = kind
        self.id = id
        self.name = name
        self.mapAttributes = mapAttributes
        self.lastUsedAt = lastUsedAt
    }
}

/// What a code agent session is doing, one crow animation each, as rook reports it.
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case working
    case needsApproval = "needs_approval"
    case needsInput = "needs_input"
    case compacting
    case done
    case error
    case rateLimited = "rate_limited"
    case ended

    /// The state as the app names it.
    public var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .working: "Working"
        case .needsApproval: "Needs approval"
        case .needsInput: "Needs input"
        case .compacting: "Compacting"
        case .done: "Done"
        case .error: "Error"
        case .rateLimited: "Rate limited"
        case .ended: "Ended"
        }
    }

    /// Whether the agent waits on the user: for an approval, an answer, or after a failure.
    public var needsAttention: Bool {
        switch self {
        case .needsApproval, .needsInput, .error, .rateLimited: true
        default: false
        }
    }

    /// Whether the agent is busy on its own.
    public var isBusy: Bool {
        self == .thinking || self == .working || self == .compacting
    }
}

/// An agent: one session of a code agent, or a subagent it spawned, as the fleet keeps it.
public struct FleetAgent: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var state: AgentState
    public var harness: String
    public var rookName: String
    public var tab: String
    public var cwd: String
    public var gitBranch: String
    public var model: String
    public var hostname: String
    /// The session this agent is a subagent of, or nil for a session of its own.
    public var parentId: String?
    public var lastUsedAt: String

    public init(
        id: String,
        name: String,
        state: AgentState,
        harness: String = "",
        rookName: String = "",
        tab: String = "",
        cwd: String = "",
        gitBranch: String = "",
        model: String = "",
        hostname: String = "",
        parentId: String? = nil,
        lastUsedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.harness = harness
        self.rookName = rookName
        self.tab = tab
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.model = model
        self.hostname = hostname
        self.parentId = parentId
        self.lastUsedAt = lastUsedAt
    }

    /// The agent an agent resource describes.
    ///
    /// - Parameter resource: a resource of kind `agent`
    public init(resource: FleetResource) {
        let mapAttributes = resource.mapAttributes
        let isClosed = mapAttributes["closed_at"]?.stringValue != nil
        self.init(
            id: resource.id,
            name: resource.name,
            state: isClosed ? .ended : AgentState(rawValue: mapAttributes["state"]?.stringValue ?? "") ?? .idle,
            harness: mapAttributes["harness"]?.stringValue ?? "",
            rookName: mapAttributes["rook_name"]?.stringValue ?? "",
            tab: mapAttributes["tab"]?.stringValue ?? "",
            cwd: mapAttributes["cwd"]?.stringValue ?? "",
            gitBranch: mapAttributes["git_branch"]?.stringValue ?? "",
            model: mapAttributes["model"]?.stringValue ?? "",
            hostname: mapAttributes["machine"]?["hostname"]?.stringValue ?? "",
            parentId: mapAttributes["parent"]?.stringValue,
            lastUsedAt: resource.lastUsedAt
        )
    }

    /// The working directory's last component, which names the project.
    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// One thing roost logged: who did what to what.
public struct FleetEvent: Decodable, Equatable, Sendable {
    public let seq: Int
    public let at: String
    public let actor: FleetRef
    public let verb: String
    public let object: FleetRef?
    public let mapDetail: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case seq
        case at
        case actor
        case verb
        case object
        case mapDetail = "detail"
    }

    public init(seq: Int, at: String, actor: FleetRef, verb: String, object: FleetRef? = nil, mapDetail: [String: JSONValue] = [:]) {
        self.seq = seq
        self.at = at
        self.actor = actor
        self.verb = verb
        self.object = object
        self.mapDetail = mapDetail
    }
}

/// Text on its way to an agent, and what became of it.
public struct FleetDelivery: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let agentId: String
    public let text: String
    public let sender: FleetRef
    public var status: String
    public var mapDetail: [String: JSONValue]
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case text
        case sender
        case status
        case mapDetail = "detail"
        case createdAt = "created_at"
    }

    /// Why it waits or failed, or how it arrived.
    public var reason: String {
        mapDetail["reason"]?.stringValue ?? ""
    }
}

/// What applying an event to the fleet did.
public enum FleetEventEffect: Equatable, Sendable {
    /// Nothing the fleet shows changed.
    case unchanged
    /// The fleet changed in place.
    case changed
    /// The fleet changed in a way only roost's copy of this resource can tell; fetch it again.
    case refetch(FleetRef)
}

/// The agents and rooks roost knows of, kept current by applying its events in order.
public struct AgentFleet: Equatable, Sendable {
    public static let agentKind = "agent"
    public static let rookKind = "rook"

    public private(set) var mapAgents: [String: FleetAgent] = [:]
    /// Whether each rook holds its link open, by name.
    public private(set) var mapRooksOnline: [String: Bool] = [:]
    /// The last event applied.
    public private(set) var lastSeq = 0

    public init() {}

    /// Replace everything with a fresh read of roost's resources.
    ///
    /// - Parameters:
    ///   - listResources: the agents and rooks, as roost serves them
    ///   - lastSeq: the last event logged when they were read
    public mutating func load(_ listResources: [FleetResource], lastSeq: Int) {
        mapAgents = [:]
        mapRooksOnline = [:]
        for resource in listResources {
            put(resource)
        }
        self.lastSeq = lastSeq
    }

    /// Take in one resource as roost serves it now.
    public mutating func put(_ resource: FleetResource) {
        switch resource.kind {
        case Self.agentKind:
            mapAgents[resource.id] = FleetAgent(resource: resource)
        case Self.rookKind:
            mapRooksOnline[resource.id] = resource.mapAttributes["online"]?.boolValue ?? false
        default:
            break
        }
    }

    /// Apply one event, unless it was applied already.
    ///
    /// - Parameter event: the next event from roost
    /// - Returns: what it did to the fleet
    public mutating func apply(_ event: FleetEvent) -> FleetEventEffect {
        guard event.seq > lastSeq else {
            return .unchanged
        }
        lastSeq = event.seq
        switch (event.actor.kind, event.verb) {
        case (Self.agentKind, "started"):
            return .refetch(event.actor)
        case (Self.agentKind, "state"):
            guard
                let state = event.mapDetail["state"]?.stringValue.flatMap(AgentState.init(rawValue:)),
                mapAgents[event.actor.id] != nil
            else {
                return mapAgents[event.actor.id] == nil ? .refetch(event.actor) : .unchanged
            }
            mapAgents[event.actor.id]?.state = state
            mapAgents[event.actor.id]?.lastUsedAt = event.at
            return .changed
        case (Self.agentKind, "ended"):
            guard mapAgents[event.actor.id] != nil else {
                return .unchanged
            }
            mapAgents[event.actor.id]?.state = .ended
            return .changed
        case (Self.rookKind, "connected"), (Self.rookKind, "disconnected"):
            mapRooksOnline[event.actor.id] = event.verb == "connected"
            return .changed
        default:
            return .unchanged
        }
    }

    /// The sessions, without their subagents, those last active first.
    public var listSessions: [FleetAgent] {
        mapAgents.values
            .filter { $0.parentId == nil }
            .sorted { ($0.lastUsedAt, $0.id) > ($1.lastUsedAt, $1.id) }
    }

    /// A session's subagents, those last active first.
    public func listSubagents(of agentId: String) -> [FleetAgent] {
        mapAgents.values
            .filter { $0.parentId == agentId }
            .sorted { ($0.lastUsedAt, $0.id) > ($1.lastUsedAt, $1.id) }
    }

    /// Whether the rook an agent runs under holds its link open.
    public func isOnline(_ agent: FleetAgent) -> Bool {
        mapRooksOnline[agent.rookName] ?? false
    }
}

/// roost's timestamps: ISO 8601 in UTC, with milliseconds.
public enum FleetTimestamp {
    /// The moment a timestamp names, or nil when it is not one.
    public static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
