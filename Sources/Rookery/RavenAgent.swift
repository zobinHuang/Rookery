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
    static let rookName = "rookery"
    private static let workspaceName = "raven"
    private static let historyName = "raven-history"
    private static let indexName = "conversations.json"
    private static let resourceFolder = "Raven"
    private static let fileMode: Int = 0o600
    private static let executableMode: Int = 0o755
    /// It changes roost through rook-client alone, and reads skills' own pages to describe them.
    private static let listAllowedTools = ["Bash(rook-client:*)", "Skill", "WebFetch"]

    private(set) var conversations = RavenConversations()
    /// What was said in each conversation opened since launch, as read from its history.
    private(set) var mapReaders: [String: TranscriptReader] = [:]
    /// How the latest request of each conversation went, since launch.
    private(set) var mapStatuses: [String: RavenTurnStatus] = [:]
    /// The conversation the panel shows; nil for a new one, not begun yet.
    var openConversationId: String?

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
        let prompt = Self.prompt(request, listMentions: listMentions, graph: fleetModel.graph, agentId: sessionId)
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
        return workspace
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// The request as the agent reads it: the user's words, the resources they named, and the agent's id.
    static func prompt(_ request: String, listMentions: [FleetRef], graph: ResourceGraph, agentId: String) -> String {
        var listLines = [request]
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
