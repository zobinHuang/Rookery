import AppKit
import Foundation
import os
import RookeryCore
import RookeryPlatform

/// A failure of a mail or calendar tool: a bad argument, or something the Mac could not do.
enum MailToolError: Error, CustomStringConvertible {
    case badArgument(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .badArgument(let reason): "bad argument: \(reason)"
        case .unavailable(let reason): reason
        }
    }
}

/// The Mac's mail and calendars as the tools of `rookery-mail` reach them: Mail's library read in place,
/// the accounts Mail holds, the calendars through EventKit; proposals checked and returned for the user to
/// approve, and carried out here once they do. Only the accounts the user allows are seen.
actor MailService {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    private static let accountsLifetime: TimeInterval = 300
    private static let maximumEventSpan: TimeInterval = 4 * 366 * 24 * 3600
    private static let proposalIdBytes = 6
    private static let proposalNote = "Proposed. The user decides in Raven; nothing was done. Do not do it another way."

    private var library: MailLibrary?
    private let calendars = CalendarLibrary()
    private var listAccounts: [MailScriptAccount] = []
    private var accountsReadAt: Date?
    private let settingsURL = DataDirectory.file(named: MailAccountSettings.fileName)

    // MARK: - Tools

    /// Run a tool and give its result as text: JSON, or for a proposal its line and a note.
    ///
    /// - Throws: `MailToolError`, or the library's own errors
    func call(_ tool: MailTool, arguments mapArguments: [String: JSONValue]) async throws -> String {
        switch tool {
        case .listAccounts:
            return try await Self.json(listedAccounts())
        case .searchMail:
            return try await Self.json(search(mapArguments))
        case .readMail:
            let messageId = try Self.integer(mapArguments, "id")
            guard let message = try await openLibrary().message(messageId, accounts: allowedAccountAddresses()) else {
                throw MailToolError.badArgument("no message \(messageId) in the accounts Rookery may read")
            }
            return try Self.json(message)
        case .readThread:
            let messageId = try Self.integer(mapArguments, "id")
            let mapAccounts = try await allowedAccountAddresses()
            let library = try openLibrary()
            guard let message = try library.message(messageId, accounts: mapAccounts) else {
                throw MailToolError.badArgument("no message \(messageId) in the accounts Rookery may read")
            }
            return try Self.json(library.thread(message.summary.conversationId, accounts: mapAccounts))
        case .listEvents:
            return try await Self.json(events(mapArguments))
        case .proposeDraft, .proposeEvent, .proposeEventChange, .proposeEventRemoval, .proposeOpenEvent:
            return try await propose(tool, mapArguments)
        }
    }

    private func search(_ mapArguments: [String: JSONValue]) async throws -> [MailMessageSummary] {
        var query = MailQuery()
        query.listAccounts = Self.strings(mapArguments, "accounts")
        query.text = mapArguments["query"]?.stringValue ?? ""
        query.from = mapArguments["from"]?.stringValue ?? ""
        query.to = mapArguments["to"]?.stringValue ?? ""
        if let folder = mapArguments["folder"]?.stringValue {
            guard let parsed = MailFolder(rawValue: folder) else {
                throw MailToolError.badArgument("unknown folder \(folder)")
            }
            query.folder = parsed
        }
        query.isUnreadOnly = mapArguments["unread_only"]?.boolValue ?? false
        query.isFlaggedOnly = mapArguments["flagged_only"]?.boolValue ?? false
        query.after = try mapArguments["after"]?.stringValue.map(Self.moment)
        query.before = try mapArguments["before"]?.stringValue.map(Self.moment)
        if let limit = mapArguments["limit"]?.numberValue {
            query.limit = Int(limit)
        }
        return try await openLibrary().search(query, accounts: allowedAccountAddresses())
    }

    private func events(_ mapArguments: [String: JSONValue]) async throws -> [CalendarEventSummary] {
        let start = try Self.moment(try Self.string(mapArguments, "start"))
        let end = try Self.moment(try Self.string(mapArguments, "end"))
        guard end > start, end.timeIntervalSince(start) <= Self.maximumEventSpan else {
            throw MailToolError.badArgument("the end must come after the start, within four years")
        }
        let listWanted = Self.strings(mapArguments, "accounts").map { $0.lowercased() }
        let setAllowed = try await allowedCalendarIds()
        let setCalendarIds = try calendars.calendars().filter { calendar in
            setAllowed.contains(calendar.id)
                && (listWanted.isEmpty || listWanted.contains(calendar.accountTitle.lowercased()))
        }.map(\.id)
        let query = (mapArguments["query"]?.stringValue ?? "").lowercased()
        let listEvents = try calendars.events(from: start, to: end, calendarIds: Set(setCalendarIds)).filter { event in
            query.isEmpty || "\(event.title) \(event.location) \(event.notes)".lowercased().contains(query)
        }
        return CalendarEventSummary.merged(listEvents)
    }

    // MARK: - Proposals

    private func propose(_ tool: MailTool, _ mapArguments: [String: JSONValue]) async throws -> String {
        var mapPayload = mapArguments
        let action: RavenProposal.Action
        let title: String
        switch tool {
        case .proposeDraft:
            action = .draftMail
            title = try await checkDraft(&mapPayload)
        case .proposeEvent:
            action = .addEvent
            let calendarId = try Self.string(mapArguments, "calendar_id")
            guard let calendar = try calendars.calendars().first(where: { $0.id == calendarId }), calendar.isWritable else {
                throw MailToolError.badArgument("no calendar \(calendarId) that takes events")
            }
            guard try await allowedCalendarIds().contains(calendarId) else {
                throw MailToolError.badArgument("Rookery may not use calendar \(calendar.title)")
            }
            _ = try Self.moment(try Self.string(mapArguments, "start"))
            _ = try Self.moment(try Self.string(mapArguments, "end"))
            mapPayload["calendar"] = .string("\(calendar.title) (\(calendar.accountTitle))")
            title = try Self.string(mapArguments, "title")
        case .proposeEventChange, .proposeEventRemoval, .proposeOpenEvent:
            action = tool == .proposeEventChange ? .changeEvent : tool == .proposeEventRemoval ? .removeEvent : .openEvent
            let event = try await event(withId: try Self.string(mapArguments, "event_id"))
            for key in ["start", "end"] {
                if let moment = mapArguments[key]?.stringValue {
                    _ = try Self.moment(moment)
                }
            }
            mapPayload["calendar"] = .string("\(event.calendar) (\(event.account))")
            mapPayload["was"] = .string("\(event.title), \(Self.formatter().string(from: event.startsAt))")
            title = event.title
        default:
            throw MailToolError.badArgument("\(tool.rawValue) is not a proposal")
        }
        let proposal: JSONValue = .object([
            "id": .string("p-" + Self.randomHex(Self.proposalIdBytes)),
            "action": .string(action.rawValue),
            "agent_title": .string(title),
            "text": .string(mapArguments["body"]?.stringValue ?? ""),
            "payload": .object(mapPayload),
        ])
        let line = String(decoding: try JSONEncoder().encode(JSONValue.object(["proposal": proposal])), as: UTF8.self)
        return line + "\n" + Self.proposalNote
    }

    /// Check a draft and fill in its account and, for a reply, its recipients and subject.
    ///
    /// - Returns: what the proposal's card calls it
    private func checkDraft(_ mapPayload: inout [String: JSONValue]) async throws -> String {
        let mapAccounts = try await allowedAccountAddresses()
        if let replyTo = mapPayload["reply_to"]?.numberValue {
            guard let message = try openLibrary().message(Int(replyTo), accounts: mapAccounts) else {
                throw MailToolError.badArgument("no message \(Int(replyTo)) to reply to in the accounts Rookery may read")
            }
            mapPayload["account"] = mapPayload["account"] ?? .string(message.summary.account)
            mapPayload["subject"] = mapPayload["subject"] ?? .string(
                message.summary.subject.lowercased().hasPrefix("re:") ? message.summary.subject : "Re: \(message.summary.subject)"
            )
            if Self.strings(mapPayload, "to").isEmpty {
                mapPayload["to"] = .array([.string(message.summary.from.address)])
            }
            mapPayload["replying_to"] = .string("\(message.summary.from.name.isEmpty ? message.summary.from.address : message.summary.from.name): \(message.summary.subject)")
        }
        guard let account = mapPayload["account"]?.stringValue?.lowercased(), mapAccounts.values.contains(account) else {
            throw MailToolError.badArgument("name the account to send from, one of: \(mapAccounts.values.sorted().joined(separator: ", "))")
        }
        mapPayload["account"] = .string(account)
        if mapPayload["reply_to"] == nil && Self.strings(mapPayload, "to").isEmpty {
            throw MailToolError.badArgument("a new message needs a recipient")
        }
        return mapPayload["subject"]?.stringValue ?? "a message from \(account)"
    }

    private func event(withId eventId: String) async throws -> CalendarEventSummary {
        let now = Date.now
        let span: TimeInterval = 2 * 366 * 24 * 3600
        let setAllowed = try await allowedCalendarIds()
        guard let event = try calendars.events(from: now - span, to: now + span, calendarIds: setAllowed).first(where: { $0.id == eventId }) else {
            throw MailToolError.badArgument("no event \(eventId) on the calendars Rookery may use")
        }
        return event
    }

    // MARK: - Carrying out

    /// Carry out a proposal the user approved.
    ///
    /// - Returns: what was done, in a line
    /// - Throws: `MailToolError`, `MailScriptingError`, `CalendarLibraryError`
    func carryOut(_ proposal: RavenProposal) async throws -> String {
        let mapPayload = proposal.mapPayload
        switch proposal.action {
        case .draftMail:
            let mapAccounts = try await allowedAccountAddresses()
            let account = try Self.string(mapPayload, "account")
            guard let accountId = mapAccounts.first(where: { $0.value == account })?.key else {
                throw MailToolError.badArgument("Rookery may not use \(account)")
            }
            let accountName = listAccounts.first { $0.id == accountId }?.name ?? account
            try await MainActor.run {
                try MailDrafts.open(
                    accountName: accountName,
                    sender: account,
                    listTo: Self.strings(mapPayload, "to"),
                    listCc: Self.strings(mapPayload, "cc"),
                    subject: mapPayload["subject"]?.stringValue ?? "",
                    body: mapPayload["body"]?.stringValue ?? ""
                )
            }
            return "Opened the draft in Mail, from \(account)"
        case .addEvent:
            let event = try calendars.addEvent(
                calendarId: try Self.string(mapPayload, "calendar_id"),
                title: try Self.string(mapPayload, "title"),
                startsAt: try Self.moment(try Self.string(mapPayload, "start")),
                endsAt: try Self.moment(try Self.string(mapPayload, "end")),
                isAllDay: mapPayload["all_day"]?.boolValue ?? false,
                location: mapPayload["location"]?.stringValue ?? "",
                notes: mapPayload["notes"]?.stringValue ?? ""
            )
            return "Added \(event.title) to \(event.calendar)"
        case .changeEvent:
            let event = try calendars.changeEvent(
                try Self.string(mapPayload, "event_id"),
                title: mapPayload["title"]?.stringValue,
                startsAt: try mapPayload["start"]?.stringValue.map(Self.moment),
                endsAt: try mapPayload["end"]?.stringValue.map(Self.moment),
                location: mapPayload["location"]?.stringValue,
                notes: mapPayload["notes"]?.stringValue
            )
            return "Changed \(event.title)"
        case .removeEvent:
            try calendars.removeEvent(try Self.string(mapPayload, "event_id"))
            return "Removed the event"
        case .openEvent:
            let eventId = try Self.string(mapPayload, "event_id")
            guard let url = URL(string: "ical://ekevent/\(eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId)?method=show&options=more") else {
                throw MailToolError.badArgument("no event \(eventId)")
            }
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
            return "Opened the event in Calendar"
        default:
            throw MailToolError.badArgument("\(proposal.action.rawValue) is not an action on mail or calendars")
        }
    }

    // MARK: - Accounts

    /// The accounts with their calendars, as `list_accounts` gives them.
    private func listedAccounts() async throws -> JSONValue {
        let settings = loadSettings()
        let listCalendars = (try? calendars.calendars()) ?? []
        let listMail: [JSONValue] = try await accounts().filter { account in
            account.listAddresses.contains { settings.isMailAllowed($0) }
        }.map { account in
            let address = account.listAddresses.first ?? ""
            return .object([
                "address": .string(address),
                "name": .string(account.name),
                "kind": .string(settings.kind(of: address)),
            ])
        }
        let listCalendarRows: [JSONValue] = listCalendars.filter { settings.isCalendarAccountAllowed($0.accountTitle) }.map { calendar in
            .object([
                "id": .string(calendar.id),
                "title": .string(calendar.title),
                "account": .string(calendar.accountTitle),
                "takes_events": .bool(calendar.isWritable),
            ])
        }
        return .object(["mail_accounts": .array(listMail), "calendars": .array(listCalendarRows)])
    }

    /// Mail's accounts, read again every few minutes.
    func accounts() async throws -> [MailScriptAccount] {
        if let accountsReadAt, Date.now.timeIntervalSince(accountsReadAt) < Self.accountsLifetime, !listAccounts.isEmpty {
            return listAccounts
        }
        listAccounts = try await MainActor.run { try MailScripting.accounts() }
        accountsReadAt = .now
        return listAccounts
    }

    /// The accounts Rookery may read, their first address by their id.
    private func allowedAccountAddresses() async throws -> [String: String] {
        let settings = loadSettings()
        var mapAddresses: [String: String] = [:]
        for account in try await accounts() where account.isEnabled {
            if let address = account.listAddresses.first, settings.isMailAllowed(address) {
                mapAddresses[account.id] = address
            }
        }
        return mapAddresses
    }

    private func allowedCalendarIds() async throws -> Set<String> {
        let settings = loadSettings()
        return Set(try calendars.calendars().filter { settings.isCalendarAccountAllowed($0.accountTitle) }.map(\.id))
    }

    private func loadSettings() -> MailAccountSettings {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return MailAccountSettings()
        }
        do {
            return try JSONDecoder().decode(MailAccountSettings.self, from: data)
        } catch {
            Self.logger.error("cannot read the mail account settings: \(error, privacy: .public)")
            return MailAccountSettings()
        }
    }

    private func openLibrary() throws -> MailLibrary {
        if let library {
            return library
        }
        let opened = try MailLibrary(root: MailLibrary.locate())
        library = opened
        return opened
    }

    // MARK: - Arguments and results

    /// The format moments are read and written in: ISO 8601, in this Mac's time zone.
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }

    /// A moment from ISO 8601: a full timestamp, or a date alone at midnight here.
    static func moment(_ text: String) throws -> Date {
        if let date = formatter().date(from: text) {
            return date
        }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = .current
        if let date = dateOnly.date(from: text) {
            return date
        }
        let withoutZone = DateFormatter()
        withoutZone.locale = Locale(identifier: "en_US_POSIX")
        withoutZone.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            withoutZone.dateFormat = format
            if let date = withoutZone.date(from: text) {
                return date
            }
        }
        throw MailToolError.badArgument("\(text) is not an ISO 8601 moment")
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter().string(from: date))
        }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func string(_ mapArguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = mapArguments[key]?.stringValue, !value.isEmpty else {
            throw MailToolError.badArgument("\(key) is needed")
        }
        return value
    }

    private static func integer(_ mapArguments: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = mapArguments[key]?.numberValue else {
            throw MailToolError.badArgument("\(key) is needed, a number")
        }
        return Int(value)
    }

    private static func strings(_ mapArguments: [String: JSONValue], _ key: String) -> [String] {
        guard case .array(let listValues) = mapArguments[key] else {
            return mapArguments[key]?.stringValue.map { [$0] } ?? []
        }
        return listValues.compactMap(\.stringValue)
    }

    private static func randomHex(_ count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}
