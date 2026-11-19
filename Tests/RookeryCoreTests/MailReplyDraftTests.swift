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

struct MailMessagePlaceTests {
    @Test func aPlaceIsReadFromTheMailboxURLItsPathDecoded() throws {
        let place = try #require(MailMessagePlace(messageId: 33131, mailboxURL: "imap://E6C13C17-677F/%5BGmail%5D/All%20Mail"))
        #expect(place.accountId == "E6C13C17-677F")
        #expect(place.mailboxPath == "[Gmail]/All Mail")
        #expect(place.messageId == 33131)
        #expect(MailMessagePlace(messageId: 1, mailboxURL: "imap://E6C13C17-677F") == nil)
        #expect(MailMessagePlace(messageId: 1, mailboxURL: "") == nil)
    }
}
