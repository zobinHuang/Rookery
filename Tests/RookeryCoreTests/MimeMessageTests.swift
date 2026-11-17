import Foundation
import RookeryCore
import Testing

struct MimeMessageTests {
    @Test func readsAPlainMessageWithEncodedHeaders() {
        let raw = """
            From: =?UTF-8?B?5byg5LiJ?= <zhang@example.com>
            Subject: =?UTF-8?Q?Re:_=E4=BC=9A=E8=AE=AE?=
             =?UTF-8?Q?_=E6=97=B6=E9=97=B4?=
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hello =E4=BD=A0=E5=A5=BD, soft=
             break.
            """
        let message = MimeMessage(data: Data(raw.utf8))
        #expect(message.header("From") == "张三 <zhang@example.com>")
        #expect(message.header("subject") == "Re: 会议 时间")
        #expect(message.text.hasPrefix("Hello 你好, soft break."))
    }

    @Test func prefersThePlainPartAndListsAttachments() {
        let raw = """
            Content-Type: multipart/mixed; boundary="outer"

            --outer
            Content-Type: multipart/alternative; boundary=inner

            --inner
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: base64

            VGhlIHBsYWluIHRleHQu
            --inner
            Content-Type: text/html; charset=utf-8

            <p>The <b>HTML</b> text.</p>
            --inner--
            --outer
            Content-Type: application/pdf; name="report.pdf"
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            JVBERi0=
            --outer--
            """
        let message = MimeMessage(data: Data(raw.utf8))
        #expect(message.text == "The plain text.")
        #expect(message.listAttachmentNames == ["report.pdf"])
    }

    @Test func turnsHTMLIntoTextWhenThereIsNoPlainPart() {
        let raw = """
            Content-Type: text/html; charset=gb2312

            <html><head><style>p{}</style></head><body><p>First&nbsp;line</p><br>Second &amp; last</body></html>
            """
        #expect(MimeMessage(data: Data(raw.utf8)).text == "First line\n\nSecond & last")
    }

    @Test func readsAnEmlxFileWithoutMailsPropertyList() {
        let message = "Subject: Hi\n\nBody here\n"
        let emlx = "\(message.utf8.count)\n\(message)<?xml version=\"1.0\"?><plist><dict/></plist>"
        let read = MimeMessage(emlx: Data(emlx.utf8))
        #expect(read.header("subject") == "Hi")
        #expect(read.text == "Body here\n")
    }
}

struct MailDataTests {
    @Test func foldersAreKnownWhateverTheProviderAndLanguageCallThem() {
        #expect(MailFolder.of(mailboxURL: "imap://ABC/INBOX") == .inbox)
        #expect(MailFolder.of(mailboxURL: "imap://ABC/%5BGmail%5D/Sent%20Mail") == .sent)
        #expect(MailFolder.of(mailboxURL: "imap://ABC/%5BGmail%5D/%E5%B7%B2%E5%8F%91%E9%82%AE%E4%BB%B6") == .sent)
        #expect(MailFolder.of(mailboxURL: "ews://ABC/%E5%9E%83%E5%9C%BE%E9%82%AE%E4%BB%B6") == .junk)
        #expect(MailFolder.of(mailboxURL: "ews://ABC/Projects") == .other)
        #expect(MailFolder.accountId(ofMailboxURL: "imap://E6C1-99/INBOX") == "E6C1-99")
        #expect(MailFolder.path(ofMailboxURL: "imap://A/%5BGmail%5D/All%20Mail") == ["[Gmail]", "All Mail"])
        #expect(MailFolder.junk.isHiddenByDefault && !MailFolder.archive.isHiddenByDefault)
    }

    @Test func copiesOfOneMeetingOnSeveralCalendarsAreMerged() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, _ globalId: String, _ calendar: String) -> CalendarEventSummary {
            CalendarEventSummary(
                id: id, globalId: globalId, calendarId: calendar, calendar: calendar, account: "acct",
                title: "Sync", startsAt: start, endsAt: start + 1800, isAllDay: false, location: "", notes: "",
                url: "", organizer: "", listAttendees: [], isRecurring: false
            )
        }
        let listMerged = CalendarEventSummary.merged([event("1", "g", "Work"), event("2", "g", "Personal"), event("3", "", "Other")])
        #expect(listMerged.map(\.id) == ["1", "3"])
        #expect(listMerged[0].listAlsoOn == ["Personal (acct)"])
    }

    @Test func accountsAreSeenUnlessHeldBack() {
        let settings = MailAccountSettings(setHiddenMail: ["private@example.com"], setHiddenCalendarAccounts: ["iCloud"], mapKinds: ["me@work.com": "work"])
        #expect(!settings.isMailAllowed("Private@Example.com"))
        #expect(settings.isMailAllowed("me@work.com"))
        #expect(!settings.isCalendarAccountAllowed("iCloud"))
        #expect(settings.kind(of: "ME@work.com") == "work")
    }
}
