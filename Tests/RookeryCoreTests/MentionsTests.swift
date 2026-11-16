import RookeryCore
import Testing

struct MentionsTests {
    private let listResources = [
        FleetResource(kind: "skill", id: "review", name: "review", mapAttributes: [:], lastUsedAt: "2"),
        FleetResource(kind: "playbook", id: "backend-review", name: "Backend review", mapAttributes: [:], lastUsedAt: "3"),
        FleetResource(kind: "memory", id: "m-1", name: "refund rules", mapAttributes: [:], lastUsedAt: "1"),
    ]

    @Test func findsTheMentionBeingTyped() {
        #expect(Mentions.activeQuery(in: "tidy @rev") == "rev")
        #expect(Mentions.activeQuery(in: "@") == "")
        #expect(Mentions.activeQuery(in: "mail me@example") == nil)
        #expect(Mentions.activeQuery(in: "tidy @review now") == nil)
    }

    @Test func suggestsByNameAndKind() {
        #expect(Mentions.suggestions(for: "rev", among: listResources).map(\.id) == ["review", "backend-review"])
        #expect(Mentions.suggestions(for: "playbook/", among: listResources).map(\.id) == ["backend-review"])
    }

    @Test func completesTheMention() {
        #expect(Mentions.complete("merge into @back", with: listResources[1]) == "merge into @playbook/Backend-review ")
    }
}
