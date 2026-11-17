import Foundation

/// A message one agent sent another through rook, as the receiving agent reads it: a heading naming who
/// sent it, to which team and in which thread, the text, and how to answer. rook-link writes it so in an
/// agent's session, and Rookery the same way in a conversation of Raven's, so both read alike.
public struct RookMessage: Equatable, Sendable {
    private static let headingPattern = #"^Message from (.+?)(?: to team (\S+))?, through rook(?: \(thread (\S+)\))?:\n\n"#
    private static let answerMarker = "\n\nTo answer: "
    private static let noAnswerLine = "No answer wanted: do not reply to this message."
    private static let ravenPrefix = "Raven, "
    private static let quotedTitlePattern = #"\("([^"]+)"\)"#

    /// Who sent it, as the heading names them.
    public let sender: String
    public let team: String?
    public let thread: String?
    public let text: String

    public init(sender: String, team: String?, thread: String?, text: String) {
        self.sender = sender
        self.team = team
        self.thread = thread
        self.text = text
    }

    /// The sender as a person reads it: the title a sending agent goes by, Raven for Raven, else as named.
    public var senderName: String {
        if sender.hasPrefix(Self.ravenPrefix) {
            return "Raven"
        }
        if
            let range = sender.range(of: Self.quotedTitlePattern, options: .regularExpression),
            case let quoted = String(sender[range]).dropFirst(2).dropLast(2),
            !quoted.isEmpty
        {
            return String(quoted)
        }
        return sender
    }

    /// The message in a text an agent read, or nil when the text is not one.
    ///
    /// - Parameter text: what the agent read
    /// - Returns: the message, its heading and how to answer taken off
    public static func parse(_ text: String) -> RookMessage? {
        guard
            let regex = try? NSRegularExpression(pattern: headingPattern, options: []),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let senderRange = Range(match.range(at: 1), in: text),
            let headingRange = Range(match.range, in: text)
        else {
            return nil
        }
        var body = String(text[headingRange.upperBound...])
        if let answerRange = body.range(of: answerMarker, options: .backwards) {
            body = String(body[..<answerRange.lowerBound])
        } else if body.hasSuffix("\n\n" + noAnswerLine) {
            body = String(body.dropLast(noAnswerLine.count + 2))
        }
        return RookMessage(
            sender: String(text[senderRange]),
            team: Range(match.range(at: 2), in: text).map { String(text[$0]) },
            thread: Range(match.range(at: 3), in: text).map { String(text[$0]) },
            text: body
        )
    }

    /// A message as rook-link writes it for the agent it is for.
    ///
    /// - Parameters:
    ///   - senderId: the sending agent
    ///   - senderTitle: the title it goes by, if any
    ///   - text: what it says
    ///   - team: the team it went to, for a message to a whole team
    ///   - thread: the thread it belongs to
    ///   - isAnswerWanted: whether the sender wants an answer
    /// - Returns: the text the receiving agent reads
    public static func framed(
        senderId: String,
        senderTitle: String?,
        text: String,
        team: String?,
        thread: String?,
        isAnswerWanted: Bool
    ) -> String {
        let sender = "agent \(senderId)" + (senderTitle.map { " (\"\($0)\")" } ?? "")
        var heading = "Message from \(sender)" + (team.map { " to team \($0)" } ?? "") + ", through rook"
        if let thread {
            heading += " (thread \(thread))"
        }
        guard isAnswerWanted else {
            return "\(heading):\n\n\(text)\n\n\(noAnswerLine)"
        }
        let threadFlag = thread.map { " --thread \($0)" } ?? ""
        var footer = "To answer: rook message \(senderId)\(threadFlag) \"...\""
        if let team {
            footer += "; to answer the whole team: rook team send \(team)\(threadFlag) \"...\""
        }
        return "\(heading):\n\n\(text)\n\n\(footer)"
    }
}
