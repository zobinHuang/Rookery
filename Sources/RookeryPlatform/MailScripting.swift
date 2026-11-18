import AppKit
import RookeryCore

/// A failure to script Mail.
public enum MailScriptingError: Error, CustomStringConvertible {
    /// The user has not let Rookery control Mail, or declined.
    case notAllowed(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notAllowed(let reason): "Rookery may not control Mail: \(reason)"
        case .failed(let reason): "Mail did not do it: \(reason)"
        }
    }
}

/// Mail driven through AppleScript: the accounts it holds, and a draft put in front of the user. Every call
/// runs on the main actor, where NSAppleScript must run, and the first asks the user to let Rookery
/// control Mail.
@MainActor
public enum MailScripting {
    /// The error AppleScript reports when the user declined, or has not yet allowed, control of an app.
    private static let notAllowedErrors: Set<Int> = [-1743, -1744]
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"

    /// The accounts Mail holds.
    ///
    /// - Throws: `MailScriptingError`
    public static func accounts() throws -> [MailScriptAccount] {
        let source = """
            tell application "Mail"
                set output to ""
                repeat with anAccount in every account
                    set addressText to ""
                    try
                        repeat with anAddress in (get email addresses of anAccount)
                            set addressText to addressText & (contents of anAddress) & ","
                        end repeat
                    end try
                    set kindText to ""
                    try
                        set kindText to (account type of anAccount) as text
                    end try
                    set output to output & (id of anAccount) & "\(fieldSeparator)" & (name of anAccount) & "\(fieldSeparator)" ¬
                        & addressText & "\(fieldSeparator)" & kindText & "\(fieldSeparator)" ¬
                        & ((enabled of anAccount) as text) & "\(recordSeparator)"
                end repeat
                return output
            end tell
            """
        let output = try run(source)
        return output.components(separatedBy: recordSeparator).compactMap { record in
            let listFields = record.components(separatedBy: fieldSeparator)
            guard listFields.count == 5, !listFields[0].isEmpty else {
                return nil
            }
            return MailScriptAccount(
                id: listFields[0],
                name: listFields[1],
                listAddresses: listFields[2].split(separator: ",").map { String($0).lowercased() },
                kind: listFields[3],
                isEnabled: listFields[4] == "true"
            )
        }
    }

    /// Run a script and take its result as text.
    ///
    /// - Throws: `MailScriptingError`
    public static func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw MailScriptingError.failed("the script does not compile")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "error \(number)"
            if notAllowedErrors.contains(number) {
                throw MailScriptingError.notAllowed(message)
            }
            throw MailScriptingError.failed(message)
        }
        return result.stringValue ?? ""
    }
}

/// A mail written in Rookery handed to Mail: opened in a compose window for the user to finish there, or
/// sent when the user presses Send in Rookery, the draft Mail keeps of a scripted message then let go.
/// A reply is made with Mail's own reply to the message it answers, so it stays in its thread. Mail's
/// scripting sets only plain text, so formatted mail is pasted into the compose window's body through its
/// own Select All and Paste, the clipboard put back after.
@MainActor
public enum MailDrafts {
    /// Write a mail in Mail, from an account, with its recipients, subject and text filled in, then open it
    /// or send it.
    ///
    /// - Parameters:
    ///   - sender: the address to send from
    ///   - replyingTo: the `Message-ID` of the message it answers, found in the inboxes; nil, or not found,
    ///     for a new message
    ///   - listTo: the recipients
    ///   - listCc: the copied recipients
    ///   - subject: the subject
    ///   - body: the text
    ///   - isSending: whether Mail sends it at once, rather than opening it for the user
    /// - Throws: `MailScriptingError`
    public static func write(
        sender: String,
        replyingTo messageId: String?,
        listTo: [String],
        listCc: [String],
        subject: String,
        body: String,
        isSending: Bool
    ) throws {
        let recipients = listTo.map { "make new to recipient at end of to recipients with properties {address:\(quoted($0))}" }
            + listCc.map { "make new cc recipient at end of cc recipients with properties {address:\(quoted($0))}" }
        let finish = isSending
            ? """
            send theMessage
                delay 2
                repeat with theDraft in (every message of drafts mailbox whose subject is \(quoted(subject)) and date received ≥ theStart)
                    delete theDraft
                end repeat
            """
            : "set visible of theMessage to true\n    activate"
        let source = """
            tell application "Mail"
                set theStart to (current date) - 5
                set theMessage to missing value
                set theOriginals to {}
                if \(quoted(messageId ?? "")) is not "" then set theOriginals to (every message of inbox whose message id is \(quoted(messageId ?? "")))
                if (count of theOriginals) > 0 then
                    set theMessage to reply (item 1 of theOriginals) opening window no
                else
                    set theMessage to make new outgoing message with properties {visible:false}
                end if
                tell theMessage
                    set sender to \(quoted(sender))
                    set subject to \(quoted(subject))
                    set content to \(quoted(body))
                    delete every to recipient
                    delete every cc recipient
                    \(recipients.joined(separator: "\n            "))
                end tell
                \(finish)
            end tell
            """
        _ = try MailScripting.run(source)
    }

    /// How long the compose window has to appear, and how often it is looked for.
    private static let windowWait: Duration = .seconds(6)
    private static let windowPoll: Duration = .milliseconds(100)
    /// How long Mail takes to lay out a compose window's body, and to take in a paste, before the next step.
    private static let bodySettle: Duration = .milliseconds(400)
    /// How deep in a compose window its body's web area is looked for.
    private static let bodySearchDepth = 8
    private static let mailBundleId = "com.apple.mail"
    /// The role of the web view a compose window writes its body in.
    private static let bodyRole = "AXWebArea"

    /// Write formatted mail in Mail, from an account, with its recipients, subject and HTML filled in, then
    /// leave it open or send it.
    ///
    /// - Parameters:
    ///   - sender: the address to send from
    ///   - replyingTo: the `Message-ID` of the message it answers, found in the inboxes; nil, or not found,
    ///     for a new message
    ///   - listTo: the recipients
    ///   - listCc: the copied recipients
    ///   - subject: the subject
    ///   - html: the whole body, as HTML
    ///   - isSending: whether Mail sends it once written, rather than leaving it to the user
    /// - Throws: `MailScriptingError`, or `AccessibilityError` when Mail's window cannot be reached
    public static func composeFormatted(
        sender: String,
        replyingTo messageId: String?,
        listTo: [String],
        listCc: [String],
        subject: String,
        html: String,
        isSending: Bool
    ) async throws {
        let recipients = listTo.map { "make new to recipient at end of to recipients with properties {address:\(quoted($0))}" }
            + listCc.map { "make new cc recipient at end of cc recipients with properties {address:\(quoted($0))}" }
        let outgoingId = try MailScripting.run("""
            tell application "Mail"
                set theOriginals to {}
                if \(quoted(messageId ?? "")) is not "" then set theOriginals to (every message of inbox whose message id is \(quoted(messageId ?? "")))
                if (count of theOriginals) > 0 then
                    set theMessage to reply (item 1 of theOriginals) opening window yes
                else
                    set theMessage to make new outgoing message with properties {visible:true}
                end if
                tell theMessage
                    set sender to \(quoted(sender))
                    set subject to \(quoted(subject))
                    delete every to recipient
                    delete every cc recipient
                    \(recipients.joined(separator: "\n            "))
                end tell
                activate
                return (id of theMessage) as text
            end tell
            """)
        guard let mail = NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleId).first else {
            throw MailScriptingError.failed("Mail is not running")
        }
        let application = AccessibilityElement.application(processId: mail.processIdentifier)
        var window: AccessibilityElement?
        let deadline = ContinuousClock.now + windowWait
        while ContinuousClock.now < deadline {
            if let focused = try? application.focusedWindow(), (try? focused.title()) == subject {
                window = focused
                break
            }
            try await Task.sleep(for: windowPoll)
        }
        guard let window else {
            throw MailScriptingError.failed("the compose window did not open")
        }
        try await Task.sleep(for: bodySettle)
        guard
            let body = try window.firstDescendant(role: bodyRole, depth: bodySearchDepth),
            let selectAll = try application.menuCommand(key: "A"),
            let paste = try application.menuCommand(key: "V")
        else {
            throw MailScriptingError.failed("the compose window's body or its Edit menu could not be found")
        }
        let pasteboard = NSPasteboard.general
        let listKept = (pasteboard.pasteboardItems ?? []).map { item in
            let kept = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    kept.setData(data, forType: type)
                }
            }
            return kept
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(listKept)
        }
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        try body.focus()
        try selectAll.press()
        try paste.press()
        try await Task.sleep(for: bodySettle)
        guard isSending else {
            return
        }
        _ = try MailScripting.run("""
            tell application "Mail"
                set theStart to (current date) - 10
                send (first outgoing message whose id is \(Int(outgoingId) ?? -1))
                delay 2
                repeat with theDraft in (every message of drafts mailbox whose subject is \(quoted(subject)) and date received ≥ theStart)
                    delete theDraft
                end repeat
            end tell
            """)
    }

    /// A string as an AppleScript literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Changes the user asks Mail to make to a message, found in its inboxes by its `Message-ID`.
@MainActor
public enum MailActions {
    /// Mark a message read or unread.
    ///
    /// - Throws: `MailScriptingError`
    public static func markRead(messageId: String, isRead: Bool) throws {
        _ = try MailScripting.run("""
            tell application "Mail"
                set read status of (every message of inbox whose message id is \(MailDrafts.quoted(messageId))) to \(isRead)
            end tell
            """)
    }

    /// Flag a message, or take its flag off.
    ///
    /// - Throws: `MailScriptingError`
    public static func flag(messageId: String, isFlagged: Bool) throws {
        _ = try MailScripting.run("""
            tell application "Mail"
                set flagged status of (every message of inbox whose message id is \(MailDrafts.quoted(messageId))) to \(isFlagged)
            end tell
            """)
    }

    /// Open Mail's reply to an inbox message, for the user to write and send.
    ///
    /// - Throws: `MailScriptingError`
    public static func reply(messageId: String) throws {
        _ = try MailScripting.run("""
            tell application "Mail"
                set theMessages to (every message of inbox whose message id is \(MailDrafts.quoted(messageId)))
                if (count of theMessages) is 0 then error "the message is not in an inbox"
                reply (item 1 of theMessages) opening window yes
                activate
            end tell
            """)
    }

    /// The address that opens a message in Mail.
    public nonisolated static func url(messageId: String) -> URL? {
        let encoded = ("<" + messageId + ">").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".@-_"))) ?? messageId
        return URL(string: "message://" + encoded)
    }
}

