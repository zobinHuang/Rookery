import Foundation

/// A mail being written in Rookery's Mail page before the user sends it: the account it goes from, the
/// message it answers, its recipients, subject and text. Raven's proposed drafts become one to edit.
public struct MailReplyDraft: Equatable, Sendable {
    /// The account's address the mail is sent from.
    public var account: String
    /// The message it answers, by the mail library's id; nil for a new message.
    public var replyToMessageId: Int?
    public var listTo: [String]
    public var listCc: [String]
    public var subject: String
    public var body: String

    public init(account: String, replyToMessageId: Int?, listTo: [String], listCc: [String], subject: String, body: String) {
        self.account = account
        self.replyToMessageId = replyToMessageId
        self.listTo = listTo
        self.listCc = listCc
        self.subject = subject
        self.body = body
    }

    /// The draft Raven proposed, as its mail tool checked it; nil for a proposal of anything else.
    public init?(proposal: RavenProposal) {
        guard proposal.action == .draftMail else {
            return nil
        }
        let mapPayload = proposal.mapPayload
        let strings: (String) -> [String] = { key in
            mapPayload[key]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        self.init(
            account: mapPayload["account"]?.stringValue ?? "",
            replyToMessageId: mapPayload["reply_to"]?.numberValue.map { Int($0) },
            listTo: strings("to"),
            listCc: strings("cc"),
            subject: mapPayload["subject"]?.stringValue ?? "",
            body: mapPayload["body"]?.stringValue ?? proposal.text
        )
    }

    /// A reply to a message, to the one who sent it, under its subject.
    ///
    /// - Parameter message: the message answered
    public init(replyingTo message: MailMessageSummary) {
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        self.init(account: message.account, replyToMessageId: message.id, listTo: [message.from.address], listCc: [], subject: subject, body: "")
    }

    /// Recipients written as one comma-separated line, as the editor shows them, back as addresses.
    public static func addresses(in line: String) -> [String] {
        line.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
