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

    /// A value as `JSONSerialization` reads it.
    ///
    /// - Parameter any: a string, number, boolean, array, dictionary or null from `JSONSerialization`
    public init(any: Any) {
        switch any {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let list as [Any]:
            self = .array(list.map(JSONValue.init(any:)))
        case let map as [String: Any]:
            self = .object(map.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The value as text, or nil when it is not a non-empty string.
    public var stringValue: String? {
        guard case .string(let value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The value as a number, or nil when it is not one.
    public var numberValue: Double? {
        guard case .number(let value) = self else {
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

    /// Whether the resource is one of Rookery's own agents, as Raven's conversations, which the fleet's
    /// lists leave out.
    public var isRookeryOwn: Bool {
        kind == AgentFleet.agentKind && mapAttributes["rook_name"]?.stringValue == AgentFleet.rookeryRookName
    }

    /// What the resource goes by: the title it was given, such as an agent's session title, else its name.
    public var displayName: String {
        guard let title = mapAttributes["title"]?.stringValue, !title.isEmpty else {
            return name
        }
        return title
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
    /// The name rook gives it: the machine's rook name and the tmux tab it runs in.
    public var name: String
    /// The session's title as the harness keeps it, which the user may have given it; empty when unknown.
    public var title: String
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
    /// Who it is to its teammates, as it, the user or Raven set it; empty when unset.
    public var role: String
    /// What it works on now, as it last said; empty when unset.
    public var focus: String
    /// Where the role came from: the user, the agent itself, its launch or Rookery; empty when unknown.
    public var roleSource: String

    public init(
        id: String,
        name: String,
        title: String = "",
        state: AgentState,
        harness: String = "",
        rookName: String = "",
        tab: String = "",
        cwd: String = "",
        gitBranch: String = "",
        model: String = "",
        hostname: String = "",
        parentId: String? = nil,
        lastUsedAt: String = "",
        role: String = "",
        focus: String = "",
        roleSource: String = ""
    ) {
        self.id = id
        self.name = name
        self.title = title
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
        self.role = role
        self.focus = focus
        self.roleSource = roleSource
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
            title: mapAttributes["title"]?.stringValue ?? "",
            state: isClosed ? .ended : AgentState(rawValue: mapAttributes["state"]?.stringValue ?? "") ?? .idle,
            harness: mapAttributes["harness"]?.stringValue ?? "",
            rookName: mapAttributes["rook_name"]?.stringValue ?? "",
            tab: mapAttributes["tab"]?.stringValue ?? "",
            cwd: mapAttributes["cwd"]?.stringValue ?? "",
            gitBranch: mapAttributes["git_branch"]?.stringValue ?? "",
            model: mapAttributes["model"]?.stringValue ?? "",
            hostname: mapAttributes["machine"]?["hostname"]?.stringValue ?? "",
            parentId: mapAttributes["parent"]?.stringValue,
            lastUsedAt: resource.lastUsedAt,
            role: mapAttributes["role"]?.stringValue ?? "",
            focus: mapAttributes["focus"]?.stringValue ?? "",
            roleSource: mapAttributes[AgentIdentity.roleSourceKey]?.stringValue ?? ""
        )
    }

    /// What the agent goes by: its session's title, else rook's name for it.
    public var displayName: String {
        title.isEmpty ? name : title
    }

    /// The session roost keeps this agent's transcript under: its own, or for a subagent, which rook names
    /// `<parent>~<agent>`, the `agent-<agent>` one the harness writes beside its parent's.
    public static func transcriptSessionId(of agentId: String) -> String {
        guard let separator = agentId.firstIndex(of: Self.subagentSeparator) else {
            return agentId
        }
        return Self.subagentSessionPrefix + agentId[agentId.index(after: separator)...]
    }

    private static let subagentSeparator: Character = "~"
    private static let subagentSessionPrefix = "agent-"

    /// The working directory's last component, which names the project.
    public var projectName: String {
        cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
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
    /// `prompt`, `interrupt`, `approve` or `spawn`; a roost older than kinds sends none, and every delivery
    /// was a prompt.
    public let kind: String
    /// The kind's options: a prompt's `thread`, `hop`, `team`, `no_reply` and `sender_title`, a spawn's
    /// launch.
    public let mapOptions: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case mapOptions = "options"
        case id
        case agentId = "agent_id"
        case text
        case sender
        case status
        case mapDetail = "detail"
        case createdAt = "created_at"
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        text = try container.decode(String.self, forKey: .text)
        sender = try container.decode(FleetRef.self, forKey: .sender)
        status = try container.decode(String.self, forKey: .status)
        mapDetail = try container.decodeIfPresent([String: JSONValue].self, forKey: .mapDetail) ?? [:]
        createdAt = try container.decode(String.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "prompt"
        mapOptions = try container.decodeIfPresent([String: JSONValue].self, forKey: .mapOptions) ?? [:]
    }

    /// Whether roost holds it for the user to release or cancel.
    public var isHeld: Bool {
        status == "held"
    }

    /// The outcomes a delivery ends in.
    public static let setSettledStatuses: Set<String> = ["delivered", "failed", "expired"]

    /// Why it waits or failed, or how it arrived.
    public var reason: String {
        mapDetail["reason"]?.stringValue ?? ""
    }

    /// Whether it reached its agent or never will.
    public var isSettled: Bool {
        Self.setSettledStatuses.contains(status)
    }

    /// Whether it never will.
    public var isFailed: Bool {
        isSettled && status != "delivered"
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
    public static let teamKind = "team"
    /// The rook Rookery's own agents report under, as Raven's conversations: the app's tooling, not agents
    /// of the fleet, so the fleet's lists leave them out.
    public static let rookeryRookName = "rookery"

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
        if event.verb == "deleted", let object = event.object, object.kind == Self.agentKind {
            guard mapAgents.removeValue(forKey: object.id) != nil else {
                return .unchanged
            }
            return .changed
        }
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
            if let title = event.mapDetail["title"]?.stringValue {
                mapAgents[event.actor.id]?.title = title
            }
            return .changed
        case (Self.agentKind, "renamed"):
            guard mapAgents[event.actor.id] != nil else {
                return .refetch(event.actor)
            }
            mapAgents[event.actor.id]?.title = event.mapDetail["title"]?.stringValue ?? ""
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
            .filter { $0.rookName != Self.rookeryRookName }
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
    private static let withFractionStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle()

    /// The moment a timestamp names, or nil when it is not one.
    public static func date(from text: String) -> Date? {
        (try? withFractionStyle.parse(text)) ?? (try? wholeSecondStyle.parse(text))
    }
}
