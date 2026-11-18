import Foundation
import RookeryCore
import Testing

struct RavenConversationTests {
    @Test func aWrittenTitleReplacesOnlyTheRequestsAndNeverTheUsers() {
        var conversations = RavenConversations()
        conversations.open("a", with: "hi raven, what can you do?", at: .now)
        conversations.open("b", with: "plan tomorrow", at: .now)
        conversations.rename("b", to: "My plan")
        let isFirstRetitled = conversations.retitle("a", to: "Raven's abilities")
        let isSecondRetitled = conversations.retitle("a", to: "Something else")
        let isUsersRetitled = conversations.retitle("b", to: "Tomorrow's plan")
        #expect(isFirstRetitled)
        #expect(!isSecondRetitled)
        #expect(!isUsersRetitled)
        #expect(conversations.conversation("a")?.title == "Raven's abilities")
        #expect(conversations.conversation("b")?.title == "My plan")
    }

    @Test func aModelsTitleIsKeptToALineWithoutQuotes() {
        #expect(RavenConversation.writtenTitle(of: "<title>\"明天的日程安排\"</title>\nmore") == "明天的日程安排")
        #expect(RavenConversation.writtenTitle(of: "Thinking about the title, 3-7 words in Chinese\n\n<title>论文作者认领</title>") == "论文作者认领")
        #expect(RavenConversation.writtenTitle(of: "Thinking about the title, 3-7 words in Chinese\n\n论文作者认领") == "论文作者认领")
        #expect(RavenConversation.writtenTitle(of: "Title: Q4 plan review.") == "Q4 plan review")
        #expect(RavenConversation.writtenTitle(of: "  \n") == nil)
    }

    @Test func aConversationKeptBeforeTitlesWereWrittenReadsWithItsRequestsTitle() throws {
        let older = Data(#"{"id": "a", "title": "hi", "createdAt": 0, "lastAt": 0, "turnCount": 1, "costUSD": 0}"#.utf8)
        let conversation = try JSONDecoder().decode(RavenConversation.self, from: older)
        #expect(conversation.titleSource == nil)
    }

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

struct RavenOriginTests {
    @Test func aConversationKeptBeforeOriginsCountsAsTheBoardsOrMailsAndAThreadListsAllOfItsOwn() throws {
        let json = #"{"listConversations":[{"id":"a","title":"t","createdAt":0,"lastAt":2,"turnCount":1,"costUSD":0},{"id":"b","title":"t","createdAt":0,"lastAt":1,"turnCount":1,"costUSD":0,"mailMessageId":5},{"id":"c","title":"t","createdAt":0,"lastAt":0,"turnCount":1,"costUSD":0,"mailMessageId":6,"origin":"mail"}]}"#
        let conversations = try JSONDecoder().decode(RavenConversations.self, from: Data(json.utf8))
        #expect(conversations.conversation("a")?.origin == .board)
        #expect(conversations.conversation("b")?.origin == .mail)
        #expect(conversations.conversations(aboutMail: [5, 6]).map(\.id) == ["b", "c"])
    }
}

