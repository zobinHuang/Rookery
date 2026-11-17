import Foundation
import RookeryCore
import Testing

struct RookMessageTests {
    @Test func aFramedMessageReadsBackAsSent() {
        let framed = RookMessage.framed(
            senderId: "s-9",
            senderTitle: "API server",
            text: "v2 is tagged.\n\nShip it?",
            team: "api",
            thread: "t-1",
            isAnswerWanted: true
        )
        #expect(framed.hasPrefix("Message from agent s-9 (\"API server\") to team api, through rook (thread t-1):"))
        #expect(framed.hasSuffix("To answer: rook message s-9 --thread t-1 \"...\"; to answer the whole team: rook team send api --thread t-1 \"...\""))
        let message = RookMessage.parse(framed)
        #expect(message == RookMessage(sender: "agent s-9 (\"API server\")", team: "api", thread: "t-1", text: "v2 is tagged.\n\nShip it?"))
        #expect(message?.senderName == "API server")
    }

    @Test func aMessageWantingNoAnswerAndOneFromRavenReadToo() {
        let framed = RookMessage.framed(senderId: "s-9", senderTitle: nil, text: "done", team: nil, thread: "t-2", isAnswerWanted: false)
        #expect(RookMessage.parse(framed)?.text == "done")
        #expect(RookMessage.parse(framed)?.senderName == "agent s-9")
        let fromRaven = "Message from Raven, the user's assistant in Rookery, speaking for the user (agent r-1 (\"Release check\")), through rook (thread t-3):\n\nIs v2 tagged?\n\nTo answer: rook message r-1 --thread t-3 \"...\""
        #expect(RookMessage.parse(fromRaven)?.senderName == "Raven")
        #expect(RookMessage.parse(fromRaven)?.text == "Is v2 tagged?")
        #expect(RookMessage.parse("Please fix the build") == nil)
    }

    @Test func aTranscriptShowsAMessageThroughRookAsItsSendersNotTheUsers() throws {
        let framed = RookMessage.framed(senderId: "s-9", senderTitle: "API server", text: "the api is up", team: nil, thread: "t-1", isAnswerWanted: true)
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": framed]])
        var reader = TranscriptReader()
        reader.append(line + Data("\n".utf8))
        #expect(reader.listEntries.map(\.role) == [.message("API server")])
        #expect(reader.listEntries.first?.text == "the api is up")
    }
}
