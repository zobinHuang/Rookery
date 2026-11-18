import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// How the app stands with roost.
enum FleetConnection: Equatable {
    /// No address or token is set.
    case notConfigured
    case connecting
    /// The fleet is current and follows the live link.
    case online
    /// The link is down; the fleet shows what it last knew, and a retry is coming.
    case offline(String)
}

/// The agents roost knows of, kept current over the live link, and how the user teamed them on this Mac.
/// One for the app, shared by every stage's sidebar and detail page.
@MainActor
@Observable
final class FleetModel {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    /// Where the app keeps roost's token: a file only the user may read, moved there once from the keychain,
    /// where it was kept before.
    static let tokenFile = FileSecret(
        url: DataDirectory.file(named: "roost-token"),
        formerStore: KeychainSecret(account: "roost-token")
    )
    private static let firstRetryDelay: Duration = .seconds(2)
    private static let longestRetryDelay: Duration = .seconds(60)
    /// How long the live link's events gather before they are applied together, so a burst, as a playbook
    /// loading reports every skill it mounts, redraws the console once rather than once an event.
    private static let eventBatchDelay: Duration = .milliseconds(250)

    private(set) var connection: FleetConnection = .notConfigured
    private(set) var fleet = AgentFleet()
    /// Every resource, relation and recent event, for the Rookmaster console.
    private(set) var graph = ResourceGraph()
    private(set) var teams: AgentTeams
    /// Why the last change to the teams failed, until the user dismisses it.
    var teamError: String?
    private(set) var serverVersion: String?

    @ObservationIgnored private let preferences: Preferences
    /// Raven, which works on what this model follows; it lives as long as the app.
    @ObservationIgnored private(set) lazy var raven = RavenAgent(fleetModel: self)
    /// The hosts this Mac reaches over ssh, their workdirs, and the agents launched on them.
    @ObservationIgnored private(set) lazy var hosts = HostsModel(fleetModel: self)
    /// The Mac's mail and calendars, as Raven's tools reach them.
    @ObservationIgnored lazy var mailService = MailService(drafts: mailDrafts)
    /// Where the stage's calendar and mail come from: the Mac's own, or sample data set before the stage is
    /// first drawn offscreen.
    @ObservationIgnored lazy var mailSource: any MailSource = mailService
    /// The user's day and unread mail, for the stage's right sidebar and pages.
    @ObservationIgnored private(set) lazy var personal = PersonalDataModel(service: mailSource)
    /// The transcripts read so far, so an agent's page reopens at once.
    @ObservationIgnored let transcripts = TranscriptCache()
    /// Where the user left the agents' pages and the Rookmaster console.
    @ObservationIgnored let pageMemory = PageMemory()
    @ObservationIgnored let pageColumns = PageColumns()
    /// The people the user set down, whom Raven is told of and the mail and the calendars show.
    @ObservationIgnored let people = PeopleStore()
    /// The mails being written in Rookery, Raven's drafts among them.
    @ObservationIgnored let mailDrafts = MailDraftStore()
    /// What Raven reaches on the board, drawn as lines from its tab.
    @ObservationIgnored let ravenLinks = RavenLinks()
    @ObservationIgnored private let tokenStore: any SecretStore
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The live link's events not yet applied, and the task that applies them once they have gathered.
    @ObservationIgnored private var listPendingEvents: [FleetEvent] = []
    @ObservationIgnored private var eventBatchTask: Task<Void, Never>?
    private var cachedToken: String??

    init(preferences: Preferences, tokenStore: any SecretStore = FleetModel.tokenFile) {
        self.preferences = preferences
        self.tokenStore = tokenStore
        teams = Self.loadTeams()
    }

    /// Follow roost, if one is set.
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

    /// The code agent a new conversation with Raven runs on.
    var ravenEngine: String {
        get { preferences.ravenEngine }
        set { preferences.ravenEngine = newValue }
    }

    /// The address of the roost set, as the user typed it.
    var roostAddress: String {
        preferences.roostAddress
    }

    /// The token kept for roost, or empty until it is read. It is read off the main thread when the model
    /// starts: the first read after the app is signed anew waits on the keychain's prompt to allow it, which
    /// froze the app on the main thread.
    var token: String {
        (cachedToken ?? nil) ?? ""
    }

    /// Read the token kept for roost, once, on a background thread.
    private func loadTokenIfNeeded() async {
        guard cachedToken == nil else {
            return
        }
        let store = tokenStore
        do {
            let token = try await Task.detached(priority: .userInitiated) {
                try store.read()
            }.value
            cachedToken = .some(token)
        } catch {
            Self.logger.error("cannot read roost's token: \(error, privacy: .public)")
            cachedToken = nil
        }
    }

    /// Follow another roost, or the same one with another token.
    ///
    /// - Throws: `KeychainError` when the token cannot be kept
    func connect(address: String, token: String) throws {
        try tokenStore.write(token)
        cachedToken = .some(token)
        preferences.roostAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        fleet = AgentFleet()
        start()
    }

    /// Try an address and token without keeping them.
    ///
    /// - Returns: what roost said, for the settings to show
    func test(address: String, token: String) async -> String {
        do {
            let client = RoostClient(endpoint: try RoostEndpoint(address: address, token: token))
            let health = try await client.health()
            let listAgents = try await client.resources(kind: AgentFleet.agentKind)
            let linkNote = health.linkPort.map { "live link on port \($0)" } ?? "no live link (upgrade roost)"
            return "roost \(health.version), \(listAgents.count) agents, \(linkNote)"
        } catch {
            return Self.describe(error)
        }
    }

    /// The client for the roost set, or nil when none is.
    /// The people and the resources an `@` being typed in a text could name, for a request to Raven;
    /// empty when no `@` is being typed.
    func mentionTargets(in text: String) -> [MentionTarget] {
        guard let query = Mentions.activeQuery(in: text) else {
            return []
        }
        let listResources = graph.listKinds
            .filter { !RookmasterView.setHiddenKinds.contains($0.name) }
            .flatMap { graph.listResources(of: $0.name) }
        return MentionTarget.suggestions(for: query, people: people.book, resources: listResources)
    }

    func client() -> RoostClient? {
        guard
            !preferences.roostAddress.isEmpty,
            !token.isEmpty,
            let endpoint = try? RoostEndpoint(address: preferences.roostAddress, token: token)
        else {
            return nil
        }
        return RoostClient(endpoint: endpoint)
    }

    /// Send an agent a prompt from the user.
    ///
    /// - Throws: `RoostError`, or when no roost is set
    func send(_ text: String, to agentId: String) async throws -> FleetDelivery {
        guard let client = client() else {
            throw RoostError.invalidAddress(preferences.roostAddress)
        }
        return try await client.send(text, to: agentId)
    }

    /// An error as one line for the user.
    static func describe(_ error: any Error) -> String {
        return switch error {
        case let error as RoostError: error.description
        case let error as KeychainError: error.description
        default: error.localizedDescription
        }
    }

    /// Add a resource as the user.
    ///
    /// - Throws: `RoostError`
    @discardableResult
    func create(_ kind: String, body mapBody: [String: JSONValue]) async throws -> FleetResource {
        let resource = try await requireClient().create(kind, body: mapBody)
        graph.put(resource)
        fleet.put(resource)
        return resource
    }

    /// Change a resource as the user.
    ///
    /// - Throws: `RoostError`
    func update(_ ref: FleetRef, body mapBody: [String: JSONValue]) async throws {
        let resource = try await requireClient().update(ref, body: mapBody)
        graph.put(resource)
        fleet.put(resource)
    }

    /// Resolve a skill's tracked ref again.
    ///
    /// - Throws: `RoostError`
    func refreshSkill(_ skillId: String) async throws {
        let client = try requireClient()
        try await client.refreshSkill(skillId)
        graph.put(try await client.resource(FleetRef(kind: "skill", id: skillId)))
    }

    /// The client of the roost followed now.
    ///
    /// - Throws: `RoostError.invalidAddress` when no roost is set up
    func requireClient() throws -> RoostClient {
        guard let client = client() else {
            throw RoostError.invalidAddress(preferences.roostAddress)
        }
        return client
    }

    /// Remove a resource as the user.
    ///
    /// - Throws: `RoostError`
    func delete(_ ref: FleetRef) async throws {
        guard let client = client() else {
            throw RoostError.invalidAddress(preferences.roostAddress)
        }
        try await client.delete(ref)
    }

    // MARK: - Teams

    /// Make a team on roost, with an agent in it if one is given.
    func addTeam(title: String, with agentId: String? = nil) {
        let teamId = teams.addTeam(title: title)
        if let agentId {
            teams.join(agentId, to: teamId)
        }
        saveTeams()
        writeTeams("make team \(title)") { client in
            _ = try await client.create(AgentFleet.teamKind, body: ["id": .string(teamId), "name": .string(title)])
            if let agentId {
                try await client.join(agentId, team: teamId, duty: "")
            }
        }
    }

    func renameTeam(_ teamId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        teams.rename(teamId, to: trimmed)
        saveTeams()
        writeTeams("rename team \(teamId)") { client in
            _ = try await client.update(FleetRef(kind: AgentFleet.teamKind, id: teamId), body: ["name": .string(trimmed)])
        }
    }

    func removeTeam(_ teamId: String) {
        teams.removeTeam(teamId)
        saveTeams()
        writeTeams("remove team \(teamId)") { client in
            try await client.delete(FleetRef(kind: AgentFleet.teamKind, id: teamId))
        }
    }

    func toggleTeam(_ teamId: String) {
        teams.toggleCollapsed(teamId)
        saveTeams()
    }

    /// Put an agent in a team, before another of its agents, keeping it in its other teams; one already in
    /// the team only moves within it.
    func join(_ agentId: String, to teamId: String, before beforeAgentId: String? = nil) {
        let isMember = teams.teamIds(of: agentId).contains(teamId)
        teams.join(agentId, to: teamId, before: beforeAgentId)
        saveTeams()
        guard !isMember else {
            return
        }
        writeTeams("put \(agentId) in team \(teamId)") { client in
            try await client.join(agentId, team: teamId, duty: "")
        }
    }

    func leave(_ agentId: String, from teamId: String) {
        teams.leave(agentId, from: teamId)
        saveTeams()
        writeTeams("take \(agentId) out of team \(teamId)") { client in
            try await client.leave(agentId, team: teamId)
        }
    }

    /// Move an agent from one team into another.
    func move(_ agentId: String, from sourceTeamId: String, to teamId: String, before beforeAgentId: String? = nil) {
        join(agentId, to: teamId, before: beforeAgentId)
        if sourceTeamId != teamId {
            leave(agentId, from: sourceTeamId)
        }
    }

    /// Read a team from roost again at once, as after a change made outside the sidebar.
    func refreshTeam(_ teamId: String) async {
        guard let client = client() else {
            return
        }
        await refetch(FleetRef(kind: AgentFleet.teamKind, id: teamId), from: client)
        syncTeams()
    }

    /// Give a member a duty in its team.
    func assignDuty(_ duty: String, to agentId: String, in teamId: String) {
        writeTeams("give \(agentId) a duty in team \(teamId)") { client in
            try await client.join(agentId, team: teamId, duty: duty.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func moveTeam(_ teamId: String, before beforeTeamId: String?) {
        teams.moveTeam(teamId, before: beforeTeamId)
        saveTeams()
    }

    /// The messages roost holds for the user and the user has not decided on, as the recent events tell.
    var listHeldEvents: [FleetEvent] {
        let listEvents = graph.listRecentEvents
        let setDecided = Set(listEvents.compactMap { event -> String? in
            let isDecided = event.mapDetail["released"]?.boolValue == true
                || event.verb == "undelivered"
                || event.verb == "delivered"
            return isDecided ? event.mapDetail["delivery"]?.stringValue : nil
        })
        return listEvents.filter { event in
            event.verb == "messaged"
                && event.mapDetail["held"] != nil
                && !setDecided.contains(event.mapDetail["delivery"]?.stringValue ?? "")
        }
    }

    /// How many held messages went through a team: sent to it, or between two of its members.
    func heldCount(in teamId: String) -> Int {
        guard let team = graph.resource(FleetRef(kind: AgentFleet.teamKind, id: teamId)) else {
            return 0
        }
        let setMembers = Set(AgentTeams.memberIds(of: team))
        return listHeldEvents.filter { event in
            event.mapDetail["team"]?.stringValue == teamId
                || (setMembers.contains(event.actor.id) && setMembers.contains(event.object?.id ?? ""))
        }.count
    }

    /// The teams roost holds, by name.
    var listTeamResources: [FleetResource] {
        graph.listResources(of: AgentFleet.teamKind).sorted { $0.displayName < $1.displayName }
    }

    /// Change the teams on roost; the sidebar shows the change at once, and takes roost's teams back in
    /// when roost refused it.
    private func writeTeams(_ what: String, _ change: @escaping @MainActor (RoostClient) async throws -> Void) {
        Task {
            do {
                try await change(requireClient())
            } catch {
                Self.logger.error("cannot \(what, privacy: .public): \(Self.describe(error), privacy: .public)")
                teamError = "Could not \(what): \(Self.describe(error))"
                syncTeams()
            }
        }
    }

    /// Take roost's teams into the sidebar's layout.
    private func syncTeams() {
        teams.adopt(graph.listResources(of: AgentFleet.teamKind))
        saveTeams()
    }

    /// Carry the teams made on this Mac before roost held teams over to roost, once.
    private func carryTeamsToRoost(_ client: RoostClient) async {
        guard !teams.isOnRoost else {
            return
        }
        let setOnRoost = Set(graph.listResources(of: AgentFleet.teamKind).map(\.id))
        for team in teams.listTeams where !setOnRoost.contains(team.id) {
            do {
                graph.put(try await client.create(AgentFleet.teamKind, body: ["id": .string(team.id), "name": .string(team.title)]))
                for agentId in team.listAgentIds {
                    guard let agent = graph.resource(FleetRef(kind: AgentFleet.agentKind, id: agentId)), !agent.isRookeryOwn else {
                        continue
                    }
                    try await client.join(agentId, team: team.id, duty: "")
                }
                graph.put(try await client.resource(FleetRef(kind: AgentFleet.teamKind, id: team.id)))
            } catch {
                Self.logger.error("cannot carry team \(team.title, privacy: .public) to roost: \(Self.describe(error), privacy: .public)")
                return
            }
        }
        teams.noteOnRoost()
        syncTeams()
    }

    // MARK: - Following roost

    private func run() async {
        await loadTokenIfNeeded()
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
                Self.logger.info("roost link down: \(Self.describe(error), privacy: .public)")
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
    private func follow(_ client: RoostClient) async throws {
        eventBatchTask?.cancel()
        eventBatchTask = nil
        listPendingEvents = []
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
        await carryTeamsToRoost(client)
        syncTeams()
        connection = .online
        for try await event in client.events(after: lastSeq) {
            listPendingEvents.append(event)
            if eventBatchTask == nil {
                eventBatchTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.eventBatchDelay)
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.applyPendingEvents(from: client)
                }
            }
        }
        throw RoostError.unreachable("the live link closed")
    }

    /// Apply the events gathered since the last batch in one go, then fetch again at once every resource
    /// they leave only roost able to tell, so the views redraw once for the batch.
    private func applyPendingEvents(from client: RoostClient) async {
        eventBatchTask = nil
        let listEvents = listPendingEvents
        listPendingEvents = []
        var nextGraph = graph
        var nextFleet = fleet
        var setRefetch: Set<FleetRef> = []
        var isTeamChanged = false
        for event in listEvents {
            setRefetch.formUnion(nextGraph.apply(event))
            ravenLinks.take(event, graph: nextGraph)
            if case .refetch(let ref) = nextFleet.apply(event) {
                setRefetch.insert(ref)
            }
            isTeamChanged = isTeamChanged || event.object?.kind == AgentFleet.teamKind
        }
        graph = nextGraph
        fleet = nextFleet
        if isTeamChanged {
            syncTeams()
        }
        guard !setRefetch.isEmpty else {
            return
        }
        let listFetched = await Self.fetch(setRefetch, from: client)
        guard !Task.isCancelled else {
            return
        }
        var fetchedGraph = graph
        var fetchedFleet = fleet
        for resource in listFetched {
            fetchedFleet.put(resource)
            fetchedGraph.put(resource)
        }
        graph = fetchedGraph
        fleet = fetchedFleet
        if listFetched.contains(where: { $0.kind == AgentFleet.teamKind }) {
            syncTeams()
        }
    }

    /// Read resources from roost one after another; one gone or unreadable is left out.
    private static func fetch(_ setRefs: Set<FleetRef>, from client: RoostClient) async -> [FleetResource] {
        var listFetched: [FleetResource] = []
        for ref in setRefs {
            do {
                listFetched.append(try await client.resource(ref))
            } catch RoostError.rejected(status: 404, _) {
                continue
            } catch {
                logger.error("cannot read \(ref.kind) \(ref.id): \(describe(error), privacy: .public)")
            }
        }
        return listFetched
    }

    /// Read one resource from roost again and put it in place.
    private func refetch(_ ref: FleetRef, from client: RoostClient) async {
        for resource in await Self.fetch([ref], from: client) {
            fleet.put(resource)
            graph.put(resource)
        }
    }

    private static func loadTeams() -> AgentTeams {
        var url = DataDirectory.file(named: AgentTeams.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            url = DataDirectory.file(named: AgentTeams.legacyFileName)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentTeams()
        }
        do {
            return try JSONDecoder().decode(AgentTeams.self, from: Data(contentsOf: url))
        } catch {
            logger.error("cannot read the agent teams: \(error, privacy: .public)")
            return AgentTeams()
        }
    }

    private func saveTeams() {
        do {
            try FileManager.default.createDirectory(at: DataDirectory.url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(teams).write(to: DataDirectory.file(named: AgentTeams.fileName), options: .atomic)
        } catch {
            Self.logger.error("cannot save the agent teams: \(error, privacy: .public)")
        }
    }
}
