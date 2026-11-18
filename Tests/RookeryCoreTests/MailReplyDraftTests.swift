import Foundation
import Testing
@testable import RookeryCore

/// A conversation can be tied to the mail it is about and found again from any message of its thread, and
/// Raven's proposed draft becomes a reply to edit.
struct MailReplyDraftTests {
    @Test func aConversationKeptBeforeMailLinksReadsAndIsFoundFromItsThreadOnceLinked() throws {
        let json = #"{"listConversations":[{"id":"c1","title":"t","createdAt":0,"lastAt":0,"turnCount":1,"costUSD":0}]}"#
        var conversations = try JSONDecoder().decode(RavenConversations.self, from: Data(json.utf8))
        #expect(conversations.conversation(aboutMail: [7, 8]) == nil)
        conversations.link("c1", toMail: 8)
        #expect(conversations.conversation(aboutMail: [7, 8])?.id == "c1")
        let saved = try JSONDecoder().decode(RavenConversations.self, from: JSONEncoder().encode(conversations))
        #expect(saved.conversation("c1")?.mailMessageId == 8)
    }

    @Test func aProposedDraftBecomesAReplyAndRecipientsAreReadFromALine() throws {
        let json = #"{"id":"p1","action":"draft_mail","text":"Hi","payload":{"account":"me@work.example","reply_to":42,"to":["a@x.com"],"cc":[],"subject":"Re: Plan","body":"Hi there"}}"#
        let proposal = try JSONDecoder().decode(RavenProposal.self, from: Data(json.utf8))
        let draft = try #require(MailReplyDraft(proposal: proposal))
        #expect(draft.replyToMessageId == 42)
        #expect(draft.listTo == ["a@x.com"])
        #expect(draft.body == "Hi there")
        #expect(MailReplyDraft.addresses(in: "a@x.com, b@y.com; ,") == ["a@x.com", "b@y.com"])
    }
}

struct MailQuoteReplyTests {
    @Test func aReplyCarriesTheMessageItAnswersQuotedUnderItsOwnText() {
        let sentAt = Date(timeIntervalSince1970: 1_795_000_000)
        let reply = MailQuote.reply(
            to: "Hi Zhuobin,\n\nThe paper is up.\n> earlier line",
            from: MailAddress(address: "x@ust.hk", name: "Xudong Liao"),
            sentAt: sentAt,
            body: "Thanks!\n",
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        #expect(reply.hasPrefix("Thanks!\n\nOn "))
        #expect(reply.contains("Xudong Liao <x@ust.hk> wrote:\n\n> Hi Zhuobin,\n> \n> The paper is up.\n>> earlier line"))
    }
}
