import Foundation

/// The tools Rookery offers a code agent over the Mac's mail and calendars, through the `rookery-mail` MCP
/// server: reading and searching, and proposing a draft or a change to an event, which the user approves
/// in Raven before Rookery carries it out. No tool sends mail, and no tool changes anything by itself.
public enum MailTool: String, CaseIterable, Sendable {
    case listAccounts = "list_accounts"
    case searchMail = "search_mail"
    case readMail = "read_mail"
    case readThread = "read_thread"
    case listEvents = "list_events"
    case proposeDraft = "propose_draft"
    case proposeEvent = "propose_event"
    case proposeEventChange = "propose_event_change"
    case proposeEventRemoval = "propose_event_removal"
    case proposeOpenEvent = "propose_open_event"
    case listDrafts = "list_drafts"
    case proposeDraftRemoval = "propose_draft_removal"

    /// Whether the tool only proposes, its result a proposal for the user.
    public var isProposal: Bool {
        rawValue.hasPrefix("propose_")
    }

    public var description: String {
        switch self {
        case .listAccounts:
            "The user's mail and calendar accounts Rookery may read: each address, its name, whether it is personal or work, and how many messages its inbox holds and how many are unread; and the calendars with their ids and whether they take events."
        case .searchMail:
            "Search the user's mail, newest first, across every account or the ones named. Matches words in the subject, the sender or the opening of the text; junk and trash are left out unless that folder is asked for. Each result names its account. To know how many match, pass count_only rather than paging."
        case .readMail:
            "Read one message whole: who it went to, its text and its attachments' names. Takes the id a search returned."
        case .readThread:
            "List the messages of the conversation a message belongs to, oldest first."
        case .listEvents:
            "List the events between two moments on every calendar, or those of the accounts named; copies of one meeting on several calendars are merged, with the others noted. Times are ISO 8601."
        case .proposeDraft:
            "Propose a draft; it goes into Rookery's drafts at once, in the account named, for the user to change and send from Rookery's Mail page. Never sends. To reply, give the id of the message replied to, and the reply goes from its account."
        case .proposeEvent:
            "Propose a new event on a calendar, for the user to approve. Attendees cannot be invited this way; draft an invitation instead."
        case .proposeEventChange:
            "Propose changing an event's title, time, place or notes, this occurrence only for a recurring event, for the user to approve."
        case .proposeEventRemoval:
            "Propose removing an event, this occurrence only for a recurring event, for the user to approve."
        case .proposeOpenEvent:
            "Propose opening an event in Calendar, where the user answers an invitation; invitations cannot be answered otherwise."
        case .listDrafts:
            "List the drafts in Rookery's drafts, where propose_draft puts them, newest first: each id, account, recipients, subject, the message it replies to and its opening. Mail's own drafts are found with search_mail, folder drafts."
        case .proposeDraftRemoval:
            "Propose throwing drafts away, for the user to approve: Rookery's drafts by their ids from list_drafts, and Mail's drafts by their message ids from search_mail in the drafts folder, which go to the trash."
        }
    }

    /// The JSON schema of the tool's arguments.
    public var inputSchema: JSONValue {
        switch self {
        case .listAccounts:
            Self.schema([:], required: [])
        case .searchMail:
            Self.schema([
                "accounts": Self.list("Addresses of the accounts to search; leave out for all"),
                "query": Self.text("Words to find in the subject, the sender or the opening of the text"),
                "from": Self.text("A sender's address or name, in part"),
                "to": Self.text("A recipient's address or name, in part"),
                "folder": .object([
                    "type": .string("string"),
                    "enum": .array(MailFolder.allCases.map { .string($0.rawValue) }),
                    "description": .string("A folder to keep to"),
                ]),
                "unread_only": Self.flag("Only unread messages"),
                "flagged_only": Self.flag("Only flagged or starred messages"),
                "after": Self.text("Received at or after this moment, ISO 8601"),
                "before": Self.text("Received before this moment, ISO 8601"),
                "limit": .object(["type": .string("integer"), "description": .string("At most this many, up to \(MailQuery.maximumLimit); \(MailQuery.defaultLimit) by default")]),
                "count_only": Self.flag("Only count the matches, however many, rather than list them"),
            ], required: [])
        case .readMail, .readThread:
            Self.schema(["id": .object(["type": .string("integer"), "description": .string("A message's id, from a search")])], required: ["id"])
        case .listEvents:
            Self.schema([
                "start": Self.text("From this moment, ISO 8601"),
                "end": Self.text("Until this moment, ISO 8601"),
                "accounts": Self.list("Account names or addresses whose calendars to read; leave out for all"),
                "query": Self.text("Words to find in the title, place or notes"),
            ], required: ["start", "end"])
        case .proposeDraft:
            Self.schema([
                "account": Self.text("The address to send from; for a reply, leave out to use the account of the message replied to"),
                "reply_to": .object(["type": .string("integer"), "description": .string("The id of the message replied to, if this is a reply")]),
                "to": Self.list("Recipients' addresses"),
                "cc": Self.list("Copied recipients' addresses"),
                "subject": Self.text("The subject"),
                "body": Self.text("The text, plain"),
            ], required: ["body"])
        case .proposeEvent:
            Self.schema([
                "calendar_id": Self.text("The calendar's id, from list_accounts; left out, the user's default calendar, marked `default` there"),
                "title": Self.text("The title"),
                "start": Self.text("ISO 8601"),
                "end": Self.text("ISO 8601"),
                "all_day": Self.flag("A day-long event"),
                "location": Self.text("Where"),
                "notes": Self.text("Notes"),
            ], required: ["title", "start", "end"])
        case .proposeEventChange:
            Self.schema([
                "event_id": Self.text("The event's id, from list_events"),
                "title": Self.text("A new title"),
                "start": Self.text("A new start, ISO 8601"),
                "end": Self.text("A new end, ISO 8601"),
                "location": Self.text("A new place"),
                "notes": Self.text("New notes"),
            ], required: ["event_id"])
        case .proposeEventRemoval, .proposeOpenEvent:
            Self.schema(["event_id": Self.text("The event's id, from list_events")], required: ["event_id"])
        case .listDrafts:
            Self.schema([:], required: [])
        case .proposeDraftRemoval:
            Self.schema([
                "draft_ids": Self.list("Ids of Rookery's drafts, from list_drafts"),
                "mail_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "description": .string("Ids of messages in Mail's drafts folder, from search_mail"),
                ]),
            ], required: [])
        }
    }

    private static func schema(_ mapProperties: [String: JSONValue], required listRequired: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(mapProperties),
            "required": .array(listRequired.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func text(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func flag(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func list(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
}
