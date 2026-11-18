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
    private static func original(text: String, listCc: [MailAddress]) -> MailMessageDetail {
        MailMessageDetail(
            summary: MailMessageSummary(
                id: 9, account: "zhuobin@u.nus.edu", folder: .inbox, from: MailAddress(address: "junjie.tan@nus.edu.sg", name: "Tan Jun Jie"),
                subject: "RE: Enquiry on Leave of Absence", sentAt: Date(timeIntervalSince1970: 1_793_700_000), receivedAt: Date(timeIntervalSince1970: 1_793_700_000),
                isRead: true, isFlagged: false, snippet: "", conversationId: 1, attachmentCount: 0
            ),
            listTo: [MailAddress(address: "zhuobin@u.nus.edu", name: "Huang Zhuobin")],
            listCc: listCc,
            text: text,
            listAttachments: [],
            isPartial: false
        )
    }

    @Test func aReplyCarriesTheMessageItAnswersUnderAnOutlookHeaderAsItWas() {
        let reply = MailQuote.reply(
            to: Self.original(text: "Dear Zhuobin,  \n\n\n\nThank you.", listCc: [MailAddress(address: "linefong@nus.edu.sg", name: "Loo Line Fong")]),
            body: "Dear Junjie,\n\nThanks!\n",
            timeZone: TimeZone(identifier: "Asia/Singapore") ?? .current
        )
        #expect(reply == """
            Dear Junjie,

            Thanks!

            From: Tan Jun Jie <junjie.tan@nus.edu.sg>
            Sent: Tuesday, 3 November 2026 6:00 pm
            To: Huang Zhuobin <zhuobin@u.nus.edu>
            Cc: Loo Line Fong <linefong@nus.edu.sg>
            Subject: RE: Enquiry on Leave of Absence

            Dear Zhuobin,

            Thank you.

            """)
    }

    @Test func aReplyToAMessageCopiedToNoOneLeavesTheCcLineOut() {
        let reply = MailQuote.reply(to: Self.original(text: "Hi", listCc: []), body: "Ok")
        #expect(!reply.contains("Cc:"))
        #expect(MailQuote.trimmed(reply) == "Ok")
    }
}

struct MailQuotePassageTests {
    @Test func quotedLinesBecomePassagesByDepthTheirMarksTakenOff() {
        let listPassages = MailQuote.passages(of: "Sounds good.\n\n> Can you check?\n>\n>> Earlier ask\nDone.")
        #expect(listPassages == [
            QuotedPassage(depth: 0, text: "Sounds good."),
            QuotedPassage(depth: 1, text: "Can you check?"),
            QuotedPassage(depth: 2, text: "Earlier ask"),
            QuotedPassage(depth: 0, text: "Done."),
        ])
    }
}

struct MailDraftBoxTests {
    @Test func aProposalMakesOneDraftTheNewestFirstAndEditsAndRemovalsHold() throws {
        var box = MailDraftBox()
        let older = MailReplyDraft(createdAt: Date(timeIntervalSince1970: 1), proposalId: "p1", account: "me@x.com", replyToMessageId: 3, listTo: ["a@x.com"], listCc: [], subject: "Re: A", body: "One")
        let newer = MailReplyDraft(createdAt: Date(timeIntervalSince1970: 2), account: "me@x.com", replyToMessageId: nil, listTo: ["b@x.com"], listCc: [], subject: "B", body: "Two")
        let isOlderAdded = box.add(older)
        let isRepeatAdded = box.add(MailReplyDraft(proposalId: "p1", account: "me@x.com", replyToMessageId: 3, listTo: [], listCc: [], subject: "", body: ""))
        let isNewerAdded = box.add(newer)
        #expect(isOlderAdded)
        #expect(!isRepeatAdded)
        #expect(isNewerAdded)
        #expect(box.listDrafts.map(\.id) == [newer.id, older.id])
        var edited = older
        edited.body = "Changed"
        box.update(edited)
        #expect(box.draft(older.id)?.body == "Changed")
        let saved = try JSONDecoder().decode(MailDraftBox.self, from: JSONEncoder().encode(box))
        #expect(saved == box)
        box.remove(newer.id)
        #expect(box.listDrafts.map(\.id) == [older.id])
    }
}
