import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// How the app stands with rookd.
enum FleetConnection: Equatable {
    /// No address or token is set.
    case notConfigured
    case connecting
    /// The fleet is current and follows the live link.
    case online
    /// The link is down; the fleet shows what it last knew, and a retry is coming.
    case offline(String)
}

/// The agents rookd knows of, kept current over the live link, and how the user grouped them on this Mac.
/// One for the app, shared by every stage's sidebar and detail page.
@MainActor
@Observable
final class FleetModel {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    /// Where the app keeps rookd's token.
    static let keychainToken = KeychainSecret(account: "rookd-token")
    private static let firstRetryDelay: Duration = .seconds(2)
    private static let longestRetryDelay: Duration = .seconds(60)

    private(set) var connection: FleetConnection = .notConfigured
    private(set) var fleet = AgentFleet()
    /// Every resource, relation and recent event, for the Rookmaster console.
    private(set) var graph = ResourceGraph()
    private(set) var groups: AgentGroups
    private(set) var serverVersion: String?

    @ObservationIgnored private let preferences: Preferences
    /// The maintenance agent, which works on what this model follows; it lives as long as the app.
    @ObservationIgnored private(set) lazy var maintenance = MaintenanceAgent(fleetModel: self)
    @ObservationIgnored private let tokenStore: any SecretStore
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var cachedToken: String??

    init(preferences: Preferences, tokenStore: any SecretStore = FleetModel.keychainToken) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        groups = Self.loadGroups()
    }

    /// Follow rookd, if one is set.
    func start() {
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    /// The token kept for rookd, or empty.
    var token: String {
        if let cachedToken {
            return cachedToken ?? ""
        }
        do {
            let token = try tokenStore.read()
            cachedToken = .some(token)
            return token ?? ""
        } catch {
            Self.logger.error("cannot read rookd's token: \(error, privacy: .public)")
            return ""
        }
    }

    /// Follow another rookd, or the same one with another token.
    ///
    /// - Throws: `KeychainError` when the token cannot be kept
    func connect(address: String, token: String) throws {
        try tokenStore.write(token)
        cachedToken = .some(token)
        preferences.rookdAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        fleet = AgentFleet()
        start()
    }

    /// Try an address and token without keeping them.
    ///
    /// - Returns: what rookd said, for the settings to show
    func test(address: String, token: String) async -> String {
        do {
            let client = RookdClient(endpoint: try RookdEndpoint(address: address, token: token))
            let health = try await client.health()
            let listAgents = try await client.resources(kind: AgentFleet.agentKind)
            let linkNote = health.linkPort.map { "live link on port \($0)" } ?? "no live link (upgrade rookd)"
            return "rookd \(health.version), \(listAgents.count) agents, \(linkNote)"
        } catch {
            return Self.describe(error)
        }
    }

    /// The client for the rookd set, or nil when none is.
    func client() -> RookdClient? {
        guard
            !preferences.rookdAddress.isEmpty,
            !token.isEmpty,
            let endpoint = try? RookdEndpoint(address: preferences.rookdAddress, token: token)
        else {
            return nil
        }
        return RookdClient(endpoint: endpoint)
    }

    /// Send an agent a prompt from the user.
    ///
    /// - Throws: `RookdError`, or when no rookd is set
    func send(_ text: String, to agentId: String) async throws -> FleetDelivery {
        guard let client = client() else {
            throw RookdError.invalidAddress(preferences.rookdAddress)
        }
        return try await client.send(text, to: agentId)
    }

    /// An error as one line for the user.
    static func describe(_ error: any Error) -> String {
        return switch error {
        case let error as RookdError: error.description
        case let error as KeychainError: error.description
        default: error.localizedDescription
        }
    }

    /// Change a resource as the user.
    ///
    /// - Throws: `RookdError`
    func update(_ ref: FleetRef, name: String?, attributes mapAttributes: [String: JSONValue]) async throws {
        guard let client = client() else {
            throw RookdError.invalidAddress(preferences.rookdAddress)
        }
        let resource = try await client.update(ref, name: name, attributes: mapAttributes)
        graph.put(resource)
        fleet.put(resource)
    }

    /// Remove a resource as the user.
    ///
    /// - Throws: `RookdError`
    func delete(_ ref: FleetRef) async throws {
        guard let client = client() else {
            throw RookdError.invalidAddress(preferences.rookdAddress)
        }
        try await client.delete(ref)
    }

    // MARK: - Groups

    func addGroup(title: String, with agentId: String? = nil) {
        let groupId = groups.addGroup(title: title)
        if let agentId {
            groups.move(agentId, to: groupId)
        }
        saveGroups()
    }

    func renameGroup(_ groupId: String, to title: String) {
        groups.rename(groupId, to: title)
        saveGroups()
    }

    func removeGroup(_ groupId: String) {
        groups.removeGroup(groupId)
        saveGroups()
    }

    func toggleGroup(_ groupId: String) {
        groups.toggleCollapsed(groupId)
        saveGroups()
    }

    func move(_ agentId: String, to groupId: String?, before beforeAgentId: String? = nil) {
        groups.move(agentId, to: groupId, before: beforeAgentId)
        saveGroups()
    }

    func moveGroup(_ groupId: String, before beforeGroupId: String?) {
        groups.moveGroup(groupId, before: beforeGroupId)
        saveGroups()
    }

    // MARK: - Following rookd

    private func run() async {
        var retryDelay = Self.firstRetryDelay
        while !Task.isCancelled {
            guard let client = client() else {
                connection = .notConfigured
                return
            }
            if connection != .online {
                connection = .connecting
            }
            do {
                try await follow(client)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                connection = .offline(Self.describe(error))
                Self.logger.info("rookd link down: \(Self.describe(error), privacy: .public)")
            }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
            retryDelay = min(retryDelay * 2, Self.longestRetryDelay)
            if connection == .online {
                retryDelay = Self.firstRetryDelay
            }
        }
    }

    /// Read the fleet afresh, then apply the live link's events until it drops.
    private func follow(_ client: RookdClient) async throws {
        let health = try await client.health()
        serverVersion = health.version
        let listRecentEvents = try await client.latestEvents(limit: ResourceGraph.recentEventLimit)
        let lastSeq = listRecentEvents.last?.seq ?? 0
        let listKinds = try await client.kinds()
        var listResources: [FleetResource] = []
        for kind in listKinds {
            listResources += try await client.resources(kind: kind.name)
        }
        let listRelations = try await client.relations()
        fleet.load(listResources, lastSeq: lastSeq)
        graph.load(
            kinds: listKinds,
            resources: listResources,
            relations: listRelations,
            recentEvents: listRecentEvents,
            lastSeq: lastSeq
        )
        groups.prune(keeping: Set(fleet.mapAgents.keys))
        saveGroups()
        connection = .online
        for try await event in client.events(after: lastSeq) {
            var setRefetch = Set(graph.apply(event))
            if case .refetch(let ref) = fleet.apply(event) {
                setRefetch.insert(ref)
            }
            for ref in setRefetch {
                await refetch(ref, from: client)
            }
        }
        throw RookdError.unreachable("the live link closed")
    }

    private func refetch(_ ref: FleetRef, from client: RookdClient) async {
        do {
            let resource = try await client.resource(ref)
            fleet.put(resource)
            graph.put(resource)
        } catch RookdError.rejected(status: 404, _) {
            return
        } catch {
            Self.logger.error("cannot read \(ref.kind) \(ref.id): \(Self.describe(error), privacy: .public)")
        }
    }

    private static func loadGroups() -> AgentGroups {
        let url = DataDirectory.file(named: AgentGroups.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentGroups()
        }
        do {
            return try JSONDecoder().decode(AgentGroups.self, from: Data(contentsOf: url))
        } catch {
            logger.error("cannot read the agent groups: \(error, privacy: .public)")
            return AgentGroups()
        }
    }

    private func saveGroups() {
        do {
            try FileManager.default.createDirectory(at: DataDirectory.url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(groups).write(to: DataDirectory.file(named: AgentGroups.fileName), options: .atomic)
        } catch {
            Self.logger.error("cannot save the agent groups: \(error, privacy: .public)")
        }
    }
}
