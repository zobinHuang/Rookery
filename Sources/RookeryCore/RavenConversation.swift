import Foundation

/// Where a conversation with Raven was started, which decides where it is listed: the Rookmaster board
/// lists its own, the Mail page those beside each thread, and the launcher's open from it.
public enum RavenOrigin: String, Codable, CaseIterable, Sendable {
    case board
    case mail
    case launcher
}

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
    /// What the user decided about each of Raven's proposals in it, by the proposal's id.
    public var mapDecisions: [String: RavenDecision]
    /// The code agent it runs on, `claude` or `codex`; one conversation keeps to one.
    public var engine: String
    /// For a conversation on Codex, the thread its turns resume.
    public var codexThreadId: String?
    /// Where the title came from: nil for the first request, `generated` once Rookery wrote one from the
    /// conversation, `user` once the user named it.
    public var titleSource: String?
    /// The mail the conversation is about, when it was opened from the Mail page beside a message.
    public var mailMessageId: Int?
    /// Where it was started.
    public var origin: RavenOrigin

    public static let engineClaude = "claude"
    public static let engineCodex = "codex"
    public static let titleSourceGenerated = "generated"
    public static let titleSourceUser = "user"
    /// The most characters a written title keeps.
    public static let writtenTitleLength = 48
    /// The tags the model puts the title it writes between.
    private static let titleOpenTag = "<title>"
    private static let titleCloseTag = "</title>"
    private static let excerptLength = 600

    enum CodingKeys: String, CodingKey {
        case origin
        case mailMessageId
        case engine
        case codexThreadId
        case titleSource
        case id
        case title
        case createdAt
        case lastAt
        case turnCount
        case costUSD
        case mapDecisions
    }

    public init(
        id: String,
        title: String,
        createdAt: Date,
        lastAt: Date,
        turnCount: Int,
        costUSD: Double,
        mapDecisions: [String: RavenDecision] = [:],
        engine: String = RavenConversation.engineClaude,
        codexThreadId: String? = nil,
        origin: RavenOrigin = .board
    ) {
        self.origin = origin
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastAt = lastAt
        self.turnCount = turnCount
        self.costUSD = costUSD
        self.mapDecisions = mapDecisions
        self.engine = engine
        self.codexThreadId = codexThreadId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastAt = try container.decode(Date.self, forKey: .lastAt)
        turnCount = try container.decode(Int.self, forKey: .turnCount)
        costUSD = try container.decode(Double.self, forKey: .costUSD)
        mapDecisions = try container.decodeIfPresent([String: RavenDecision].self, forKey: .mapDecisions) ?? [:]
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? Self.engineClaude
        codexThreadId = try container.decodeIfPresent(String.self, forKey: .codexThreadId)
        titleSource = try container.decodeIfPresent(String.self, forKey: .titleSource)
        mailMessageId = try container.decodeIfPresent(Int.self, forKey: .mailMessageId)
        origin = try container.decodeIfPresent(RavenOrigin.self, forKey: .origin) ?? (mailMessageId == nil ? .board : .mail)
    }

    /// The request to a model for a conversation's title, from its first request and Raven's answer.
    public static func titlePrompt(request: String, answer: String) -> String {
        """
        Write a title for this conversation between a user and their assistant, as a chat app lists it: \
        3 to 7 words naming what it is about, in the language the user wrote in, no quotes, no period. \
        Answer with the title alone inside <title></title>, and nothing else: no thinking, no explanation.

        The user: \(request.prefix(excerptLength))

        The assistant: \(answer.prefix(excerptLength))
        """
    }

    /// A title as a model wrote it, kept to its first line, quotes and a trailing period taken off and
    /// cut to fit; nil when nothing is left.
    public static func writtenTitle(of answer: String) -> String? {
        var tagged: String?
        if let open = answer.range(of: titleOpenTag), let close = answer.range(of: titleCloseTag, range: open.upperBound..<answer.endIndex) {
            tagged = String(answer[open.upperBound..<close.lowerBound])
        }
        let lastLine = answer
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let firstLine = (tagged ?? lastLine)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine
            .replacingOccurrences(of: "Title:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”‘’「」《》.。#*"))
        guard !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(writtenTitleLength))
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

    /// Every conversation about any message of a mail thread, the latest first.
    ///
    /// - Parameter listMessageIds: the thread's messages
    public func conversations(aboutMail listMessageIds: [Int]) -> [RavenConversation] {
        let setIds = Set(listMessageIds)
        return listConversations.filter { $0.mailMessageId.map(setIds.contains) ?? false }
    }

    /// The latest conversation about any message of a mail thread, if there is one.
    ///
    /// - Parameter listMessageIds: the thread's messages
    public func conversation(aboutMail listMessageIds: [Int]) -> RavenConversation? {
        let setIds = Set(listMessageIds)
        return listConversations.first { $0.mailMessageId.map(setIds.contains) ?? false }
    }

    /// Tie a conversation to the mail it is about.
    public mutating func link(_ conversationId: String, toMail messageId: Int) {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].mailMessageId = messageId
    }

    /// Open a conversation with its first request.
    ///
    /// - Parameters:
    ///   - conversationId: the session id chosen for it
    ///   - request: the first request, which titles it
    ///   - date: when it was made
    public mutating func open(
        _ conversationId: String,
        with request: String,
        at date: Date,
        engine: String = RavenConversation.engineClaude,
        origin: RavenOrigin = .board
    ) {
        listConversations.removeAll { $0.id == conversationId }
        listConversations.insert(
            RavenConversation(
                id: conversationId,
                title: RavenConversation.title(of: request),
                createdAt: date,
                lastAt: date,
                turnCount: 1,
                costUSD: 0,
                engine: engine,
                origin: origin
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

    /// Note the Codex thread a conversation's first turn opened.
    public mutating func noteCodexThread(_ threadId: String, in conversationId: String) {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].codexThreadId = threadId
    }

    public mutating func rename(_ conversationId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].title = trimmed
        listConversations[index].titleSource = RavenConversation.titleSourceUser
    }

    /// Give a conversation the title Rookery wrote, unless it has one written or the user's already.
    ///
    /// - Returns: whether the title changed
    @discardableResult
    public mutating func retitle(_ conversationId: String, to title: String) -> Bool {
        guard
            let index = listConversations.firstIndex(where: { $0.id == conversationId }),
            listConversations[index].titleSource == nil
        else {
            return false
        }
        listConversations[index].title = title
        listConversations[index].titleSource = RavenConversation.titleSourceGenerated
        return true
    }

    /// Record what the user decided about a proposal.
    public mutating func decide(_ proposalId: String, in conversationId: String, _ decision: RavenDecision) {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }
        listConversations[index].mapDecisions[proposalId] = decision
    }

    /// The decisions in a conversation Raven has not heard of, which go with the next request, now marked
    /// as told.
    public mutating func takeUnreportedDecisions(in conversationId: String) -> [String: RavenDecision] {
        guard let index = listConversations.firstIndex(where: { $0.id == conversationId }) else {
            return [:]
        }
        let mapUnreported = listConversations[index].mapDecisions.filter { !$0.value.isReported }
        for proposalId in mapUnreported.keys {
            listConversations[index].mapDecisions[proposalId]?.isReported = true
        }
        return mapUnreported
    }

    public mutating func remove(_ conversationId: String) {
        listConversations.removeAll { $0.id == conversationId }
    }
}
