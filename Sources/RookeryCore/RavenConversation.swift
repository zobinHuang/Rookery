import Foundation

/// One conversation with Raven: a Claude Code session the user can come back to and continue, its id the
/// session's, which is its agent's id on roost too.
public struct RavenConversation: Codable, Equatable, Identifiable, Sendable {
    /// The most characters of the first request a title keeps.
    public static let titleLength = 60

    public let id: String
    public var title: String
    public let createdAt: Date
    public var lastAt: Date
    /// The requests made in it, each a turn of the session.
    public var turnCount: Int
    /// What its turns cost, in US dollars.
    public var costUSD: Double

    public init(id: String, title: String, createdAt: Date, lastAt: Date, turnCount: Int, costUSD: Double) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastAt = lastAt
        self.turnCount = turnCount
        self.costUSD = costUSD
    }

    /// A title from the request that opened the conversation: its first line, cut at a word to fit.
    ///
    /// - Parameter request: the first request
    public static func title(of request: String) -> String {
        let firstLine = request
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard firstLine.count > titleLength else {
            return firstLine.isEmpty ? "New conversation" : firstLine
        }
        let cut = firstLine.prefix(titleLength)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Every conversation with Raven, the one last active first.
public struct RavenConversations: Codable, Equatable, Sendable {
    public private(set) var listConversations: [RavenConversation] = []

    public init(listConversations: [RavenConversation] = []) {
        self.listConversations = listConversations.sorted { $0.lastAt > $1.lastAt }
    }

    /// The conversation with an id, if there is one.
    public func conversation(_ conversationId: String) -> RavenConversation? {
        listConversations.first { $0.id == conversationId }
    }

    /// Open a conversation with its first request.
    ///
    /// - Parameters:
    ///   - conversationId: the session id chosen for it
    ///   - request: the first request, which titles it
    ///   - date: when it was made
    public mutating func open(_ conversationId: String, with request: String, at date: Date) {
        listConversations.removeAll { $0.id == conversationId }
        listConversations.insert(
            RavenConversation(
                id: conversationId,
                title: RavenConversation.title(of: request),
                createdAt: date,
                lastAt: date,
                turnCount: 1,
                costUSD: 0
            ),
            at: 0
        )
    }

    /// Note another request made in a conversation, which brings it to the top.
    public mutating func noteTurn(in conversationId: String, at date: Date) {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        var conversation = listConversations.remove(at: index)
        conversation.lastAt = date
        conversation.turnCount += 1
        listConversations.insert(conversation, at: 0)
    }

    /// Add what a turn cost to its conversation.
    public mutating func addCost(_ costUSD: Double, to conversationId: String) {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].costUSD += costUSD
    }

    public mutating func rename(_ conversationId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].title = trimmed
    }

    public mutating func remove(_ conversationId: String) {
        listConversations.removeAll { $0.id == conversationId }
    }
}
