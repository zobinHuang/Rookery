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

    @Test func dropsAnAgentDeletedOnRoost() throws {
        var fleet = try fleet()
        let deletion = FleetEvent(
            seq: 11,
            at: "t",
            actor: FleetRef(kind: "person", id: "user"),
            verb: "deleted",
            object: FleetRef(kind: "agent", id: "s-1")
        )
        #expect(fleet.apply(deletion) == .changed)
        #expect(fleet.mapAgents["s-1"] == nil)
    }

    @Test func takesASentPromptAsRecordedOnceTheTranscriptHoldsItAfterItWasSent() {
        let prompt = OutgoingPrompt(id: "d-1", text: "run the  tests\nthen push", sentAt: .now, entryCountAtSend: 1)
        let listBefore = [TranscriptEntry(id: 0, role: .user, text: "run the tests then push")]
        #expect(!prompt.isRecorded(in: listBefore))
        let listAfter = listBefore + [
            TranscriptEntry(id: 1, role: .assistant, text: "ok"),
            TranscriptEntry(id: 2, role: .user, text: "run the tests then push"),
        ]
        #expect(prompt.isRecorded(in: listAfter))
    }

    @Test func namesAGoneSubagentAfterItsSession() {
        var graph = ResourceGraph()
        graph.load(
            kinds: [],
            resources: [
                FleetResource(kind: "agent", id: "s-1", name: "box/bash", mapAttributes: ["title": .string("G-Watch")], lastUsedAt: ""),
            ],
            relations: [],
            recentEvents: [],
            lastSeq: 0
        )
        #expect(graph.name(of: FleetRef(kind: "agent", id: "s-1~a3c5")) == "G-Watch › subagent")
    }

    @Test func readsASubagentsTranscriptFromTheSessionTheHarnessWroteIt() {
        #expect(FleetAgent.transcriptSessionId(of: "6ca28427~a3c52ad0") == "agent-a3c52ad0")
        #expect(FleetAgent.transcriptSessionId(of: "6ca28427") == "6ca28427")
    }

    @Test func namesNoProjectWithoutAWorkingDirectory() {
        #expect(FleetAgent(id: "a", name: "a", state: .idle).projectName == "")
    }

    @Test func takesANewTitle() throws {
        var fleet = try fleet()

        let effect = fleet.apply(FleetEvent(seq: 11, at: "t", actor: FleetRef(kind: "agent", id: "s-1"), verb: "renamed", mapDetail: ["title": .string("G-Watch development")]))

        #expect(effect == .changed)
        #expect(fleet.mapAgents["s-1"]?.displayName == "G-Watch development")
    }

    @Test func asksForNewAgentsToBeFetched() throws {
        var fleet = try fleet()
        let newRef = FleetRef(kind: "agent", id: "s-3")

        #expect(fleet.apply(FleetEvent(seq: 11, at: "t", actor: newRef, verb: "started")) == .refetch(newRef))
        #expect(fleet.apply(FleetEvent(seq: 12, at: "t", actor: newRef, verb: "state", mapDetail: ["state": .string("idle")])) == .refetch(newRef))
    }
}

struct AgentTeamsTests {
    @Test func movesAgentsBetweenTeamsKeepingOneHome() {
        var teams = AgentTeams()
        let backend = teams.addTeam(title: "Backend")
        let frontend = teams.addTeam(title: "Frontend")

        teams.move("a", to: backend)
        teams.move("b", to: backend)
        teams.move("c", to: backend, before: "a")
        teams.move("a", to: frontend)

        #expect(teams.listTeams[0].listAgentIds == ["c", "b"])
        #expect(teams.teamId(of: "a") == frontend)
        teams.move("a", to: nil)
        #expect(teams.teamId(of: "a") == nil)
    }

    @Test func readsTeamsSavedWhenTheyWereGroups() throws {
        let legacy = #"{"listGroups":[{"id":"t","title":"Backend","listAgentIds":["a"],"isCollapsed":false}]}"#

        let teams = try JSONDecoder().decode(AgentTeams.self, from: Data(legacy.utf8))

        #expect(teams.listTeams.map(\.title) == ["Backend"])
    }

    @Test func forgetsAgentsRoostDropped() {
        var teams = AgentTeams()
        let backend = teams.addTeam(title: "Backend")
        teams.move("a", to: backend)
        teams.move("b", to: backend)

        teams.prune(keeping: ["b"])

        #expect(teams.listTeams[0].listAgentIds == ["b"])
    }

    @Test func reordersAndRenamesTeams() {
        var teams = AgentTeams()
        let first = teams.addTeam(title: "One")
        let second = teams.addTeam(title: "Two")

        teams.moveTeam(second, before: first)
        teams.rename(first, to: "  ")
        teams.rename(second, to: "Second")

        #expect(teams.listTeams.map(\.title) == ["Second", "One"])
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

        #expect(reader.listEntries.map(\.role) == [.user, .command("/clear"), .assistant, .tool("Bash")])
        #expect(reader.listEntries.map(\.text) == ["fix the login test", "", "Looking.", "npm test"])
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

    @Test func readsCompactionsCommandsTimesAndTheTitle() {
        var reader = TranscriptReader()
        let lines = #"""
            {"type":"ai-title","aiTitle":"Repo overview"}
            {"type":"user","timestamp":"2026-11-08T05:50:31.324Z","message":{"content":"<command-name>/compact</command-name>\n<command-args></command-args>"}}
            {"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued..."}}
            {"type":"custom-title","customTitle":"G-Watch development"}
            {"type":"user","timestamp":"2026-11-08T05:51:00.000Z","message":{"content":"carry on"}}

            """#

        reader.append(Data(lines.utf8))

        #expect(reader.listEntries.map(\.role) == [.command("/compact"), .compaction, .user])
        #expect(reader.title == "G-Watch development")
        #expect(reader.listEntries.last?.timestamp != nil)
    }

    @Test func startsPartwayAtTheNextWholeLine() {
        let line = #"{"type":"user","message":{"content":"hello"}}"# + "\n"
        let data = Data((line + line).utf8)
        var reader = TranscriptReader(startOffset: 10)

        reader.append(data.dropFirst(10))

        #expect(reader.listEntries.map(\.text) == ["hello"])
        #expect(reader.nextOffset == data.count)
    }

    @Test func foldsRunsOfToolCalls() {
        let listEntries = [
            TranscriptEntry(id: 0, role: .user, text: "go"),
            TranscriptEntry(id: 1, role: .tool("Bash"), text: "ls"),
            TranscriptEntry(id: 2, role: .tool("Read"), text: "a.swift"),
            TranscriptEntry(id: 3, role: .assistant, text: "done"),
        ]

        let listBlocks = TranscriptBlock.blocks(of: listEntries)

        #expect(listBlocks.count == 3)
        #expect(listBlocks[1] == .tools(Array(listEntries[1...2])))
    }

    @Test func splitsARepliesProseHeadingsAndCode() {
        let text = "## Plan\nFirst **this**.\n- one\n- two\n\n```swift\nlet x = 1\n```\nAfter."

        #expect(MarkdownBlock.blocks(of: text) == [
            .heading(level: 2, text: "Plan"),
            .paragraph("First **this**.\n- one\n- two"),
            .code(language: "swift", text: "let x = 1"),
            .paragraph("After."),
        ])
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
