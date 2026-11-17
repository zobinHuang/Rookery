import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// How the latest request in a conversation went.
enum RavenTurnStatus: Equatable {
    case running
    case finished(costUSD: Double?)
    case failed(String)
    case cancelled
}

/// Raven, Rookery's agent over the fleet: Claude Code run headless on this Mac, in a workspace of the app's
/// own that holds Rookery's skills and a `rook-client` connected to the roost the app follows, allowed that
/// command and its skills and nothing else. Each conversation is one Claude Code session, continued with
/// `--resume` for each request after its first, reported to roost as the agent `rookery/raven` with the
/// session's id, so whatever it changes is logged as its doing. Conversations and what was said in them
/// are kept in the data directory, so they outlive the app.
@MainActor
@Observable
final class RavenAgent {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "raven")
    static let agentName = "rookery/raven"
    static let rookName = AgentFleet.rookeryRookName
    private static let workspaceName = "raven"
    private static let historyName = "raven-history"
    private static let indexName = "conversations.json"
    private static let resourceFolder = "Raven"
    /// The name Raven's MCP config gives `rookery-mail`, which its tools are named under.
    static let mailServerName = "mail"
    private static let mailServerExecutable = "rookery-mail"
    private static let mcpConfigName = "mcp.json"
    private static let fileMode: Int = 0o600
    private static let executableMode: Int = 0o755
    /// It reads and changes roost's resources and reads the agents, the teams and the user's hosts through
    /// rook-client, and only proposes what it would do to an agent or a team, which the user carries out; it
    /// reads skills' own pages to describe them.
    private static let listAllowedTools = [
        "Bash(rook-client resource:*)",
        "Bash(rook-client agent:*)",
        "Bash(rook-client propose:*)",
        "Bash(rook-client host:*)",
        "Bash(rook-client team list:*)",
        "Bash(rook-client team roster:*)",
        "mcp__\(mailServerName)",
        "Skill",
        "WebFetch",
    ]

    private(set) var conversations = RavenConversations()
    /// What was said in each conversation opened since launch, as read from its history.
    private(set) var mapReaders: [String: TranscriptReader] = [:]
    /// How the latest request of each conversation went, since launch.
    private(set) var mapStatuses: [String: RavenTurnStatus] = [:]
    /// The conversation the panel shows; nil for a new one, not begun yet.
    var openConversationId: String?
    /// What Raven proposed in each conversation read since launch, oldest first.
    private(set) var mapProposals: [String: [RavenProposal]] = [:]
    /// The latest state of each delivery the user's decisions sent, by its id.
    private(set) var mapDeliveries: [String: FleetDelivery] = [:]
    /// Why carrying out a proposal failed, by the proposal's id.
    private(set) var mapProposalErrors: [String: String] = [:]
    /// What carrying out each proposal on mail or calendars did, in a line, by the proposal's id.
    private(set) var mapProposalOutcomes: [String: String] = [:]

    @ObservationIgnored private unowned let fleetModel: FleetModel
    @ObservationIgnored private var mapTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isIndexLoaded = false
    /// The program run in place of Claude Code, for checks that must not call a model.
    @ObservationIgnored var executableOverride: URL?
    /// Where the workspace and the history are laid out in place of the app's data directory, for the same
    /// checks.
    @ObservationIgnored var workspaceOverride: URL?

    init(fleetModel: FleetModel) {
        self.fleetModel = fleetModel
    }

    /// Whether a request in a conversation is under way.
    func isRunning(_ conversationId: String?) -> Bool {
        conversationId.map { mapStatuses[$0] == .running } ?? false
    }

    /// Whether any conversation has a request under way.
    var isAnyRunning: Bool {
        mapStatuses.values.contains(.running)
    }

    /// Read the conversations kept from earlier launches, once.
    func loadIfNeeded() {
        guard !isIndexLoaded else {
            return
        }
        isIndexLoaded = true
        do {
            let data = try Data(contentsOf: historyDirectory.appending(path: Self.indexName))
            conversations = try JSONDecoder().decode(RavenConversations.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            conversations = RavenConversations()
        } catch {
            Self.logger.error("cannot read Raven's conversations: \(error, privacy: .public)")
        }
    }

    /// What was said in a conversation, read from its history the first time it is asked for.
    func reader(of conversationId: String) -> TranscriptReader {
        if let reader = mapReaders[conversationId] {
            return reader
        }
        var reader = TranscriptReader()
        if let data = try? Data(contentsOf: historyFile(of: conversationId)) {
            reader.append(data)
            mapProposals[conversationId] = data
                .split(separator: UInt8(ascii: "\n"))
                .flatMap { RavenProposal.proposals(in: Data($0)) }
        }
        mapReaders[conversationId] = reader
        return reader
    }

    /// Ask Raven something, in an open conversation or in a new one.
    ///
    /// - Parameters:
    ///   - request: what the user asked, as typed
    ///   - listMentions: the resources it names with @
    ///   - conversationId: the conversation to continue, or nil to begin one
    /// - Returns: the conversation the request went to
    @discardableResult
    func ask(_ request: String, mentioning listMentions: [FleetRef], in conversationId: String?) -> String? {
        loadIfNeeded()
        guard let client = fleetModel.client(), !isRunning(conversationId) else {
            return nil
        }
        let now = Date()
        let sessionId: String
        let isFirstTurn: Bool
        if let conversationId, conversations.conversation(conversationId) != nil {
            sessionId = conversationId
            isFirstTurn = false
            conversations.noteTurn(in: sessionId, at: now)
        } else {
            sessionId = UUID().uuidString.lowercased()
            isFirstTurn = true
            conversations.open(sessionId, with: request, at: now)
        }
        saveIndex()
        openConversationId = sessionId
        record(Self.requestLine(request, at: now), in: sessionId)
        mapStatuses[sessionId] = .running
        let prompt = Self.prompt(
            request,
            listMentions: listMentions,
            graph: fleetModel.graph,
            agentId: sessionId,
            listDecisions: decisionLines(in: sessionId)
        )
        mapTasks[sessionId] = Task { [weak self] in
            await self?.perform(prompt: prompt, sessionId: sessionId, isFirstTurn: isFirstTurn, client: client)
        }
        return sessionId
    }

    /// Stop the request under way in a conversation.
    func cancel(_ conversationId: String) {
        mapTasks[conversationId]?.cancel()
    }

    /// Forget a conversation and what was said in it; roost keeps its agent and what it changed.
    func remove(_ conversationId: String) {
        cancel(conversationId)
        conversations.remove(conversationId)
        mapReaders[conversationId] = nil
        mapStatuses[conversationId] = nil
        try? FileManager.default.removeItem(at: historyFile(of: conversationId))
        if openConversationId == conversationId {
            openConversationId = nil
        }
        saveIndex()
    }

    /// Carry out a proposal, as the user: send its text, interrupt its agent, answer the agent's approval
    /// prompt, or start its new session.
    func approve(_ proposal: RavenProposal, in conversationId: String) async {
        mapProposalErrors[proposal.id] = nil
        if proposal.action.isOnMailOrCalendar {
            do {
                let outcome = try await fleetModel.mailService.carryOut(proposal)
                mapProposalOutcomes[proposal.id] = outcome
                conversations.decide(proposal.id, in: conversationId, RavenDecision(outcome: .done, decidedAt: .now))
                saveIndex()
            } catch {
                mapProposalErrors[proposal.id] = String(describing: error)
            }
            return
        }
        do {
            let client = try fleetModel.requireClient()
            let delivery: FleetDelivery
            switch proposal.action {
            case .message:
                delivery = try await client.send(proposal.text, to: proposal.agentId ?? "")
            case .interrupt:
                delivery = try await client.interrupt(proposal.agentId ?? "")
            case .approve:
                delivery = try await client.approve(proposal.agentId ?? "", choice: proposal.choice ?? RavenProposal.approveDeny)
            case .spawn:
                delivery = try await client.launch(LaunchRequest(
                    rookName: proposal.rook ?? "",
                    cwd: proposal.cwd ?? "",
                    harness: proposal.harness ?? Workdir.harnessClaude,
                    prompt: proposal.text,
                    playbookId: proposal.playbookId,
                    listSkillIds: proposal.listSkillIds,
                    role: proposal.role,
                    listTeams: proposal.listTeams
                ))
            case .draftMail, .addEvent, .changeEvent, .removeEvent, .openEvent:
                return
            case .join, .leave, .createTeam:
                try await changeTeam(proposal, with: client)
                conversations.decide(proposal.id, in: conversationId, RavenDecision(outcome: .done, decidedAt: .now))
                saveIndex()
                return
            }
            mapDeliveries[delivery.id] = delivery
            conversations.decide(proposal.id, in: conversationId, RavenDecision(outcome: .sent(deliveryId: delivery.id), decidedAt: .now))
            saveIndex()
        } catch {
            mapProposalErrors[proposal.id] = FleetModel.describe(error)
        }
    }

    /// Carry out a proposal that changes a team on roost.
    private func changeTeam(_ proposal: RavenProposal, with client: RoostClient) async throws {
        let teamId = proposal.team ?? ""
        switch proposal.action {
        case .join:
            try await client.join(proposal.agentId ?? "", team: teamId, duty: proposal.duty)
        case .leave:
            try await client.leave(proposal.agentId ?? "", team: teamId)
        case .createTeam:
            var mapBody: [String: JSONValue] = ["id": .string(teamId), "name": .string(proposal.teamTitle ?? teamId)]
            if !proposal.goal.isEmpty {
                mapBody["attributes"] = .object(["goal": .string(proposal.goal)])
            }
            _ = try await fleetModel.create(AgentFleet.teamKind, body: mapBody)
        case .message, .interrupt, .approve, .spawn, .draftMail, .addEvent, .changeEvent, .removeEvent, .openEvent:
            return
        }
    }

    func reject(_ proposal: RavenProposal, in conversationId: String) {
        conversations.decide(proposal.id, in: conversationId, RavenDecision(outcome: .rejected, decidedAt: .now))
        saveIndex()
    }

    /// Read again the deliveries a conversation's decisions sent that have not settled.
    func refreshDeliveries(in conversationId: String) async {
        guard let client = fleetModel.client(), let conversation = conversations.conversation(conversationId) else {
            return
        }
        for decision in conversation.mapDecisions.values {
            guard
                case .sent(let deliveryId) = decision.outcome,
                mapDeliveries[deliveryId]?.isSettled != true
            else {
                continue
            }
            do {
                mapDeliveries[deliveryId] = try await client.delivery(deliveryId)
            } catch {
                Self.logger.info("cannot read delivery \(deliveryId, privacy: .public): \(FleetModel.describe(error), privacy: .public)")
            }
        }
    }

    /// The user's decisions Raven has not heard of, one line each, now marked as told.
    private func decisionLines(in conversationId: String) -> [String] {
        let mapUnreported = conversations.takeUnreportedDecisions(in: conversationId)
        saveIndex()
        let mapProposed = Dictionary((mapProposals[conversationId] ?? []).map { ($0.id, $0) }) { first, _ in first }
        return mapUnreported.keys.sorted().map { proposalId in
            let about = mapProposed[proposalId].map { "your \($0.action.rawValue) for \($0.agentTitle) (\(proposalId))" } ?? proposalId
            switch mapUnreported[proposalId]?.outcome {
            case .sent(let deliveryId):
                return "- \(about): the user sent it; delivery \(deliveryId)"
            case .done:
                return "- \(about): the user approved it, and it is done"
            default:
                return "- \(about): the user decided not to send it"
            }
        }
    }

    func rename(_ conversationId: String, to title: String) {
        conversations.rename(conversationId, to: title)
        saveIndex()
    }

    // MARK: - A request

    private func perform(prompt: String, sessionId: String, isFirstTurn: Bool, client: RoostClient) async {
        let workspace: URL
        do {
            workspace = try prepareWorkspace(endpoint: client.endpoint)
        } catch {
            finish(sessionId, .failed("can't prepare the workspace: \(error.localizedDescription)"))
            return
        }
        await report(sessionId, [
            Self.event(sessionId, "started", detail: [
                "name": .string(Self.agentName),
                "harness": .string("claude"),
                "rook_name": .string(Self.rookName),
                "tab": .string("raven"),
                "cwd": .string(workspace.path),
                "title": .string(conversations.conversation(sessionId)?.title ?? ""),
            ]),
            Self.event(sessionId, "state", detail: ["state": .string(AgentState.thinking.rawValue)]),
        ], to: client)
        let listSessionArguments = isFirstTurn ? ["--session-id", sessionId] : ["--resume", sessionId]
        let agent = HeadlessAgent(launch: HeadlessAgent.Launch(
            arguments: ["-p", prompt] + listSessionArguments + [
                "--output-format", "stream-json",
                "--verbose",
                "--setting-sources", "project",
                "--mcp-config", workspace.appending(path: Self.mcpConfigName).path,
                "--strict-mcp-config",
                "--allowedTools",
            ] + Self.listAllowedTools,
            workingDirectory: workspace,
            mapEnvironment: [
                "PATH": workspace.appending(path: "bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                "XDG_CONFIG_HOME": workspace.appending(path: "config").path,
                "XDG_STATE_HOME": workspace.appending(path: "state").path,
                "ROOKERY_AGENT_ID": sessionId,
                "TMUX": nil,
                "TMUX_PANE": nil,
            ],
            executable: executableOverride
        ))
        var finalState = AgentState.done
        do {
            for try await line in agent.run() {
                take(line, into: sessionId)
            }
            if Task.isCancelled {
                finish(sessionId, .cancelled)
            } else if mapStatuses[sessionId] == .running {
                finish(sessionId, .finished(costUSD: nil))
            }
        } catch {
            finish(sessionId, Task.isCancelled ? .cancelled : .failed(Self.describe(error)))
        }
        if case .failed = mapStatuses[sessionId] {
            finalState = .error
        }
        mapTasks[sessionId] = nil
        await report(sessionId, [
            Self.event(sessionId, "state", detail: ["state": .string(finalState.rawValue)]),
            Self.event(sessionId, "ended", detail: [:]),
        ], to: client)
    }

    /// Take one line of the agent's stream-json output: a step of its conversation, kept in its history, or
    /// its result.
    private func take(_ line: Data, into sessionId: String) {
        record(line, in: sessionId)
        guard
            let object = try? JSONDecoder().decode(JSONValue.self, from: line),
            object["type"]?.stringValue == "result"
        else {
            return
        }
        var costUSD: Double?
        if case .number(let cost) = object["total_cost_usd"] {
            costUSD = cost
            conversations.addCost(cost, to: sessionId)
            saveIndex()
        }
        if object["is_error"]?.boolValue == true {
            let result = object["result"]?.stringValue ?? ""
            mapStatuses[sessionId] = .failed(result.isEmpty ? "Raven stopped on an error" : result)
        } else {
            mapStatuses[sessionId] = .finished(costUSD: costUSD)
        }
    }

    private func finish(_ sessionId: String, _ status: RavenTurnStatus) {
        mapStatuses[sessionId] = status
    }

    // MARK: - History

    private var historyDirectory: URL {
        (workspaceOverride?.deletingLastPathComponent() ?? DataDirectory.url).appending(path: Self.historyName)
    }

    private func historyFile(of conversationId: String) -> URL {
        historyDirectory.appending(path: "\(conversationId).jsonl")
    }

    /// Add a line to what was said in a conversation, on screen and in its history.
    private func record(_ line: Data, in conversationId: String) {
        var reader = reader(of: conversationId)
        let listProposed = RavenProposal.proposals(in: line)
        if !listProposed.isEmpty {
            mapProposals[conversationId, default: []].append(contentsOf: listProposed)
        }
        let terminated = line + Data("\n".utf8)
        reader.append(terminated)
        mapReaders[conversationId] = reader
        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            let file = historyFile(of: conversationId)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: Self.fileMode])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: terminated)
        } catch {
            Self.logger.error("cannot keep Raven's history: \(error, privacy: .public)")
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
            let file = historyDirectory.appending(path: Self.indexName)
            try JSONEncoder().encode(conversations).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: file.path)
        } catch {
            Self.logger.error("cannot keep Raven's conversations: \(error, privacy: .public)")
        }
    }

    /// The user's request as a transcript line, so the history reads as the session's own transcript does.
    private static func requestLine(_ request: String, at date: Date) -> Data {
        let object: [String: Any] = [
            "type": "user",
            "timestamp": date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "message": ["role": "user", "content": request],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func report(_ sessionId: String, _ listEvents: [[String: JSONValue]], to client: RoostClient) async {
        do {
            try await client.post(events: listEvents)
        } catch {
            Self.logger.error("cannot report Raven: \(FleetModel.describe(error), privacy: .public)")
        }
    }

    // MARK: - The workspace and the prompt

    /// Lay out the agent's workspace afresh from the app's resources: its instructions, its skills, the
    /// client, and the connection to roost, readable by the user alone.
    private func prepareWorkspace(endpoint: RoostEndpoint) throws -> URL {
        let fileManager = FileManager.default
        let workspace = workspaceOverride ?? DataDirectory.file(named: Self.workspaceName)
        guard let bundled = Bundle.main.url(forResource: Self.resourceFolder, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let skills = workspace.appending(path: ".claude/skills")
        let bin = workspace.appending(path: "bin")
        let rookConfig = workspace.appending(path: "config/rook")
        for directory in [skills.deletingLastPathComponent(), bin, rookConfig, workspace.appending(path: "state")] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? fileManager.removeItem(at: skills)
        try fileManager.copyItem(at: bundled.appending(path: "skills"), to: skills)
        try Self.replace(workspace.appending(path: "CLAUDE.md"), with: bundled.appending(path: "CLAUDE.md"))
        let client = bin.appending(path: "rook-client")
        try Self.replace(client, with: bundled.appending(path: "rook-client"))
        try fileManager.setAttributes([.posixPermissions: Self.executableMode], ofItemAtPath: client.path)
        let connection = try JSONSerialization.data(withJSONObject: [
            "base_url": endpoint.baseURL.absoluteString,
            "token": endpoint.token,
        ])
        let connectFile = rookConfig.appending(path: "connect.json")
        try connection.write(to: connectFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: connectFile.path)
        try Data(#"{"name": "rookery"}"#.utf8).write(to: rookConfig.appending(path: "config.json"), options: .atomic)
        try hostsSnapshot().write(to: rookConfig.appending(path: "hosts.json"), options: .atomic)
        try Self.mcpConfig().write(to: workspace.appending(path: Self.mcpConfigName), options: .atomic)
        return workspace
    }

    /// The user's hosts as `rook-client host list` reads them: each ssh host with its rook, whether that is
    /// online, and its workdirs; then the rooks no host here runs. They live on this Mac, where Raven runs.
    private func hostsSnapshot() throws -> Data {
        let hosts = fleetModel.hosts
        hosts.reloadHosts()
        let listHosts: [JSONValue] = hosts.listHosts.map { host in
            let rookName = hosts.rookName(of: host)
            let listWorkdirs: [JSONValue] = hosts.book.settings(of: host.alias).listWorkdirs.map { workdir in
                .object([
                    "name": .string(workdir.name),
                    "path": .string(workdir.path),
                    "harness": .string(workdir.harness),
                    "playbook": workdir.playbookId.map(JSONValue.string) ?? .null,
                    "skills": .array(workdir.listSkillIds.map(JSONValue.string)),
                    "role": .string(workdir.role),
                    "teams": .array(workdir.listTeams.map { .object(["team": .string($0.teamId), "duty": .string($0.duty)]) }),
                ])
            }
            return .object([
                "alias": .string(host.alias),
                "address": .string(host.address),
                "rook": rookName.map(JSONValue.string) ?? .null,
                "online": .bool(rookName.map(hosts.isOnline) ?? false),
                "workdirs": .array(listWorkdirs),
            ])
        }
        let listRooks: [JSONValue] = hosts.listUnmatchedRooks.map { rookName in
            .object(["rook": .string(rookName), "online": .bool(hosts.isOnline(rookName))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSONValue.object(["hosts": .array(listHosts), "rooks_without_host": .array(listRooks)]))
    }

    /// Raven's MCP servers: `rookery-mail`, beside the app's executable, which reaches the Mac's mail and
    /// calendars through the running app; none when it is missing, as in a build run outside the bundle.
    private static func mcpConfig() throws -> Data {
        var mapServers: [String: JSONValue] = [:]
        if
            let executable = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: mailServerExecutable),
            FileManager.default.isExecutableFile(atPath: executable.path)
        {
            mapServers[mailServerName] = .object(["command": .string(executable.path), "args": .array([])])
        }
        return try JSONEncoder().encode(JSONValue.object(["mcpServers": .object(mapServers)]))
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// The request as the agent reads it: the user's words, the resources they named, and the agent's id.
    static func prompt(
        _ request: String,
        listMentions: [FleetRef],
        graph: ResourceGraph,
        agentId: String,
        listDecisions: [String]
    ) -> String {
        var listLines = [request]
        if !listDecisions.isEmpty {
            listLines.append("")
            listLines.append("Since your last answer, the user decided on your proposals:")
            listLines.append(contentsOf: listDecisions)
        }
        let listUnique = listMentions.reduce(into: [FleetRef]()) { list, ref in
            if !list.contains(ref) {
                list.append(ref)
            }
        }
        if !listUnique.isEmpty {
            listLines.append("")
            listLines.append("The request names these resources:")
            for ref in listUnique {
                listLines.append("- \(ref.kind) \"\(graph.name(of: ref))\" (id \(ref.id))")
            }
        }
        listLines.append("")
        listLines.append("Your agent id is \(agentId); pass --as-agent \(agentId) on every change.")
        return listLines.joined(separator: "\n")
    }

    private static func event(_ sessionId: String, _ verb: String, detail mapDetail: [String: JSONValue]) -> [String: JSONValue] {
        [
            "actor": .object(["kind": .string(AgentFleet.agentKind), "id": .string(sessionId)]),
            "verb": .string(verb),
            "detail": .object(mapDetail),
        ]
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? HeadlessAgentError {
            return error.description
        }
        return FleetModel.describe(error)
    }
}
