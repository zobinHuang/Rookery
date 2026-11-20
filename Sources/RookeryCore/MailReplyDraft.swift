import Foundation

/// A mail being written in Rookery's Mail page before the user sends it: the account it goes from, the
/// message it answers, its recipients, subject and text. Raven's proposed drafts become one to edit, kept
/// in Rookery's drafts until sent or thrown away.
public struct MailReplyDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let createdAt: Date
    /// The Raven proposal it came from, so one proposal makes one draft.
    public let proposalId: String?
    /// The account's address the mail is sent from.
    public var account: String
    /// The message it answers, by the mail library's id; nil for a new message.
    public var replyToMessageId: Int?
    public var listTo: [String]
    public var listCc: [String]
    public var subject: String
    public var body: String
    /// The files sent with it, by their absolute paths.
    public var listAttachments: [String]

    /// The most bytes of attachments a mail carries, as mail servers commonly take.
    public static let attachmentLimitBytes = 20 * 1024 * 1024

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case proposalId
        case account
        case replyToMessageId
        case listTo
        case listCc
        case subject
        case body
        case listAttachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        proposalId = try container.decodeIfPresent(String.self, forKey: .proposalId)
        account = try container.decode(String.self, forKey: .account)
        replyToMessageId = try container.decodeIfPresent(Int.self, forKey: .replyToMessageId)
        listTo = try container.decode([String].self, forKey: .listTo)
        listCc = try container.decode([String].self, forKey: .listCc)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        listAttachments = try container.decodeIfPresent([String].self, forKey: .listAttachments) ?? []
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        createdAt: Date = .now,
        proposalId: String? = nil,
        account: String,
        replyToMessageId: Int?,
        listTo: [String],
        listCc: [String],
        subject: String,
        body: String,
        listAttachments: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.proposalId = proposalId
        self.account = account
        self.replyToMessageId = replyToMessageId
        self.listTo = listTo
        self.listCc = listCc
        self.subject = subject
        self.body = body
        self.listAttachments = listAttachments
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
            proposalId: proposal.id,
            account: mapPayload["account"]?.stringValue ?? "",
            replyToMessageId: mapPayload["reply_to"]?.numberValue.map { Int($0) },
            listTo: strings("to"),
            listCc: strings("cc"),
            subject: mapPayload["subject"]?.stringValue ?? "",
            body: mapPayload["body"]?.stringValue ?? proposal.text,
            listAttachments: strings("attachments")
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

/// The mails being written in Rookery, Raven's drafts among them, the newest first.
public struct MailDraftBox: Codable, Equatable, Sendable {
    public static let fileName = "mail-drafts.json"

    public private(set) var listDrafts: [MailReplyDraft] = []

    public init(listDrafts: [MailReplyDraft] = []) {
        self.listDrafts = listDrafts.sorted { $0.createdAt > $1.createdAt }
    }

    /// The draft with an id, if it is kept.
    public func draft(_ draftId: String) -> MailReplyDraft? {
        listDrafts.first { $0.id == draftId }
    }

    /// Keep a draft, unless one from the same proposal is kept already.
    ///
    /// - Returns: whether it was added
    @discardableResult
    public mutating func add(_ draft: MailReplyDraft) -> Bool {
        if let proposalId = draft.proposalId, listDrafts.contains(where: { $0.proposalId == proposalId }) {
            return false
        }
        let index = listDrafts.firstIndex { $0.createdAt < draft.createdAt } ?? listDrafts.endIndex
        listDrafts.insert(draft, at: index)
        return true
    }

    /// Replace a kept draft with its edited self.
    public mutating func update(_ draft: MailReplyDraft) {
        guard let index = listDrafts.firstIndex(where: { $0.id == draft.id }) else {
            return
        }
        listDrafts[index] = draft
    }

    public mutating func remove(_ draftId: String) {
        listDrafts.removeAll { $0.id == draftId }
    }
}

