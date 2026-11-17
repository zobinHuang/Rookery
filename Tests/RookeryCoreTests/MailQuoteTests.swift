import RookeryCore
import Testing

struct MailQuoteTests {
    @Test func aReplyKeepsOnlyItsOwnWords() {
        let text = "Sounds good, see you then.\n\nOn Mon, Nov 17, 2026 at 3:02 PM Alex Chen <alex@example.com> wrote:\n> Shall we meet at 4?\n"
        #expect(MailQuote.trimmed(text) == "Sounds good, see you then.")
    }

    @Test func anOutlookReplyIsCutAtItsHeader() {
        let text = "Approved.\n\nFrom: Priya Natarajan <p@example.com>\nSent: Monday, November 17, 2026 7:07 PM\nTo: Me\nSubject: Budget"
        #expect(MailQuote.trimmed(text) == "Approved.")
    }

    @Test func aChineseReplyIsCutAtItsAttribution() {
        let text = "收到，谢谢。\n\n在 2026年11月17日 下午3:02，Alex Chen 写道：\n> 请看附件"
        #expect(MailQuote.trimmed(text) == "收到，谢谢。")
    }

    @Test func aMessageWithoutAQuoteOrWithNothingButOneIsLeftAsItIs() {
        #expect(MailQuote.trimmed("Just a note.\nFrom the team") == nil)
        #expect(MailQuote.trimmed("---------- Forwarded message ---------\nFrom: a\nDate: b") == nil)
    }

    @Test func aQuoteInTheMiddleIsKept() {
        #expect(MailQuote.trimmed("You said:\n> it works\nI agree, it does.") == nil)
    }
}
