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

/// Mail driven through AppleScript: the accounts it holds, and the changes Rookery asks of it. Every script
/// runs in an `osascript` of its own off the main thread, so Mail taking its time never holds up the app;
/// the first asks the user to let Rookery control Mail.
public enum MailScripting {
    /// The error AppleScript reports when the user declined, or has not yet allowed, control of an app.
    private static let notAllowedErrors: Set<Int> = [-1743, -1744]
    private static let fieldSeparator = "\u{1F}"
    private static let recordSeparator = "\u{1E}"
    private static let scriptRunner = URL(fileURLWithPath: "/usr/bin/osascript")

    /// The accounts Mail holds.
    ///
    /// - Throws: `MailScriptingError`
    public static func accounts() async throws -> [MailScriptAccount] {
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
        let output = try await run(source)
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
    public static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runWaiting(source) })
            }
        }
    }

    /// The lines of a script, inside `tell application "Mail"`, that set a variable to a message, or to
    /// `missing value` when Mail has no such message: taken by its id from the mailbox its path names, else
    /// from each of the account's mailboxes in turn, as Mail's scripting names a Gmail account's folders
    /// otherwise than its library does. Each try takes the message by its id, never searching a mailbox.
    ///
    /// - Parameters:
    ///   - place: where Mail keeps the message
    ///   - variable: the variable to set
    static func find(_ place: MailMessagePlace, into variable: String) -> String {
        let message = "«class mssg» id \(place.messageId)"
        return """
            set \(variable) to missing value
            set theAccount to account id \(quoted(place.accountId))
            try
                set \(variable) to \(message) of mailbox \(quoted(place.mailboxPath)) of theAccount
                get id of \(variable)
            on error
                set \(variable) to missing value
                repeat with theBox in every mailbox of theAccount
                    try
                        set \(variable) to \(message) of theBox
                        get id of \(variable)
                        exit repeat
                    on error
                        set \(variable) to missing value
                    end try
                end repeat
            end try
            """
    }

    /// A string as an AppleScript literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runWaiting(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = scriptRunner
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw MailScriptingError.failed("osascript does not start: \(error.localizedDescription)")
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = message
                .replacing(#/^\d+:\d+: (execution )?error: /#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let number = message.firstMatch(of: #/\((-?\d+)\)\s*$/#).flatMap { Int($0.1) } ?? 0
            if notAllowedErrors.contains(number) {
                throw MailScriptingError.notAllowed(reason)
            }
            throw MailScriptingError.failed(reason.isEmpty ? "osascript ended with \(process.terminationStatus)" : reason)
        }
        var text = String(decoding: result, as: UTF8.self)
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }
}

/// A mail written in Rookery handed to Mail to send, without a window, when the user presses Send in
/// Rookery; the draft Mail keeps of a scripted message then let go. A reply is made with Mail's own reply to
/// the message it answers, so it stays in its thread and quotes that message as Mail quotes any reply. What
/// the user wrote goes in as a signature made for the one message and removed after: Mail wraps text set as
/// a message's content in a quote of its own, as it does a page shared to it, so every client would show
/// the user's words as quoted, while a signature it places as written.
public enum MailDrafts {
    private static let bodySignaturePrefix = "Rookery Message "

    /// Send a mail through Mail, from an account, with its recipients, subject and text.
    ///
    /// - Parameters:
    ///   - sender: the address to send from
    ///   - original: where Mail keeps the message it answers; nil for a new message
    ///   - listTo: the recipients
    ///   - listCc: the copied recipients
    ///   - subject: the subject
    ///   - body: the text
    /// - Throws: `MailScriptingError`
    public static func send(
        sender: String,
        replyingTo original: MailMessagePlace?,
        listTo: [String],
        listCc: [String],
        subject: String,
        body: String
    ) async throws {
        let quoted = MailScripting.quoted
        let recipients = listTo.map { "make new to recipient at end of to recipients with properties {address:\(quoted($0))}" }
            + listCc.map { "make new cc recipient at end of cc recipients with properties {address:\(quoted($0))}" }
        let start = original.map { place in
            """
            \(MailScripting.find(place, into: "theOriginal"))
                if theOriginal is not missing value then
                    set theMessage to reply theOriginal opening window no
                else
                    set theMessage to make new outgoing message with properties {visible:false}
                end if
            """
        } ?? "set theMessage to make new outgoing message with properties {visible:false}"
        let signatureName = quoted(bodySignaturePrefix + UUID().uuidString)
        let source = """
            tell application "Mail"
                set theStart to (current date) - 5
                set theBody to make new signature with properties {name:\(signatureName), content:\(quoted(body))}
                try
                    \(start)
                    tell theMessage
                        set sender to \(quoted(sender))
                        set subject to \(quoted(subject))
                        delete every to recipient
                        delete every cc recipient
                        \(recipients.joined(separator: "\n                "))
                    end tell
                    set message signature of theMessage to theBody
                    delay 2
                    send theMessage
                on error theError number theNumber
                    delete theBody
                    error theError number theNumber
                end try
                delay 2
                delete theBody
                repeat with theDraft in (every message of drafts mailbox whose subject is \(quoted(subject)) and date received ≥ theStart)
                    delete theDraft
                end repeat
            end tell
            """
        _ = try await MailScripting.run(source)
    }

    /// Move drafts out of Mail's drafts into the trash.
    ///
    /// - Parameter listPlaces: where Mail keeps the drafts
    /// - Throws: `MailScriptingError`
    public static func trash(_ listPlaces: [MailMessagePlace]) async throws {
        guard !listPlaces.isEmpty else {
            return
        }
        let listDeletes = listPlaces.map { place in
            """
            \(MailScripting.find(place, into: "theDraft"))
                if theDraft is not missing value then delete theDraft
            """
        }
        _ = try await MailScripting.run("""
            tell application "Mail"
                \(listDeletes.joined(separator: "\n    "))
            end tell
            """)
    }
}

/// Changes the user asks Mail to make to a message, found where Mail keeps it.
public enum MailActions {
    /// Mark a message read or unread.
    ///
    /// - Throws: `MailScriptingError`
    public static func markRead(_ place: MailMessagePlace, isRead: Bool) async throws {
        _ = try await MailScripting.run("""
            tell application "Mail"
                \(MailScripting.find(place, into: "theMessage"))
                if theMessage is missing value then error "Mail's copy of the message cannot be found"
                set read status of theMessage to \(isRead)
            end tell
            """)
    }

    /// Flag a message, or take its flag off.
    ///
    /// - Throws: `MailScriptingError`
    public static func flag(_ place: MailMessagePlace, isFlagged: Bool) async throws {
        _ = try await MailScripting.run("""
            tell application "Mail"
                \(MailScripting.find(place, into: "theMessage"))
                if theMessage is missing value then error "Mail's copy of the message cannot be found"
                set flagged status of theMessage to \(isFlagged)
            end tell
            """)
    }
}
