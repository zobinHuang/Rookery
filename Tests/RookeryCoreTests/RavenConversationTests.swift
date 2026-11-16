import Foundation
import RookeryCore
import Testing

struct RavenConversationTests {
    @Test func titlesAConversationByItsFirstLineCutAtAWord() {
        #expect(RavenConversation.title(of: "What is G-Watch doing?\nand why") == "What is G-Watch doing?")
        let long = "Which agents are stuck or waiting on me and on what exactly are they waiting right now"
        let title = RavenConversation.title(of: long)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= RavenConversation.titleLength + 1)
        #expect(!title.dropLast().hasSuffix(" "))
        #expect(RavenConversation.title(of: "  ") == "New conversation")
    }

    @Test func keepsTheConversationLastActiveFirst() {
        var conversations = RavenConversations()
        let start = Date(timeIntervalSince1970: 0)
        conversations.open("a", with: "first", at: start)
        conversations.open("b", with: "second", at: start.addingTimeInterval(10))
        #expect(conversations.listConversations.map(\.id) == ["b", "a"])
        conversations.noteTurn(in: "a", at: start.addingTimeInterval(20))
        #expect(conversations.listConversations.map(\.id) == ["a", "b"])
        #expect(conversations.conversation("a")?.turnCount == 2)
    }

    @Test func survivesAnEncodingRoundTrip() throws {
        var conversations = RavenConversations()
        conversations.open("a", with: "hello", at: Date(timeIntervalSince1970: 100))
        conversations.addCost(0.25, to: "a")
        conversations.rename("a", to: "Greeting")
        let data = try JSONEncoder().encode(conversations)
        let decoded = try JSONDecoder().decode(RavenConversations.self, from: data)
        #expect(decoded == conversations)
        #expect(decoded.conversation("a")?.title == "Greeting")
        #expect(decoded.conversation("a")?.costUSD == 0.25)
    }
}
