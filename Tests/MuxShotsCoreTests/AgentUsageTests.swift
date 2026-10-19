import Foundation
import MuxShotsCore
import Testing

struct AgentUsageTests {
    private static let answer = #"""
        {"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":23},
        "limits":[
        {"kind":"session","group":"session","percent":23,"resets_at":"2026-10-19T21:10:00.409449+00:00","severity":"normal"},
        {"kind":"weekly_all","group":"weekly","percent":70,"resets_at":"2026-10-21T05:00:00+00:00","severity":"normal"},
        {"kind":"weekly_scoped","group":"weekly","percent":92,"resets_at":"2026-10-21T05:00:00+00:00","severity":"critical",
         "scope":{"model":{"display_name":"Fable","id":null},"surface":null}}]}}
        """#

    @Test func readsEveryLimitWithShortTitles() throws {
        let usage = try ClaudeCodeUsageDecoder.decode(Data(Self.answer.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.plan == "max")
        #expect(usage.listLimits.map(\.title) == ["5h", "7d", "Fable"])
        #expect(usage.listLimits.map(\.severity) == [.normal, .normal, .critical])
        #expect(usage.listLimits[0].remainingFraction == 0.77)
        let expectedReset = try #require(ISO8601DateFormatter().date(from: "2026-10-19T21:10:00Z"))
        let reset = try #require(usage.listLimits[0].resetsAt)
        #expect(abs(reset.timeIntervalSince(expectedReset) - 0.409) < 0.01)
    }

    @Test func readsWhoIsSignedInFromTheInitializeAnswer() throws {
        let initialize = #"{"account":{"email":"someone@example.com","organization":"Org","subscriptionType":"max"}}"#

        let usage = try ClaudeCodeUsageDecoder.decode(
            Data(Self.answer.utf8),
            initializeData: Data(initialize.utf8),
            fetchedAt: Date()
        )

        #expect(usage.signedInAs == "someone@example.com")
    }

    @Test func refusesAnAnswerWithoutPlanLimits() {
        let answer = #"{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}"#

        #expect(throws: ClaudeCodeUsageDecoder.DecodingError.noPlanLimits) {
            try ClaudeCodeUsageDecoder.decode(Data(answer.utf8), fetchedAt: Date())
        }
    }

    @Test func signsTheDefaultAccountInPlainly() {
        #expect(AgentHarness.claudeCode.signInCommand(configDirectory: nil) == "claude auth login")
    }

    @Test func signsAnotherAccountInThroughItsDirectory() {
        #expect(
            AgentHarness.claudeCode.signInCommand(configDirectory: "~/.claude work")
                == #"CLAUDE_CONFIG_DIR="$HOME/.claude work" claude auth login"#
        )
        #expect(
            AgentHarness.claudeCode.signInCommand(configDirectory: "/tmp/a$b")
                == #"CLAUDE_CONFIG_DIR="/tmp/a\$b" claude auth login"#
        )
    }

    @Test func tellsWhichCodeAgentADirectoryBelongsTo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appending(path: "claude")
        let codex = root.appending(path: "codex")
        let empty = root.appending(path: "empty")
        for directory in [claude, codex, empty] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: claude.appending(path: ".claude.json"))
        try Data().write(to: codex.appending(path: "config.toml"))
        try Data().write(to: codex.appending(path: "auth.json"))

        #expect(AgentDirectoryContents.inspect(claude.path) == .harness(.claudeCode))
        #expect(AgentDirectoryContents.inspect(codex.path) == .unsupported(name: "Codex"))
        #expect(AgentDirectoryContents.inspect(empty.path) == .empty)
    }
}
