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

/// A draft opened in Mail for the user to read and send: never sent from here.
@MainActor
public enum MailDrafts {
    /// Open a new message in Mail, from an account, with its recipients, subject and text filled in.
    ///
    /// - Parameters:
    ///   - accountName: the account's name in Mail, which owns the sender address
    ///   - sender: the address to send from
    ///   - listTo: the recipients
    ///   - listCc: the copied recipients
    ///   - subject: the subject
    ///   - body: the text
    /// - Throws: `MailScriptingError`
    public static func open(
        accountName: String,
        sender: String,
        listTo: [String],
        listCc: [String],
        subject: String,
        body: String
    ) throws {
        let recipients = listTo.map { "make new to recipient at end of to recipients with properties {address:\(quoted($0))}" }
            + listCc.map { "make new cc recipient at end of cc recipients with properties {address:\(quoted($0))}" }
        let source = """
            tell application "Mail"
                set theMessage to make new outgoing message with properties {subject:\(quoted(subject)), content:\(quoted(body)), visible:true}
                tell theMessage
                    set sender to \(quoted(sender))
                    \(recipients.joined(separator: "\n            "))
                end tell
                activate
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

