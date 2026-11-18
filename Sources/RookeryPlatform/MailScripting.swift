import Foundation
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

/// A mail written in Rookery handed to Mail to send, without a window, when the user presses Send in
/// Rookery; the draft Mail keeps of a scripted message then let go. A reply is made with Mail's own reply to the message it
/// answers, so it stays in its thread; its quoted text is replaced by what the user wrote.
@MainActor
public enum MailDrafts {
    /// Send a mail through Mail, from an account, with its recipients, subject and text.
    ///
    /// - Parameters:
    ///   - sender: the address to send from
    ///   - replyingTo: the `Message-ID` of the message it answers, found in the inboxes; nil, or not found,
    ///     for a new message
    ///   - listTo: the recipients
    ///   - listCc: the copied recipients
    ///   - subject: the subject
    ///   - body: the text
    /// - Throws: `MailScriptingError`
    public static func send(
        sender: String,
        replyingTo messageId: String?,
        listTo: [String],
        listCc: [String],
        subject: String,
        body: String
    ) throws {
        let recipients = listTo.map { "make new to recipient at end of to recipients with properties {address:\(quoted($0))}" }
            + listCc.map { "make new cc recipient at end of cc recipients with properties {address:\(quoted($0))}" }
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
                send theMessage
                delay 2
                repeat with theDraft in (every message of drafts mailbox whose subject is \(quoted(subject)) and date received ≥ theStart)
                    delete theDraft
                end repeat
            end tell
            """
        _ = try MailScripting.run(source)
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

}

