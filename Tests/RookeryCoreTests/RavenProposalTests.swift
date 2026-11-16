import Foundation
import RookeryCore
import Testing

struct RavenProposalTests {
    private static let printed = #"{"proposal": {"id": "p-1", "action": "message", "agent": "s-1", "agent_title": "Payments", "text": "run the tests"}}"#
        + "\nProposed. The user decides in Rookery; nothing was sent."

    @Test func findsAProposalInTheResultOfTheCommandThatPrintedIt() throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": Self.printed]]],
        ])
        let expected = try JSONDecoder().decode(
            RavenProposal.self,
            from: Data(#"{"id": "p-1", "action": "message", "agent": "s-1", "agent_title": "Payments", "text": "run the tests"}"#.utf8)
        )
        #expect(RavenProposal.proposals(in: line) == [expected])
    }

    @Test func readsAResultSplitIntoParts() throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["content": [["type": "tool_result", "content": [["type": "text", "text": Self.printed]]]]],
        ])
        #expect(RavenProposal.proposals(in: line).map(\.id) == ["p-1"])
    }

    @Test func readsEveryActionWithItsOwnFields() throws {
        let interrupt = try JSONDecoder().decode(
            RavenProposal.self,
            from: Data(#"{"id": "p-2", "action": "interrupt", "agent": "s-1", "agent_title": "Payments", "text": ""}"#.utf8)
        )
        #expect(interrupt.action == .interrupt)
        let approve = try JSONDecoder().decode(
            RavenProposal.self,
            from: Data(#"{"id": "p-3", "action": "approve", "agent": "s-1", "agent_title": "Payments", "choice": "once"}"#.utf8)
        )
        #expect(approve.choice == RavenProposal.approveOnce)
        let spawn = try JSONDecoder().decode(
            RavenProposal.self,
            from: Data(#"{"id": "p-4", "action": "spawn", "rook": "studio", "cwd": "/src/api", "harness": "claude", "text": "fix it", "agent_title": "claude on studio"}"#.utf8)
        )
        #expect(spawn.agentId == nil)
        #expect(spawn.rook == "studio")
        #expect(spawn.cwd == "/src/api")
    }

    @Test func findsNoneInWhatTheAgentSaid() throws {
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": Self.printed]]],
        ])
        #expect(RavenProposal.proposals(in: line).isEmpty)
    }

    @Test func tellsRavenOfEachDecisionOnce() {
        var conversations = RavenConversations()
        conversations.open("c", with: "hello", at: .now)
        conversations.decide("p-1", in: "c", RavenDecision(outcome: .sent(deliveryId: "d-1"), decidedAt: .now))
        #expect(conversations.takeUnreportedDecisions(in: "c").keys.sorted() == ["p-1"])
        #expect(conversations.takeUnreportedDecisions(in: "c").isEmpty)
    }

    @Test func readsAConversationKeptBeforeDecisionsWere() throws {
        let data = Data(#"{"listConversations":[{"id":"c","title":"t","createdAt":0,"lastAt":0,"turnCount":1,"costUSD":0}]}"#.utf8)
        let conversations = try JSONDecoder().decode(RavenConversations.self, from: data)
        #expect(conversations.conversation("c")?.mapDecisions.isEmpty == true)
    }
}
