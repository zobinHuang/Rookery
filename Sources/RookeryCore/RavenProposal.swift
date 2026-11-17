import Foundation

/// Something Raven would do to another agent, or on a rook, put to the user rather than done:
/// `rook-client propose` prints it, and it arrives in Raven's output as the result of that command.
public struct RavenProposal: Codable, Equatable, Identifiable, Sendable {
    /// What Raven would do.
    public enum Action: String, Codable, Sendable {
        /// Send the agent a prompt.
        case message
        /// Stop what the agent is doing.
        case interrupt
        /// Answer the agent's approval prompt with `choice`.
        case approve
        /// Start a new session on `rook`, in `cwd`, with `text` as its first prompt, the playbook and skills
        /// installed first, its role, and the teams it joins.
        case spawn
        /// Put the agent in `team`, with `duty` there.
        case join
        /// Take the agent out of `team`.
        case leave
        /// Make `team`, named `teamTitle`, toward `goal`.
        case createTeam = "create_team"
    }

    /// The answers to an approval prompt Raven may propose.
    public static let approveOnce = "once"
    public static let approveDeny = "deny"

    public let id: String
    public let action: Action
    /// The agent it is for; nil for a new session.
    public let agentId: String?
    /// What the agent was called when Raven proposed it, or the new session's harness and rook.
    public let agentTitle: String
    /// The text to send, or the new session's first prompt; empty for none.
    public let text: String
    /// For an approval: `once` or `deny`.
    public let choice: String?
    /// For a new session: the rook, the directory there and the harness.
    public let rook: String?
    public let cwd: String?
    public let harness: String?
    public let playbookId: String?
    public let listSkillIds: [String]
    public let role: String
    /// For a new session, the teams it joins; for a team proposal, nothing.
    public let listTeams: [LaunchTeam]
    /// For a team proposal: the team, its name and goal, and the agent's duty in it.
    public let team: String?
    public let teamTitle: String?
    public let duty: String
    public let goal: String

    enum CodingKeys: String, CodingKey {
        case playbookId = "playbook"
        case listSkillIds = "skills"
        case role
        case listTeams = "teams"
        case team
        case teamTitle = "team_title"
        case duty
        case goal
        case id
        case action
        case agentId = "agent"
        case agentTitle = "agent_title"
        case text
        case choice
        case rook
        case cwd
        case harness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(Action.self, forKey: .action)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentTitle = try container.decodeIfPresent(String.self, forKey: .agentTitle) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
        rook = try container.decodeIfPresent(String.self, forKey: .rook)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        harness = try container.decodeIfPresent(String.self, forKey: .harness)
        playbookId = try container.decodeIfPresent(String.self, forKey: .playbookId)
        listSkillIds = try container.decodeIfPresent([String].self, forKey: .listSkillIds) ?? []
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        let listJoins = try container.decodeIfPresent([[String: String]].self, forKey: .listTeams) ?? []
        listTeams = listJoins.compactMap { mapJoin in
            mapJoin["team"].map { LaunchTeam(teamId: $0, duty: mapJoin["duty"] ?? "") }
        }
        team = try container.decodeIfPresent(String.self, forKey: .team)
        teamTitle = try container.decodeIfPresent(String.self, forKey: .teamTitle)
        duty = try container.decodeIfPresent(String.self, forKey: .duty) ?? ""
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encode(agentTitle, forKey: .agentTitle)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(choice, forKey: .choice)
        try container.encodeIfPresent(rook, forKey: .rook)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(harness, forKey: .harness)
        try container.encodeIfPresent(playbookId, forKey: .playbookId)
        try container.encode(listSkillIds, forKey: .listSkillIds)
        try container.encode(role, forKey: .role)
        try container.encode(listTeams.map { ["team": $0.teamId, "duty": $0.duty] }, forKey: .listTeams)
        try container.encodeIfPresent(team, forKey: .team)
        try container.encodeIfPresent(teamTitle, forKey: .teamTitle)
        try container.encode(duty, forKey: .duty)
        try container.encode(goal, forKey: .goal)
    }

    /// The marker the proposal's line starts with in the command's output.
    private static let marker = #"{"proposal":"#

    /// The proposals in one line of Raven's output or history: those a command's result printed.
    ///
    /// - Parameter line: one JSON line, as the stream-json output and the transcript hold it
    public static func proposals(in line: Data) -> [RavenProposal] {
        guard
            let object = try? JSONDecoder().decode(JSONValue.self, from: line),
            object["type"]?.stringValue == "user",
            case .array(let listBlocks) = object["message"]?["content"]
        else {
            return []
        }
        return listBlocks
            .filter { $0["type"]?.stringValue == "tool_result" }
            .flatMap { block in resultText(of: block).split(whereSeparator: \.isNewline) }
            .filter { $0.hasPrefix(marker) }
            .compactMap { proposalLine in
                try? JSONDecoder().decode([String: RavenProposal].self, from: Data(proposalLine.utf8))["proposal"]
            }
    }

    private static func resultText(of block: JSONValue) -> String {
        switch block["content"] {
        case .string(let text):
            return text
        case .array(let listParts):
            return listParts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default:
            return ""
        }
    }
}

/// What the user decided about a proposal, and whether Raven has heard.
public struct RavenDecision: Codable, Equatable, Sendable {
    /// The decision itself.
    public enum Outcome: Codable, Equatable, Sendable {
        /// Carried out: it went to its agent or rook as a delivery roost tracks.
        case sent(deliveryId: String)
        case rejected
        /// Carried out on roost at once, as a change to a team.
        case done
    }

    public let outcome: Outcome
    public let decidedAt: Date
    /// Whether Raven was told, with the request after it.
    public var isReported: Bool

    public init(outcome: Outcome, decidedAt: Date, isReported: Bool = false) {
        self.outcome = outcome
        self.decidedAt = decidedAt
        self.isReported = isReported
    }
}
