import Foundation

/// A team the user dragged agents into, kept on this Mac only.
public struct AgentTeam: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    /// The agents in the team, in the order the user put them.
    public var listAgentIds: [String]
    public var isCollapsed: Bool

    public init(id: String = UUID().uuidString, title: String, listAgentIds: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.listAgentIds = listAgentIds
        self.isCollapsed = isCollapsed
    }
}

/// How the user teamed the agents in the sidebar. An agent is in at most one team; those in none show
/// under the teams, ordered by the fleet.
public struct AgentTeams: Codable, Equatable, Sendable {
    public static let fileName = "agent-teams.json"
    /// Where the teams were kept when they were called groups, read once to carry them over.
    public static let legacyFileName = "agent-groups.json"

    enum CodingKeys: String, CodingKey {
        case listTeams
        case legacyListTeams = "listGroups"
    }

    public private(set) var listTeams: [AgentTeam]

    public init(listTeams: [AgentTeam] = []) {
        self.listTeams = listTeams
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listTeams = try container.decodeIfPresent([AgentTeam].self, forKey: .listTeams)
            ?? container.decodeIfPresent([AgentTeam].self, forKey: .legacyListTeams)
            ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(listTeams, forKey: .listTeams)
    }

    /// The team an agent is in, or nil.
    public func teamId(of agentId: String) -> String? {
        listTeams.first { $0.listAgentIds.contains(agentId) }?.id
    }

    /// Add an empty team at the end.
    ///
    /// - Parameter title: its name
    /// - Returns: its id
    @discardableResult
    public mutating func addTeam(title: String) -> String {
        let team = AgentTeam(title: title)
        listTeams.append(team)
        return team.id
    }

    /// Rename a team; an empty name leaves it as it was.
    public mutating func rename(_ teamId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let teamIndex = index(of: teamId) else {
            return
        }
        listTeams[teamIndex].title = trimmed
    }

    /// Remove a team; its agents go back to being in none.
    public mutating func removeTeam(_ teamId: String) {
        listTeams.removeAll { $0.id == teamId }
    }

    /// Fold a team away, or open it.
    public mutating func toggleCollapsed(_ teamId: String) {
        guard let teamIndex = index(of: teamId) else {
            return
        }
        listTeams[teamIndex].isCollapsed.toggle()
    }

    /// Move an agent into a team, before another agent of it or at its end; or out of every team.
    ///
    /// - Parameters:
    ///   - agentId: the agent
    ///   - teamId: the team, or nil for none
    ///   - beforeAgentId: the agent to put it before, or nil for the end
    public mutating func move(_ agentId: String, to teamId: String?, before beforeAgentId: String? = nil) {
        guard agentId != beforeAgentId else {
            return
        }
        for teamIndex in listTeams.indices {
            listTeams[teamIndex].listAgentIds.removeAll { $0 == agentId }
        }
        guard let teamId, let teamIndex = index(of: teamId) else {
            return
        }
        let insertIndex = beforeAgentId
            .flatMap { listTeams[teamIndex].listAgentIds.firstIndex(of: $0) }
            ?? listTeams[teamIndex].listAgentIds.endIndex
        listTeams[teamIndex].listAgentIds.insert(agentId, at: insertIndex)
    }

    /// Move a team to just before another, or to the end.
    public mutating func moveTeam(_ teamId: String, before beforeTeamId: String?) {
        guard teamId != beforeTeamId, let teamIndex = index(of: teamId) else {
            return
        }
        let team = listTeams.remove(at: teamIndex)
        let insertIndex = beforeTeamId.flatMap(index(of:)) ?? listTeams.endIndex
        listTeams.insert(team, at: insertIndex)
    }

    /// Forget agents roost no longer knows of.
    ///
    /// - Parameter setKnownIds: the agents roost knows
    public mutating func prune(keeping setKnownIds: Set<String>) {
        for teamIndex in listTeams.indices {
            listTeams[teamIndex].listAgentIds.removeAll { !setKnownIds.contains($0) }
        }
    }

    private func index(of teamId: String) -> Int? {
        listTeams.firstIndex { $0.id == teamId }
    }
}
