import Foundation
import os
import RookeryCore
import RookeryPlatform

/// Keeps each rook agent's role and focus written, so no one has to: once its user first prompts it, Rookery
/// asks a small model who the agent is and what it works on, from its transcript, and asks again after its
/// context is compacted or many prompts later. A role the user or the agent wrote is kept as written; one a
/// launch gave is the starting point. It reads only what each transcript grew by, and runs while Rookery
/// follows a roost.
@MainActor
final class AgentIdentityKeeper {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "identity")
    /// How often the agents are looked over.
    private static let checkInterval: Duration = .seconds(90)
    /// The first look waits for the fleet to be read.
    private static let firstCheckDelay: Duration = .seconds(20)
    /// How much of a transcript's start is read for the user's first prompt.
    private static let headBytes = 256 * 1024
    /// The most of a transcript's growth read in one look; past it, only its end is read.
    private static let growthReadLimit = 8 * 1024 * 1024
    /// How much of a transcript's end is read when it grew past the limit or was never read.
    private static let tailBytes = 2 * 1024 * 1024
    /// How long an agent the model failed for waits before it is tried again.
    private static let retryDelay: TimeInterval = 600

    private let fleetModel: FleetModel
    private var loopTask: Task<Void, Never>?
    /// Each agent's transcript as read since the identity was last written, by agent id.
    private var mapReaders: [String: TranscriptReader] = [:]
    private var mapDigests: [String: TranscriptDigest] = [:]
    private var mapRetryAfter: [String: Date] = [:]

    init(fleetModel: FleetModel) {
        self.fleetModel = fleetModel
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Look over every live agent of rook's, one after another.
    private func checkAll() async {
        guard let client = fleetModel.client() else {
            return
        }
        let listResources = fleetModel.graph.listResources(of: AgentFleet.agentKind)
        let setLiveIds = Set(listResources.map(\.id))
        mapReaders = mapReaders.filter { setLiveIds.contains($0.key) }
        mapDigests = mapDigests.filter { setLiveIds.contains($0.key) }
        for resource in listResources {
            let agent = FleetAgent(resource: resource)
            guard
                !Task.isCancelled,
                agent.state != .ended,
                agent.parentId == nil,
                agent.rookName != RavenAgent.rookName,
                agent.harness == AgentProgram.claude.rawValue || agent.harness == AgentProgram.codex.rawValue,
                (mapRetryAfter[agent.id] ?? .distantPast) < .now
            else {
                continue
            }
            do {
                try await check(agent, attributes: resource.mapAttributes, with: client)
            } catch {
                mapRetryAfter[agent.id] = Date.now.addingTimeInterval(Self.retryDelay)
                Self.logger.error("cannot keep the identity of \(agent.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Read what an agent's transcript grew by and, if its identity is due, write it.
    private func check(_ agent: FleetAgent, attributes mapAttributes: [String: JSONValue], with client: RoostClient) async throws {
        let checkedOffset = mapAttributes[AgentIdentity.checkedOffsetKey]?.numberValue.map { Int($0) }
        guard let total = try await client.transcript(of: agent.id, from: 0, limit: 1)?.total, total > 0 else {
            return
        }
        try await read(agent, upTo: total, checkedOffset: checkedOffset, with: client)
        let roleSource = mapAttributes[AgentIdentity.roleSourceKey]?.stringValue ?? ""
        let digest = mapDigests[agent.id] ?? TranscriptDigest()
        guard AgentIdentity.isDue(role: agent.role, roleSource: roleSource, focus: agent.focus, digest: digest, hasRun: checkedOffset != nil) else {
            return
        }
        var fullDigest = digest
        if digest.firstPrompt == nil || checkedOffset == nil {
            fullDigest.adoptFirstPrompt(try await firstPrompt(of: agent, with: client))
        }
        guard let identity = try await ask(AgentIdentity.prompt(for: agent, roleSource: roleSource, digest: fullDigest)) else {
            mapRetryAfter[agent.id] = Date.now.addingTimeInterval(Self.retryDelay)
            return
        }
        var mapWrite: [String: JSONValue] = [AgentIdentity.checkedOffsetKey: .number(Double(total))]
        if !AgentIdentity.isKeptAsWritten(roleSource), !identity.role.isEmpty, identity.role != agent.role {
            mapWrite["role"] = .string(identity.role)
            mapWrite[AgentIdentity.roleSourceKey] = .string(AgentIdentity.sourceAuto)
        }
        if !identity.focus.isEmpty, isFocusOpen(mapAttributes) {
            mapWrite["focus"] = .string(identity.focus)
            mapWrite[AgentIdentity.focusSourceKey] = .string(AgentIdentity.sourceAuto)
        }
        try await fleetModel.update(FleetRef(kind: AgentFleet.agentKind, id: agent.id), body: ["attributes": .object(mapWrite)])
        mapReaders[agent.id] = nil
        mapDigests[agent.id] = nil
        Self.logger.info("wrote the identity of \(agent.id, privacy: .public) at \(total) bytes")
    }

    /// Read an agent's transcript on from where it was last read, or from the identity's last writing, up to
    /// its end; a stretch past the limit, or a transcript never read before, is read only at its end.
    private func read(_ agent: FleetAgent, upTo total: Int, checkedOffset: Int?, with client: RoostClient) async throws {
        var reader = mapReaders[agent.id] ?? Self.reader(startingAt: checkedOffset.map { min($0, total) } ?? total)
        if checkedOffset == nil && mapReaders[agent.id] == nil {
            reader = Self.reader(startingAt: max(total - Self.tailBytes, 0))
        } else if total - reader.nextOffset > Self.growthReadLimit {
            reader = Self.reader(startingAt: total - Self.tailBytes)
            mapDigests[agent.id] = nil
        }
        var digest = mapDigests[agent.id] ?? TranscriptDigest()
        while reader.nextOffset < total {
            guard let chunk = try await client.transcript(of: agent.id, from: reader.nextOffset), !chunk.data.isEmpty else {
                break
            }
            let entryCount = reader.listEntries.count
            reader.append(chunk.data)
            digest.add(reader.listEntries.dropFirst(entryCount))
        }
        mapReaders[agent.id] = reader
        mapDigests[agent.id] = digest
    }

    /// The user's first prompt to an agent, from the start of its transcript.
    private func firstPrompt(of agent: FleetAgent, with client: RoostClient) async throws -> String? {
        guard let chunk = try await client.transcript(of: agent.id, from: 0, limit: Self.headBytes) else {
            return nil
        }
        var reader = TranscriptReader()
        reader.append(chunk.data)
        var digest = TranscriptDigest()
        digest.add(reader.listEntries)
        return digest.firstPrompt
    }

    /// A reader that begins at a line's start: one byte back, on the newline that ends the line before, so
    /// the partial line a reader passes over is empty.
    private static func reader(startingAt offset: Int) -> TranscriptReader {
        TranscriptReader(startOffset: max(offset - 1, 0))
    }

    /// Whether Rookery may write the focus: unless the agent set it itself within the last hour.
    private func isFocusOpen(_ mapAttributes: [String: JSONValue]) -> Bool {
        guard mapAttributes[AgentIdentity.focusSourceKey]?.stringValue == AgentIdentity.sourceAgent else {
            return true
        }
        guard
            let focusAt = mapAttributes[AgentIdentity.focusAtKey]?.stringValue,
            let date = FleetTimestamp.date(from: focusAt)
        else {
            return true
        }
        return Date.now.timeIntervalSince(date) > AgentIdentity.agentFocusLifetime
    }

    /// Ask the code agent Raven runs on, with its smallest model and no tools, for an identity.
    private func ask(_ prompt: String) async throws -> AgentIdentity? {
        AgentIdentity.parse(try await QuickModel.answer(prompt, engine: fleetModel.ravenEngine))
    }
}
