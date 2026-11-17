import Foundation
import RookeryCore
import Testing

struct AgentIdentityTests {
    private func agent(role: String = "", focus: String = "") -> FleetAgent {
        FleetAgent(
            id: "a-1",
            name: "studio/api",
            title: "",
            state: .idle,
            harness: "claude",
            rookName: "studio",
            tab: "api",
            cwd: "/srv/api",
            gitBranch: "main",
            model: "",
            hostname: "studio",
            parentId: nil,
            lastUsedAt: "",
            role: role,
            focus: focus
        )
    }

    private func digest(prompts: Int, compactions: Int = 0) -> TranscriptDigest {
        var digest = TranscriptDigest()
        var listEntries: [TranscriptEntry] = []
        for index in 0..<prompts {
            listEntries.append(TranscriptEntry(id: index, role: .user, text: "prompt \(index)"))
        }
        for index in 0..<compactions {
            listEntries.append(TranscriptEntry(id: prompts + index, role: .compaction, text: "summary \(index)"))
        }
        digest.add(listEntries)
        return digest
    }

    @Test func aDigestKeepsTheFirstAndLatestPromptsAndTheLatestSummary() {
        var digest = TranscriptDigest()
        digest.add([
            TranscriptEntry(id: 0, role: .user, text: "port the decoder"),
            TranscriptEntry(id: 1, role: .tool("Bash"), text: "make"),
            TranscriptEntry(id: 2, role: .assistant, text: "done"),
            TranscriptEntry(id: 3, role: .compaction, text: "we ported it"),
        ])
        digest.add((4..<12).map { TranscriptEntry(id: $0, role: .user, text: "next \($0)") })
        #expect(digest.promptCount == 9)
        #expect(digest.compactionCount == 1)
        #expect(digest.firstPrompt == "port the decoder")
        #expect(digest.listRecentPrompts == ["next 7", "next 8", "next 9", "next 10", "next 11"])
        #expect(digest.latestSummary == "we ported it")
        #expect(digest.latestReply == "done")
    }

    @Test func anIdentityIsDueOnceThereIsAPromptAndAgainAfterACompactionOrManyPrompts() {
        #expect(!AgentIdentity.isDue(role: "", roleSource: "", focus: "", digest: TranscriptDigest(), hasRun: false))
        #expect(AgentIdentity.isDue(role: "", roleSource: "", focus: "", digest: digest(prompts: 1), hasRun: false))
        #expect(!AgentIdentity.isDue(role: "owner", roleSource: "auto", focus: "porting", digest: digest(prompts: 3), hasRun: true))
        #expect(AgentIdentity.isDue(role: "owner", roleSource: "auto", focus: "porting", digest: digest(prompts: 20), hasRun: true))
        #expect(AgentIdentity.isDue(role: "owner", roleSource: "auto", focus: "porting", digest: digest(prompts: 0, compactions: 1), hasRun: true))
        #expect(!AgentIdentity.isDue(role: "", roleSource: "user", focus: "porting", digest: digest(prompts: 3), hasRun: true))
    }

    @Test func theUsersAndTheAgentsOwnWordsAreKept() {
        #expect(AgentIdentity.isKeptAsWritten("user"))
        #expect(AgentIdentity.isKeptAsWritten("agent"))
        #expect(!AgentIdentity.isKeptAsWritten("launch"))
        #expect(!AgentIdentity.isKeptAsWritten("auto"))
        #expect(!AgentIdentity.isKeptAsWritten(""))
    }

    @Test func thePromptCarriesWhatTheTranscriptSaysAndTheCurrentRole() {
        let prompt = AgentIdentity.prompt(for: agent(role: "owner of the API"), roleSource: "launch", digest: digest(prompts: 2, compactions: 1))
        #expect(prompt.contains("/srv/api on branch main"))
        #expect(prompt.contains("Current role (launch): owner of the API"))
        #expect(prompt.contains("The user's first prompt:\nprompt 0"))
        #expect(prompt.contains("- prompt 1"))
        #expect(prompt.contains("summary 0"))
    }

    @Test func anAnswerIsReadFromItsFirstJSONObjectAndKeptToALine() {
        let identity = AgentIdentity.parse("Here it is:\n{\"role\": \"owner of\\nthe decoder.\", \"focus\": \"\\\"porting tests\\\"\"}\nDone.")
        #expect(identity == AgentIdentity(role: "owner of the decoder", focus: "porting tests"))
        #expect(AgentIdentity.parse("no json here") == nil)
        #expect(AgentIdentity.parse("{\"other\": 1}") == nil)
    }
}
