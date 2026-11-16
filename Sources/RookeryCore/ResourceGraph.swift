import Foundation

/// A kind of resource roost manages, as `GET /v1/kinds` lists it.
public struct FleetKind: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let title: String
    public let pluralTitle: String
    public let description: String

    public var id: String {
        name
    }

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case pluralTitle = "plural_title"
        case description
    }

    public init(name: String, title: String, pluralTitle: String, description: String = "") {
        self.name = name
        self.title = title
        self.pluralTitle = pluralTitle
        self.description = description
    }
}

/// A directed edge between two resources: one acted on the other, this often, first and last then.
public struct FleetRelation: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public let source: FleetRef
    public let verb: String
    public let target: FleetRef
    public var firstAt: String
    public var lastAt: String
    public var count: Int

    public var id: String {
        "\(source.kind)/\(source.id) \(verb) \(target.kind)/\(target.id)"
    }

    enum CodingKeys: String, CodingKey {
        case source
        case verb
        case target
        case firstAt = "first_at"
        case lastAt = "last_at"
        case count
    }

    public init(source: FleetRef, verb: String, target: FleetRef, firstAt: String, lastAt: String, count: Int) {
        self.source = source
        self.verb = verb
        self.target = target
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.count = count
    }
}

/// Every resource roost manages, the relations between them and the latest events, kept current by
/// applying the event log in order, as the Rookmaster console shows them.
public struct ResourceGraph: Equatable, Sendable {
    /// How many of the latest events the log keeps.
    public static let recentEventLimit = 100
    /// The verbs that draw a relation from their actor to their object, as roost applies them.
    public static let setRelationVerbs: Set<String> = [
        "created", "updated", "uses", "mounts", "follows", "spawned", "wrote", "depends_on", "messaged",
    ]
    private static let personKind = "person"

    public private(set) var listKinds: [FleetKind] = []
    /// Each kind's resources by id.
    public private(set) var mapResources: [String: [String: FleetResource]] = [:]
    public private(set) var mapRelations: [String: FleetRelation] = [:]
    /// The latest events, oldest first.
    public private(set) var listRecentEvents: [FleetEvent] = []
    public private(set) var lastSeq = 0

    public init() {}

    /// Replace everything with a fresh read of roost.
    public mutating func load(
        kinds listKinds: [FleetKind],
        resources listResources: [FleetResource],
        relations listRelations: [FleetRelation],
        recentEvents listEvents: [FleetEvent],
        lastSeq: Int
    ) {
        self.listKinds = listKinds
        mapResources = [:]
        for resource in listResources {
            put(resource)
        }
        mapRelations = Dictionary(listRelations.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        listRecentEvents = Array(listEvents.suffix(Self.recentEventLimit))
        self.lastSeq = lastSeq
    }

    /// Take in one resource as roost serves it now.
    public mutating func put(_ resource: FleetResource) {
        mapResources[resource.kind, default: [:]][resource.id] = resource
    }

    /// A resource, or nil when it is not known.
    public func resource(_ ref: FleetRef) -> FleetResource? {
        mapResources[ref.kind]?[ref.id]
    }

    /// A resource's name, or its id when it is not known; "you" for a person.
    public func name(of ref: FleetRef) -> String {
        if ref.kind == Self.personKind {
            return "you"
        }
        guard let resource = resource(ref) else {
            if ref.kind == AgentFleet.agentKind, let separator = ref.id.firstIndex(of: "~") {
                let parent = FleetRef(kind: ref.kind, id: String(ref.id[..<separator]))
                return "\(name(of: parent)) › subagent"
            }
            return ref.id
        }
        return resource.displayName
    }

    /// A kind's resources, those last used first.
    public func listResources(of kind: String) -> [FleetResource] {
        (mapResources[kind] ?? [:]).values.sorted { ($0.lastUsedAt, $0.id) > ($1.lastUsedAt, $1.id) }
    }

    /// Apply one event, unless it was applied already.
    ///
    /// - Parameter event: the next event from roost
    /// - Returns: the resources only roost's copy of can tell what changed, to fetch again
    public mutating func apply(_ event: FleetEvent) -> [FleetRef] {
        guard event.seq > lastSeq else {
            return []
        }
        lastSeq = event.seq
        listRecentEvents.append(event)
        if listRecentEvents.count > Self.recentEventLimit {
            listRecentEvents.removeFirst(listRecentEvents.count - Self.recentEventLimit)
        }
        var listRefetch: [FleetRef] = []
        if event.actor.kind != Self.personKind {
            if resource(event.actor) == nil || event.verb == "started" || event.actor.kind == "rook" {
                listRefetch.append(event.actor)
            } else {
                touch(event.actor, at: event.at)
                if event.verb == "state", let state = event.mapDetail["state"] {
                    setAttribute("state", to: state, of: event.actor)
                    if let title = event.mapDetail["title"], title.stringValue != nil {
                        setAttribute("title", to: title, of: event.actor)
                    }
                } else if event.verb == "renamed", let title = event.mapDetail["title"] {
                    setAttribute("title", to: title, of: event.actor)
                } else if event.verb == "ended" {
                    setAttribute("closed_at", to: .string(event.at), of: event.actor)
                }
            }
        }
        guard let object = event.object else {
            return listRefetch
        }
        if event.verb == "deleted" {
            remove(object)
            return listRefetch
        }
        if
            Self.setRelationVerbs.contains(event.verb),
            event.actor.kind != Self.personKind
        {
            relate(event.actor, event.verb, object, at: event.at)
        }
        if resource(object) == nil || event.verb == "created" || event.verb == "updated" || event.verb == "wrote" {
            listRefetch.append(object)
        } else {
            touch(object, at: event.at)
        }
        return listRefetch
    }

    /// The relations touching a resource, either way.
    public func listRelations(touching ref: FleetRef) -> [FleetRelation] {
        mapRelations.values.filter { $0.source == ref || $0.target == ref }
    }

    private mutating func relate(_ source: FleetRef, _ verb: String, _ target: FleetRef, at: String) {
        let relation = FleetRelation(source: source, verb: verb, target: target, firstAt: at, lastAt: at, count: 1)
        if var known = mapRelations[relation.id] {
            known.lastAt = at
            known.count += 1
            mapRelations[relation.id] = known
        } else {
            mapRelations[relation.id] = relation
        }
    }

    private mutating func remove(_ ref: FleetRef) {
        mapResources[ref.kind]?[ref.id] = nil
        mapRelations = mapRelations.filter { $0.value.source != ref && $0.value.target != ref }
    }

    private mutating func touch(_ ref: FleetRef, at: String) {
        guard let resource = resource(ref), at > resource.lastUsedAt else {
            return
        }
        put(FleetResource(
            kind: resource.kind,
            id: resource.id,
            name: resource.name,
            mapAttributes: resource.mapAttributes,
            lastUsedAt: at
        ))
    }

    private mutating func setAttribute(_ key: String, to value: JSONValue, of ref: FleetRef) {
        guard let resource = resource(ref) else {
            return
        }
        var mapAttributes = resource.mapAttributes
        mapAttributes[key] = value
        put(FleetResource(
            kind: resource.kind,
            id: resource.id,
            name: resource.name,
            mapAttributes: mapAttributes,
            lastUsedAt: resource.lastUsedAt
        ))
    }
}
