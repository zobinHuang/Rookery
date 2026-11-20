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
actor MailService: MailSource {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    /// How long Mail's accounts are kept before they are read again, in the background.
    private static let accountsLifetime: TimeInterval = 300
    private static let maximumEventSpan: TimeInterval = 4 * 366 * 24 * 3600
    private static let proposalIdBytes = 6
    /// How much of a draft's text `list_drafts` shows.
    private static let draftOpeningLength = 200
    /// How many subjects a removal's card names before counting the rest.
    private static let removalSubjectsShown = 6
    static let mailBundleId = "com.apple.mail"
    private static let proposalNote = "Proposed. The user decides in Raven; nothing was done. Do not do it another way."

    private var library: MailLibrary?
    private let calendars = CalendarLibrary()
    /// Rookery's drafts, which Raven lists and may propose throwing away.
    private let drafts: MailDraftStore

    init(drafts: MailDraftStore) {
        self.drafts = drafts
    }
    private var listAccounts: [MailScriptAccount] = []
    private var accountsReadAt: Date?
    /// Reading the accounts again once they are old, while the old ones still serve.
    private var accountsRefresh: Task<Void, Never>?
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
            if mapArguments["count_only"]?.boolValue == true {
                let count = try await openLibrary().count(try query(mapArguments), accounts: allowedAccountAddresses())
                return try Self.json(["count": count])
            }
            return try await Self.json(openLibrary().search(try query(mapArguments), accounts: allowedAccountAddresses()), isCompact: true)
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
        case .listDrafts:
            let listDrafts = await drafts.listDrafts
            return try Self.json(listDrafts.map { draft -> JSONValue in
                var mapDraft: [String: JSONValue] = [
                    "id": .string(draft.id),
                    "account": .string(draft.account),
                    "to": .array(draft.listTo.map(JSONValue.string)),
                    "cc": .array(draft.listCc.map(JSONValue.string)),
                    "subject": .string(draft.subject),
                    "created": .string(draft.createdAt.formatted(.iso8601)),
                    "opening": .string(String(draft.body.prefix(Self.draftOpeningLength))),
                ]
                if let replyToMessageId = draft.replyToMessageId {
                    mapDraft["reply_to"] = .number(Double(replyToMessageId))
                }
                return .object(mapDraft)
            })
        case .proposeDraft, .proposeEvent, .proposeEventChange, .proposeEventRemoval, .proposeOpenEvent, .proposeDraftRemoval:
            return try await propose(tool, mapArguments)
        }
    }

    private func query(_ mapArguments: [String: JSONValue]) throws -> MailQuery {
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
        return query
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
            let namedId = mapArguments["calendar_id"]?.stringValue ?? ""
            guard let calendarId = namedId.isEmpty ? loadSettings().defaultCalendarId : namedId else {
                throw MailToolError.badArgument("name a calendar_id: the user has no default calendar; ask which calendar to use")
            }
            mapPayload["calendar_id"] = .string(calendarId)
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
        case .proposeDraftRemoval:
            action = .removeDrafts
            title = try await checkDraftRemoval(&mapPayload)
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
        let listAttachments = Self.strings(mapPayload, "attachments")
        var totalBytes = 0
        for path in listAttachments {
            guard path.hasPrefix("/"), let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
                throw MailToolError.badArgument("no file at \(path) to attach; give an absolute path")
            }
            totalBytes += size
        }
        guard totalBytes <= MailReplyDraft.attachmentLimitBytes else {
            throw MailToolError.badArgument("the attachments come to more than 20 MB")
        }
        return mapPayload["subject"]?.stringValue ?? "a message from \(account)"
    }

    /// Check that every draft named is one, and list their subjects for the proposal's card.
    ///
    /// - Returns: what the proposal's card calls them
    private func checkDraftRemoval(_ mapPayload: inout [String: JSONValue]) async throws -> String {
        let listDraftIds = Self.strings(mapPayload, "draft_ids")
        let listMailIds = mapPayload["mail_ids"]?.arrayValue?.compactMap(\.numberValue).map { Int($0) } ?? []
        guard !listDraftIds.isEmpty || !listMailIds.isEmpty else {
            throw MailToolError.badArgument("name at least one draft")
        }
        let listKept = await drafts.listDrafts
        var listSubjects: [String] = []
        for draftId in listDraftIds {
            guard let draft = listKept.first(where: { $0.id == draftId }) else {
                throw MailToolError.badArgument("no draft \(draftId) in Rookery's drafts")
            }
            listSubjects.append(draft.subject.isEmpty ? "No subject" : draft.subject)
        }
        let mapAccounts = try await allowedAccountAddresses()
        for mailId in listMailIds {
            guard let message = try openLibrary().message(mailId, accounts: mapAccounts), message.summary.folder == .drafts else {
                throw MailToolError.badArgument("no message \(mailId) in Mail's drafts")
            }
            listSubjects.append(message.summary.subject.isEmpty ? "No subject" : message.summary.subject)
        }
        let listShown = listSubjects.prefix(Self.removalSubjectsShown)
        let rest = listSubjects.count - listShown.count
        mapPayload["drafts"] = .string(listShown.joined(separator: "; ") + (rest > 0 ? "; and \(rest) more" : ""))
        let count = listSubjects.count
        return count == 1 ? "1 draft" : "\(count) drafts"
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
            throw MailToolError.badArgument("a draft goes to Rookery's drafts, to be written and sent there")
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
        case .removeDrafts:
            let listDraftIds = Self.strings(mapPayload, "draft_ids")
            let listMailIds = mapPayload["mail_ids"]?.arrayValue?.compactMap(\.numberValue).map { Int($0) } ?? []
            var listPlaces: [MailMessagePlace] = []
            for mailId in listMailIds {
                if let place = try await message(mailId)?.place {
                    listPlaces.append(place)
                }
            }
            try await MailDrafts.trash(listPlaces)
            await drafts.remove(listDraftIds)
            let count = listDraftIds.count + listPlaces.count
            return count == 1 ? "Threw away 1 draft" : "Threw away \(count) drafts"
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

    // MARK: - For the stage

    /// The unread messages in every allowed account's inbox, newest first.
    func unreadInbox(limit: Int) async throws -> [MailMessageSummary] {
        var query = MailQuery()
        query.folder = .inbox
        query.isUnreadOnly = true
        query.limit = limit
        return try await openLibrary().search(query, accounts: allowedAccountAddresses())
    }

    /// How many messages are unread in every allowed account's inbox.
    func unreadCount() async throws -> Int {
        var query = MailQuery()
        query.folder = .inbox
        query.isUnreadOnly = true
        return try await openLibrary().count(query, accounts: allowedAccountAddresses())
    }

    /// The events between two moments on every allowed calendar, copies of one meeting merged.
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSummary] {
        CalendarEventSummary.merged(try calendars.events(from: start, to: end, calendarIds: try await allowedCalendarIds()))
    }

    /// The messages a query matches in the allowed accounts, newest first.
    func search(_ query: MailQuery) async throws -> [MailMessageSummary] {
        try await openLibrary().search(query, accounts: allowedAccountAddresses())
    }

    /// The messages of a message's conversation, oldest first.
    func thread(of summary: MailMessageSummary) async throws -> [MailMessageSummary] {
        try await openLibrary().thread(summary.conversationId, accounts: allowedAccountAddresses())
    }

    /// The allowed accounts' addresses with their inbox counts, by address.
    func inboxCounts() async throws -> [String: MailboxCount] {
        let mapAddresses = try await allowedAccountAddresses()
        var mapCounts: [String: MailboxCount] = [:]
        for (accountId, count) in try openLibrary().inboxCounts() {
            if let address = mapAddresses[accountId] {
                mapCounts[address] = count
            }
        }
        return mapCounts
    }

    /// The calendars Raven and the stage may show.
    func defaultCalendarId() -> String? {
        loadSettings().defaultCalendarId
    }

    func allowedCalendars() async throws -> [CalendarSummary] {
        let setAllowed = try await allowedCalendarIds()
        return try calendars.calendars().filter { setAllowed.contains($0.id) }
    }

    /// Add an event the user made, on a calendar they may use.
    ///
    /// - Throws: `CalendarLibraryError`
    func addEvent(
        calendarId: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        location: String
    ) throws -> CalendarEventSummary {
        try calendars.addEvent(
            calendarId: calendarId,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            isAllDay: isAllDay,
            location: location,
            notes: ""
        )
    }

    /// Move an event the user dragged, this occurrence only for a recurring one.
    func moveEvent(_ eventId: String, startsAt: Date, endsAt: Date) throws {
        _ = try calendars.changeEvent(eventId, title: nil, startsAt: startsAt, endsAt: endsAt, location: nil, notes: nil)
    }

    /// Remove an event the user chose, this occurrence only for a recurring one.
    func removeEvent(_ eventId: String) throws {
        try calendars.removeEvent(eventId)
    }

    /// Have Mail send a mail written in Rookery, from an account Rookery may use, without showing it: a
    /// reply answers its message in its thread, that message quoted under the user's text as Outlook
    /// quotes it.
    ///
    /// - Throws: `MailToolError` for an account Rookery may not use or no recipient, `MailScriptingError`
    func send(_ draft: MailReplyDraft) async throws {
        guard !draft.listTo.isEmpty || draft.replyToMessageId != nil else {
            throw MailToolError.badArgument("the mail has no recipient")
        }
        var account = draft.account.lowercased()
        var originalPlace: MailMessagePlace?
        if let replyToMessageId = draft.replyToMessageId, let original = try await message(replyToMessageId) {
            originalPlace = original.place
            if account.isEmpty {
                account = original.summary.account.lowercased()
            }
        }
        guard try await allowedAccountAddresses().values.contains(account) else {
            throw MailToolError.badArgument("Rookery may not send from \(draft.account)")
        }
        try await MailDrafts.send(
            sender: account,
            replyingTo: originalPlace,
            listTo: draft.listTo,
            listCc: draft.listCc,
            subject: draft.subject,
            body: draft.body,
            listAttachments: draft.listAttachments
        )
    }

    /// One message read whole, from an allowed account.
    func message(_ messageId: Int) async throws -> MailMessageDetail? {
        try await openLibrary().message(messageId, accounts: allowedAccountAddresses())
    }

    /// Mark a message read or unread in Mail.
    ///
    /// - Throws: `MailToolError` when Mail's copy cannot be found, `MailScriptingError`
    func markRead(_ summary: MailMessageSummary, isRead: Bool) async throws {
        guard let place = try await message(summary.id)?.place else {
            throw MailToolError.unavailable("Mail's copy of the message cannot be found")
        }
        try await MailActions.markRead(place, isRead: isRead)
    }

    /// Flag a message, or take its flag off, in Mail.
    func flag(_ summary: MailMessageSummary, isFlagged: Bool) async throws {
        guard let place = try await message(summary.id)?.place else {
            throw MailToolError.unavailable("Mail's copy of the message cannot be found")
        }
        try await MailActions.flag(place, isFlagged: isFlagged)
    }

    /// When Mail last wrote its library, which changes as mail arrives or is read.
    nonisolated static func libraryStamp() -> Date? {
        guard let root = try? MailLibrary.locate() else {
            return nil
        }
        let data = root.appending(path: "MailData")
        return ["Envelope Index", "Envelope Index-wal"].compactMap { name in
            (try? FileManager.default.attributesOfItem(atPath: data.appending(path: name).path))?[.modificationDate] as? Date
        }.max()
    }

    // MARK: - Accounts

    /// How Rookery stands with the mail and calendars, asking Mail for its accounts afresh.
    func access() async -> MailAccess {
        var access = MailAccess()
        access.settings = loadSettings()
        do {
            _ = try openLibrary()
            access.hasFullDiskAccess = true
        } catch MailLibraryError.noAccess {
            access.hasFullDiskAccess = false
        } catch {
            access.hasFullDiskAccess = true
        }
        access.calendarAuthorization = CalendarLibrary.authorization
        access.listCalendarAccounts = Array(Set(((try? calendars.calendars()) ?? []).map(\.accountTitle))).sorted()
        access.isMailRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailBundleId).isEmpty
        }
        guard access.hasFullDiskAccess else {
            return access
        }
        accountsReadAt = nil
        do {
            access.listMailAccounts = try await accounts()
        } catch {
            access.mailProblem = String(describing: error)
        }
        return access
    }

    /// Ask for calendar access, the first time.
    func requestCalendarAccess() async -> Bool {
        await calendars.requestAccess()
    }

    /// Keep what the user decided about the accounts.
    ///
    /// - Throws: when the file cannot be written
    func save(_ settings: MailAccountSettings) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// The accounts with their calendars, as `list_accounts` gives them.
    private func listedAccounts() async throws -> JSONValue {
        let settings = loadSettings()
        let listCalendars = (try? calendars.calendars()) ?? []
        let mapInboxCounts = (try? openLibrary().inboxCounts()) ?? [:]
        let listMail: [JSONValue] = try await accounts().filter { account in
            account.listAddresses.contains { settings.isMailAllowed($0) }
        }.map { account in
            let address = account.listAddresses.first ?? ""
            let inbox = mapInboxCounts[account.id]
            return .object([
                "address": .string(address),
                "name": .string(account.name),
                "kind": .string(settings.kind(of: address)),
                "inbox_total": inbox.map { .number(Double($0.total)) } ?? .null,
                "inbox_unread": inbox.map { .number(Double($0.unread)) } ?? .null,
            ])
        }
        let listCalendarRows: [JSONValue] = listCalendars.filter { settings.isCalendarAccountAllowed($0.accountTitle) }.map { calendar in
            .object([
                "id": .string(calendar.id),
                "title": .string(calendar.title),
                "account": .string(calendar.accountTitle),
                "takes_events": .bool(calendar.isWritable),
                "default": .bool(calendar.id == settings.defaultCalendarId),
            ])
        }
        return .object(["mail_accounts": .array(listMail), "calendars": .array(listCalendarRows)])
    }

    /// Mail's accounts, read again every few minutes.
    func accounts() async throws -> [MailScriptAccount] {
        guard let accountsReadAt, !listAccounts.isEmpty else {
            return try await readAccounts()
        }
        if Date.now.timeIntervalSince(accountsReadAt) >= Self.accountsLifetime, accountsRefresh == nil {
            accountsRefresh = Task {
                defer { accountsRefresh = nil }
                do {
                    _ = try await readAccounts()
                } catch {
                    Self.logger.error("cannot read Mail's accounts again: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return listAccounts
    }

    /// Ask Mail for its accounts, which only its scripting tells, and keep them.
    private func readAccounts() async throws -> [MailScriptAccount] {
        listAccounts = try await MailScripting.accounts()
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

    /// A result as JSON: indented, or compact for a long list.
    private static func json(_ value: some Encodable, isCompact: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = isCompact ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
