import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// One request to Raven, and what came of it.
struct RavenRun: Identifiable {
    enum Status: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    /// The agent session's id, which is its agent's id on roost too.
    let id: String
    let prompt: String
    let startedAt: Date
    var status = Status.running
    var reader = TranscriptReader()
    /// The agent's closing answer.
    var result = ""
    var costUSD: Double?
}

/// Raven, Rookery's agent over the fleet: Claude Code run headless on this Mac, in a workspace of the app's own that
/// holds Rookery's skills and a `rook-client` connected to the roost the app follows, allowed that
/// command and its skills and nothing else. Each request is one session, reported to roost as the agent
/// `rookery/raven`, so whatever it changes is logged as its doing; it changes without asking, as
/// the user chose.
@MainActor
@Observable
final class RavenAgent {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "raven")
    static let agentName = "rookery/raven"
    static let rookName = "rookery"
    private static let workspaceName = "raven"
    private static let resourceFolder = "Raven"
    private static let fileMode: Int = 0o600
    private static let executableMode: Int = 0o755
    /// It changes roost through rook-client alone, and reads skills' own pages to describe them.
    private static let listAllowedTools = ["Bash(rook-client:*)", "Skill", "WebFetch"]

    private(set) var listRuns: [RavenRun] = []

    @ObservationIgnored private unowned let fleetModel: FleetModel
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The program run in place of Claude Code, for checks that must not call a model.
    @ObservationIgnored var executableOverride: URL?
    /// Where the workspace is laid out in place of the app's data directory, for the same checks.
    @ObservationIgnored var workspaceOverride: URL?

    init(fleetModel: FleetModel) {
        self.fleetModel = fleetModel
    }

    var isRunning: Bool {
        listRuns.last?.status == .running
    }

    /// Ask the agent to do something, naming resources the request is about.
    ///
    /// - Parameters:
    ///   - request: what the user asked, as typed
    ///   - listMentions: the resources it names with @
    func ask(_ request: String, mentioning listMentions: [FleetRef]) {
        guard !isRunning, let client = fleetModel.client() else {
            return
        }
        let sessionId = UUID().uuidString.lowercased()
        listRuns.append(RavenRun(id: sessionId, prompt: request, startedAt: .now))
        let prompt = Self.prompt(request, listMentions: listMentions, graph: fleetModel.graph, agentId: sessionId)
        runTask = Task { [weak self] in
            await self?.perform(prompt: prompt, sessionId: sessionId, client: client)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    // MARK: - A run

    private func perform(prompt: String, sessionId: String, client: RoostClient) async {
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
            ]),
            Self.event(sessionId, "state", detail: ["state": .string(AgentState.thinking.rawValue)]),
        ], to: client)
        let agent = HeadlessAgent(launch: HeadlessAgent.Launch(
            arguments: [
                "-p", prompt,
                "--session-id", sessionId,
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
            } else if case .running = run(sessionId)?.status {
                finish(sessionId, .finished)
            }
        } catch {
            finalState = .error
            finish(sessionId, Task.isCancelled ? .cancelled : .failed(Self.describe(error)))
        }
        if case .failed = run(sessionId)?.status {
            finalState = .error
        }
        await report(sessionId, [
            Self.event(sessionId, "state", detail: ["state": .string(finalState.rawValue)]),
            Self.event(sessionId, "ended", detail: [:]),
        ], to: client)
    }

    /// Take one line of the agent's stream-json output: a step of its conversation, or its result.
    private func take(_ line: Data, into sessionId: String) {
        guard let runIndex = listRuns.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        listRuns[runIndex].reader.append(line + Data("\n".utf8))
        guard
            let object = try? JSONDecoder().decode(JSONValue.self, from: line),
            object["type"]?.stringValue == "result"
        else {
            return
        }
        listRuns[runIndex].result = object["result"]?.stringValue ?? ""
        if case .number(let cost) = object["total_cost_usd"] {
            listRuns[runIndex].costUSD = cost
        }
        if object["is_error"]?.boolValue == true {
            listRuns[runIndex].status = .failed(listRuns[runIndex].result.isEmpty ? "the agent stopped on an error" : listRuns[runIndex].result)
        } else {
            listRuns[runIndex].status = .finished
        }
    }

    private func run(_ sessionId: String) -> RavenRun? {
        listRuns.first { $0.id == sessionId }
    }

    private func finish(_ sessionId: String, _ status: RavenRun.Status) {
        guard let runIndex = listRuns.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        listRuns[runIndex].status = status
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
