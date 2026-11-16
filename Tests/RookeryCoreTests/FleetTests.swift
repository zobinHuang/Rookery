import Foundation
import RookeryCore
import Testing

struct FleetTests {
    private static let resources = #"""
        [{"kind":"agent","id":"s-1","name":"studio/api","attributes":{"state":"working","rook_name":"studio",
          "harness":"claude","cwd":"/srv/api","machine":{"hostname":"studio"}},"last_used_at":"2026-11-16T01:00:00.000+00:00"},
         {"kind":"agent","id":"s-1~explore","name":"studio/api/Explore","attributes":{"parent":"s-1"},"last_used_at":"2026-11-16T01:00:01.000+00:00"},
         {"kind":"agent","id":"s-2","name":"studio/web","attributes":{"state":"done","closed_at":"x"},"last_used_at":"2026-11-16T00:00:00.000+00:00"},
         {"kind":"rook","id":"studio","name":"studio","attributes":{"online":true},"last_used_at":""}]
        """#

    private func fleet() throws -> AgentFleet {
        var fleet = AgentFleet()
        fleet.load(try JSONDecoder().decode([FleetResource].self, from: Data(Self.resources.utf8)), lastSeq: 10)
        return fleet
    }

    @Test func readsAgentsAndRooks() throws {
        let fleet = try fleet()
        let agent = try #require(fleet.mapAgents["s-1"])

        #expect(agent.state == .working)
        #expect(agent.projectName == "api")
        #expect(agent.hostname == "studio")
        #expect(fleet.isOnline(agent))
        #expect(fleet.mapAgents["s-2"]?.state == .ended)
        #expect(fleet.listSessions.map(\.id) == ["s-1", "s-2"])
        #expect(fleet.listSubagents(of: "s-1").map(\.id) == ["s-1~explore"])
    }

    @Test func appliesStatesAndPresenceInOrder() throws {
        var fleet = try fleet()
        let agentRef = FleetRef(kind: "agent", id: "s-1")

        let effect = fleet.apply(FleetEvent(seq: 11, at: "t", actor: agentRef, verb: "state", mapDetail: ["state": .string("needs_approval")]))
        #expect(effect == .changed)
        #expect(fleet.mapAgents["s-1"]?.state == .needsApproval)

        #expect(fleet.apply(FleetEvent(seq: 11, at: "t", actor: agentRef, verb: "ended")) == .unchanged)
        #expect(fleet.apply(FleetEvent(seq: 12, at: "t", actor: FleetRef(kind: "rook", id: "studio"), verb: "disconnected")) == .changed)
        #expect(fleet.mapRooksOnline["studio"] == false)
        #expect(fleet.lastSeq == 12)
    }

    @Test func asksForNewAgentsToBeFetched() throws {
        var fleet = try fleet()
        let newRef = FleetRef(kind: "agent", id: "s-3")

        #expect(fleet.apply(FleetEvent(seq: 11, at: "t", actor: newRef, verb: "started")) == .refetch(newRef))
        #expect(fleet.apply(FleetEvent(seq: 12, at: "t", actor: newRef, verb: "state", mapDetail: ["state": .string("idle")])) == .refetch(newRef))
    }
}

struct AgentGroupsTests {
    @Test func movesAgentsBetweenGroupsKeepingOneHome() {
        var groups = AgentGroups()
        let backend = groups.addGroup(title: "Backend")
        let frontend = groups.addGroup(title: "Frontend")

        groups.move("a", to: backend)
        groups.move("b", to: backend)
        groups.move("c", to: backend, before: "a")
        groups.move("a", to: frontend)

        #expect(groups.listGroups[0].listAgentIds == ["c", "b"])
        #expect(groups.groupId(of: "a") == frontend)
        groups.move("a", to: nil)
        #expect(groups.groupId(of: "a") == nil)
    }

    @Test func forgetsAgentsRookdDropped() {
        var groups = AgentGroups()
        let backend = groups.addGroup(title: "Backend")
        groups.move("a", to: backend)
        groups.move("b", to: backend)

        groups.prune(keeping: ["b"])

        #expect(groups.listGroups[0].listAgentIds == ["b"])
    }

    @Test func reordersAndRenamesGroups() {
        var groups = AgentGroups()
        let first = groups.addGroup(title: "One")
        let second = groups.addGroup(title: "Two")

        groups.moveGroup(second, before: first)
        groups.rename(first, to: "  ")
        groups.rename(second, to: "Second")

        #expect(groups.listGroups.map(\.title) == ["Second", "One"])
    }
}

struct TranscriptReaderTests {
    @Test func readsClaudeCodeTurnsAndToolCalls() {
        var reader = TranscriptReader()
        let lines = #"""
            {"type":"user","message":{"role":"user","content":"fix the login test"}}
            {"type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>/clear</command-name>"}}
            {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
            {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}

            """#

        reader.append(Data(lines.utf8))

        #expect(reader.listEntries.map(\.role) == [.user, .assistant, .tool("Bash")])
        #expect(reader.listEntries.map(\.text) == ["fix the login test", "Looking.", "npm test"])
    }

    @Test func readsCodexRollouts() {
        var reader = TranscriptReader()
        let lines = #"""
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"},{"type":"input_text","text":"add a flag"}]}}
            {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"rg\",\"flag\"]}"}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added."}]}}

            """#

        reader.append(Data(lines.utf8))

        #expect(reader.listEntries.map(\.role) == [.user, .tool("shell"), .assistant])
        #expect(reader.listEntries.map(\.text) == ["add a flag", "rg flag", "Added."])
    }

    @Test func waitsForALineToFinish() {
        var reader = TranscriptReader()
        let line = Data(#"{"type":"user","message":{"content":"hello"}}"#.utf8) + Data("\n".utf8)

        reader.append(line.prefix(10))
        #expect(reader.listEntries.isEmpty)
        reader.append(line.dropFirst(10))

        #expect(reader.listEntries.map(\.text) == ["hello"])
        #expect(reader.byteCount == line.count)
    }
}
