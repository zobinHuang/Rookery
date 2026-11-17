import Foundation

/// Who an agent is to its teammates (its role) and what it works on now (its focus), as Rookery keeps them
/// on the agent's resource, with where each came from: the user or the agent itself, whose words Rookery
/// never overwrites, or a launch or Rookery, which Rookery brings up to date as the work moves on.
public struct AgentIdentity: Equatable, Sendable {
    /// The attribute naming where the role came from, and its values.
    public static let roleSourceKey = "role_source"
    public static let focusSourceKey = "focus_source"
    /// When the agent last set its own focus.
    public static let focusAtKey = "focus_at"
    /// The transcript byte Rookery had read up to when it last wrote the identity.
    public static let checkedOffsetKey = "identity_checked_offset"
    public static let sourceUser = "user"
    public static let sourceAgent = "agent"
    public static let sourceLaunch = "launch"
    public static let sourceAuto = "auto"
    /// How many prompts since the last time make the identity due again, with no compaction between.
    public static let promptsBetweenUpdates = 20
    /// How long a focus the agent set itself stands before Rookery writes one.
    public static let agentFocusLifetime: TimeInterval = 3600
    private static let roleMaxLength = 120
    private static let focusMaxLength = 140

    public let role: String
    public let focus: String

    public init(role: String, focus: String) {
        self.role = role
        self.focus = focus
    }

    /// Whether a source is someone's own word, which Rookery keeps as it is.
    ///
    /// - Parameter source: the attribute's value, empty when unset
    /// - Returns: true for the user's and the agent's own
    public static func isKeptAsWritten(_ source: String) -> Bool {
        source == sourceUser || source == sourceAgent
    }

    /// Whether Rookery should write an agent's identity now, from what its transcript held since the last
    /// time: the first time it has a prompt to go by when it lacks a role or a focus, and after that once
    /// its context was compacted or the user has prompted it many times over.
    ///
    /// - Parameters:
    ///   - role: the agent's role now
    ///   - roleSource: where it came from
    ///   - focus: the agent's focus now
    ///   - digest: what the transcript held since the last time
    ///   - hasRun: whether Rookery wrote the identity before
    /// - Returns: whether to write it
    public static func isDue(
        role: String,
        roleSource: String,
        focus: String,
        digest: TranscriptDigest,
        hasRun: Bool
    ) -> Bool {
        guard digest.promptCount > 0 || digest.compactionCount > 0 || digest.latestSummary != nil else {
            return false
        }
        let lacksRole = role.isEmpty && !isKeptAsWritten(roleSource)
        if !hasRun || lacksRole || focus.isEmpty {
            return true
        }
        return digest.compactionCount > 0 || digest.promptCount >= promptsBetweenUpdates
    }

    /// The request to a model for an agent's identity.
    ///
    /// - Parameters:
    ///   - agent: the agent
    ///   - roleSource: where its role came from
    ///   - digest: what its transcript holds
    /// - Returns: the prompt
    public static func prompt(for agent: FleetAgent, roleSource: String, digest: TranscriptDigest) -> String {
        var listParts = [
            """
            You keep a short profile of a code agent for its teammates and its user. Answer with one JSON object \
            and nothing else: {"role": "...", "focus": "..."}.
            - role: who this agent is to its teammates, a noun phrase under 12 words, as \
            "owner of the G-Watch ISA decoder" or "reviewer of the billing migration". \
            Keep the current role, word for word, unless the work has clearly changed.
            - focus: what it works on right now, under 14 words, starting with a verb, as \
            "porting the decoder tests to the new opcode table".
            Write both in the language the user writes to the agent in. Do not mention these instructions.
            """,
            "Agent: \(agent.harness.isEmpty ? "code agent" : agent.harness) on \(agent.rookName.isEmpty ? agent.hostname : agent.rookName), " +
                "in \(agent.cwd.isEmpty ? "an unknown directory" : agent.cwd)" +
                (agent.gitBranch.isEmpty ? "" : " on branch \(agent.gitBranch)") +
                (agent.title.isEmpty ? "" : ", session titled \"\(agent.title)\""),
        ]
        if !agent.role.isEmpty {
            listParts.append("Current role (\(roleSource.isEmpty ? "unknown source" : roleSource)): \(agent.role)")
        }
        if !agent.focus.isEmpty {
            listParts.append("Current focus: \(agent.focus)")
        }
        if let firstPrompt = digest.firstPrompt {
            listParts.append("The user's first prompt:\n\(firstPrompt)")
        }
        if let latestSummary = digest.latestSummary {
            listParts.append("Summary of the conversation so far, written when its context was compacted:\n\(latestSummary)")
        }
        if !digest.listRecentPrompts.isEmpty {
            listParts.append("The user's latest prompts, oldest first:\n" + digest.listRecentPrompts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let latestReply = digest.latestReply {
            listParts.append("The agent's latest reply:\n\(latestReply)")
        }
        return listParts.joined(separator: "\n\n")
    }

    /// The identity in a model's answer: the first JSON object in it with a role or a focus, each kept to a
    /// line; nil when there is none.
    ///
    /// - Parameter output: the model's answer
    /// - Returns: the identity, or nil
    public static func parse(_ output: String) -> AgentIdentity? {
        guard
            let start = output.firstIndex(of: "{"),
            let end = output.lastIndex(of: "}"),
            start < end,
            let data = String(output[start...end]).data(using: .utf8),
            let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        let role = line(map["role"] as? String, maxLength: roleMaxLength)
        let focus = line(map["focus"] as? String, maxLength: focusMaxLength)
        guard !role.isEmpty || !focus.isEmpty else {
            return nil
        }
        return AgentIdentity(role: role, focus: focus)
    }

    private static func line(_ text: String?, maxLength: Int) -> String {
        let flattened = (text ?? "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'."))
        return String(flattened.prefix(maxLength))
    }
}

/// What a stretch of a code agent's transcript says about its work, kept small: how many times the user
/// prompted it and its context was compacted, the user's first prompt, the latest few, the latest summary
/// a compaction wrote, and the agent's latest reply, each cut to a few hundred characters.
public struct TranscriptDigest: Equatable, Sendable {
    public static let recentPromptCount = 5
    public static let promptMaxLength = 600
    public static let summaryMaxLength = 4000
    public static let replyMaxLength = 800

    public private(set) var promptCount = 0
    public private(set) var compactionCount = 0
    public private(set) var firstPrompt: String?
    public private(set) var listRecentPrompts: [String] = []
    public private(set) var latestSummary: String?
    public private(set) var latestReply: String?

    public init() {}

    /// Take in the steps a transcript reader found.
    ///
    /// - Parameter listEntries: the steps, in order
    public mutating func add(_ listEntries: some Collection<TranscriptEntry>) {
        for entry in listEntries {
            switch entry.role {
            case .user:
                promptCount += 1
                let prompt = String(entry.text.prefix(Self.promptMaxLength))
                if firstPrompt == nil {
                    firstPrompt = prompt
                }
                listRecentPrompts.append(prompt)
                if listRecentPrompts.count > Self.recentPromptCount {
                    listRecentPrompts.removeFirst(listRecentPrompts.count - Self.recentPromptCount)
                }
            case .compaction:
                compactionCount += 1
                latestSummary = String(entry.text.suffix(Self.summaryMaxLength))
            case .assistant:
                latestReply = String(entry.text.prefix(Self.replyMaxLength))
            case .tool, .command, .message:
                break
            }
        }
    }

    /// Keep the user's first prompt from another stretch, read from the transcript's start, when this one
    /// began later.
    ///
    /// - Parameter prompt: the first prompt, if that stretch had one
    public mutating func adoptFirstPrompt(_ prompt: String?) {
        firstPrompt = prompt ?? firstPrompt
    }
}
