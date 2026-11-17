import Foundation

/// One table of Mail's index: its columns and how many rows it holds.
public struct MailTableShape: Codable, Equatable, Sendable {
    public let name: String
    public let listColumns: [String]
    public let rowCount: Int

    public init(
        name: String,
        listColumns: [String],
        rowCount: Int
    ) {
        self.name = name
        self.listColumns = listColumns
        self.rowCount = rowCount
    }
}

/// One account Mail holds, as Mail's scripting names it: its id, which names its directory in the library
/// and its mailboxes' URLs, its name, its addresses and its kind.
public struct MailScriptAccount: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let listAddresses: [String]
    /// Mail's own word for it, as `imap`, `iCloud`, `pop` or `smtp`.
    public let kind: String
    public let isEnabled: Bool

    public init(
        id: String,
        name: String,
        listAddresses: [String],
        kind: String,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.listAddresses = listAddresses
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

/// One calendar the Mac holds: its id, its name, the account it belongs to, and whether it takes changes.
public struct CalendarSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The account's name, as Calendar shows it, such as an address.
    public let accountTitle: String
    /// The account's kind: `caldav` (Google, iCloud), `exchange`, `local`, `subscribed` or `birthdays`.
    public let accountKind: String
    public let isWritable: Bool

    public init(
        id: String,
        title: String,
        accountTitle: String,
        accountKind: String,
        isWritable: Bool
    ) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
        self.accountKind = accountKind
        self.isWritable = isWritable
    }
}

/// Which of an account's folders a message is in, whatever the provider and language call it.
public enum MailFolder: String, Codable, CaseIterable, Sendable {
    case inbox
    case sent
    case drafts
    case junk
    case trash
    case archive
    case starred
    case important
    case other

    /// The names providers give each folder, in English and Chinese, lowercased; Gmail's under `[Gmail]/`.
    private static let mapNames: [MailFolder: Set<String>] = [
        .inbox: ["inbox", "收件箱"],
        .sent: ["sent", "sent mail", "sent items", "sent messages", "已发邮件", "已发送邮件", "已发送"],
        .drafts: ["drafts", "draft", "草稿", "草稿箱"],
        .junk: ["spam", "junk", "junk email", "junk e-mail", "垃圾邮件"],
        .trash: ["trash", "deleted items", "deleted messages", "bin", "已删除邮件", "已删除"],
        .archive: ["all mail", "archive", "所有邮件", "存档", "归档"],
        .starred: ["starred", "flagged", "已加星标"],
        .important: ["important", "重要"],
    ]

    /// The folder a mailbox is, from its URL, as Mail's library keeps it: `imap://<account>/INBOX`,
    /// `ews://<account>/%E6%94%B6%E4%BB%B6%E7%AE%B1`.
    public static func of(mailboxURL: String) -> MailFolder {
        let name = (path(ofMailboxURL: mailboxURL).last ?? "").lowercased()
        return mapNames.first { $0.value.contains(name) }?.key ?? .other
    }

    /// The account id a mailbox URL names.
    public static func accountId(ofMailboxURL url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else {
            return ""
        }
        return String(url[schemeEnd.upperBound...].prefix { $0 != "/" })
    }

    /// The folder's path under its account, decoded: `["[Gmail]", "All Mail"]`.
    public static func path(ofMailboxURL url: String) -> [String] {
        guard let schemeEnd = url.range(of: "://") else {
            return []
        }
        return url[schemeEnd.upperBound...].split(separator: "/").dropFirst().map { component in
            String(component).removingPercentEncoding ?? String(component)
        }
    }

    /// Whether messages here are left out of a search unless asked for.
    public var isHiddenByDefault: Bool {
        self == .junk || self == .trash
    }
}

/// A person on a message: their address and the name they go by.
public struct MailAddress: Codable, Equatable, Sendable {
    public let address: String
    public let name: String

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

/// A message as a search lists it.
public struct MailMessageSummary: Codable, Equatable, Sendable {
    /// Its row in Mail's library, which `read_mail` takes.
    public let id: Int
    /// The account's address.
    public let account: String
    public let folder: MailFolder
    public let from: MailAddress
    public let subject: String
    public let sentAt: Date
    public let receivedAt: Date
    public let isRead: Bool
    public let isFlagged: Bool
    /// The opening of its text, where Mail kept one.
    public let snippet: String
    public let conversationId: Int
    public let attachmentCount: Int

    public init(
        id: Int,
        account: String,
        folder: MailFolder,
        from: MailAddress,
        subject: String,
        sentAt: Date,
        receivedAt: Date,
        isRead: Bool,
        isFlagged: Bool,
        snippet: String,
        conversationId: Int,
        attachmentCount: Int
    ) {
        self.id = id
        self.account = account
        self.folder = folder
        self.from = from
        self.subject = subject
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.snippet = snippet
        self.conversationId = conversationId
        self.attachmentCount = attachmentCount
    }
}

/// A message read whole: its summary, everyone it went to, its text and its attachments' names.
public struct MailMessageDetail: Codable, Equatable, Sendable {
    public let summary: MailMessageSummary
    public let listTo: [MailAddress]
    public let listCc: [MailAddress]
    public let text: String
    public let listAttachments: [String]
    /// Whether Mail holds only part of it: attachments or long parts not yet downloaded, which opening it in
    /// Mail fetches; its text is usually there.
    public let isPartial: Bool

    public init(
        summary: MailMessageSummary,
        listTo: [MailAddress],
        listCc: [MailAddress],
        text: String,
        listAttachments: [String],
        isPartial: Bool
    ) {
        self.summary = summary
        self.listTo = listTo
        self.listCc = listCc
        self.text = text
        self.listAttachments = listAttachments
        self.isPartial = isPartial
    }
}

/// What a search of the mail asks for; every field left out matches all.
public struct MailQuery: Equatable, Sendable {
    public static let defaultLimit = 30
    public static let maximumLimit = 200

    /// The accounts to search, by address or id; empty for every allowed account.
    public var listAccounts: [String] = []
    /// Words to find in the subject, the sender or the opening of the text.
    public var text = ""
    public var from = ""
    public var to = ""
    /// A folder to keep to; nil for all but junk and trash.
    public var folder: MailFolder?
    public var isUnreadOnly = false
    public var isFlaggedOnly = false
    public var after: Date?
    public var before: Date?
    public var limit = defaultLimit

    public init() {}
}

/// Someone invited to an event, and how they answered.
public struct CalendarAttendee: Codable, Equatable, Sendable {
    public let name: String
    public let address: String
    /// `accepted`, `declined`, `tentative`, `pending` or `unknown`.
    public let status: String
    public let isMe: Bool

    public init(name: String, address: String, status: String, isMe: Bool) {
        self.name = name
        self.address = address
        self.status = status
        self.isMe = isMe
    }
}

/// An event on one of the Mac's calendars.
public struct CalendarEventSummary: Codable, Equatable, Sendable {
    /// Its id on this Mac, which a change or a removal names.
    public let id: String
    /// The id it shares across calendars and accounts, by which copies of one meeting are matched.
    public let globalId: String
    public let calendarId: String
    public let calendar: String
    public let account: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let location: String
    public let notes: String
    public let url: String
    public let organizer: String
    public let listAttendees: [CalendarAttendee]
    public let isRecurring: Bool
    /// The other calendars the same meeting shows on, when copies were merged.
    public var listAlsoOn: [String]

    public init(
        id: String,
        globalId: String,
        calendarId: String,
        calendar: String,
        account: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        location: String,
        notes: String,
        url: String,
        organizer: String,
        listAttendees: [CalendarAttendee],
        isRecurring: Bool,
        listAlsoOn: [String] = []
    ) {
        self.id = id
        self.globalId = globalId
        self.calendarId = calendarId
        self.calendar = calendar
        self.account = account
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.listAttendees = listAttendees
        self.isRecurring = isRecurring
        self.listAlsoOn = listAlsoOn
    }

    /// Events with copies of one meeting merged: the first copy kept, the others' calendars noted on it.
    public static func merged(_ listEvents: [CalendarEventSummary]) -> [CalendarEventSummary] {
        var listMerged: [CalendarEventSummary] = []
        var mapIndices: [String: Int] = [:]
        for event in listEvents.sorted(by: { $0.startsAt < $1.startsAt }) {
            let key = event.globalId.isEmpty ? event.id : "\(event.globalId)@\(event.startsAt.timeIntervalSince1970)"
            if let index = mapIndices[key] {
                listMerged[index].listAlsoOn.append("\(event.calendar) (\(event.account))")
            } else {
                mapIndices[key] = listMerged.count
                listMerged.append(event)
            }
        }
        return listMerged
    }
}

/// What the user decided on this Mac about their accounts for Raven: which mail accounts, by address, and
/// which calendar accounts, by name, it may not see; and which accounts are work ones. Every account not
/// held back is seen.
public struct MailAccountSettings: Codable, Equatable, Sendable {
    public static let fileName = "mail-accounts.json"
    public static let kindPersonal = "personal"
    public static let kindWork = "work"

    public var setHiddenMail: Set<String>
    public var setHiddenCalendarAccounts: Set<String>
    /// Each account's kind, `personal` or `work`, by address.
    public var mapKinds: [String: String]

    public init(setHiddenMail: Set<String> = [], setHiddenCalendarAccounts: Set<String> = [], mapKinds: [String: String] = [:]) {
        self.setHiddenMail = setHiddenMail
        self.setHiddenCalendarAccounts = setHiddenCalendarAccounts
        self.mapKinds = mapKinds
    }

    /// Whether Raven may read a mail account.
    public func isMailAllowed(_ address: String) -> Bool {
        !setHiddenMail.contains(address.lowercased())
    }

    /// Whether Raven may read and propose changes to a calendar account's calendars.
    public func isCalendarAccountAllowed(_ name: String) -> Bool {
        !setHiddenCalendarAccounts.contains(name)
    }

    /// An account's kind as the user set it, or empty when they did not.
    public func kind(of address: String) -> String {
        mapKinds[address.lowercased()] ?? ""
    }
}

/// How many messages a mailbox holds, and how many of them are unread.
public struct MailboxCount: Codable, Equatable, Sendable {
    public let total: Int
    public let unread: Int

    public init(total: Int, unread: Int) {
        self.total = total
        self.unread = unread
    }
}

/// How Rookery stands with the Mac's mail and calendars, for the settings: what it may read, the accounts
/// it found, and what the user decided about them.
public struct MailAccess: Equatable, Sendable {
    public var hasFullDiskAccess = false
    /// `full`, `write_only`, `denied`, `restricted` or `not_determined`.
    public var calendarAuthorization = ""
    public var isMailRunning = false
    /// Why Mail could not be asked for its accounts, if it could not.
    public var mailProblem: String?
    public var listMailAccounts: [MailScriptAccount] = []
    /// The calendar accounts, by name, as Calendar shows them.
    public var listCalendarAccounts: [String] = []
    public var settings = MailAccountSettings()

    public init() {}
}
