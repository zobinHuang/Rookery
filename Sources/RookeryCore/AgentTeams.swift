import Foundation

/// A team of agents, as the sidebar lays it out: roost holds the team and who is in it; this Mac keeps
/// the order of its agents and whether it is folded.
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

/// The teams as the sidebar lays them out. roost holds the teams and their members, which `adopt` takes
/// in; this Mac keeps their order, the order of the agents in each, and which are folded. An agent may be
/// in several teams; those in none show under the teams, ordered by the fleet.
public struct AgentTeams: Codable, Equatable, Sendable {
    public static let fileName = "agent-teams.json"
    /// Where the teams were kept when they were called groups, read once to carry them over.
    public static let legacyFileName = "agent-groups.json"

    enum CodingKeys: String, CodingKey {
        case listTeams
        case legacyListTeams = "listGroups"
        case isOnRoost
    }

    public private(set) var listTeams: [AgentTeam]
    /// Whether the teams made on this Mac before roost held teams were carried over to it.
    public private(set) var isOnRoost: Bool

    public init(listTeams: [AgentTeam] = [], isOnRoost: Bool = false) {
        self.listTeams = listTeams
        self.isOnRoost = isOnRoost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listTeams = try container.decodeIfPresent([AgentTeam].self, forKey: .listTeams)
            ?? container.decodeIfPresent([AgentTeam].self, forKey: .legacyListTeams)
            ?? []
        isOnRoost = try container.decodeIfPresent(Bool.self, forKey: .isOnRoost) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(listTeams, forKey: .listTeams)
        try container.encode(isOnRoost, forKey: .isOnRoost)
    }

    /// The first team an agent is in, or nil.
    public func teamId(of agentId: String) -> String? {
        listTeams.first { $0.listAgentIds.contains(agentId) }?.id
    }

    /// Every team an agent is in, in the sidebar's order.
    public func teamIds(of agentId: String) -> [String] {
        listTeams.filter { $0.listAgentIds.contains(agentId) }.map(\.id)
    }

    /// Add an empty team at the end.
    ///
    /// - Parameters:
    ///   - title: its name
    ///   - teamId: its id, a fresh one by default
    /// - Returns: its id
    @discardableResult
    public mutating func addTeam(title: String, id teamId: String = UUID().uuidString.lowercased()) -> String {
        listTeams.append(AgentTeam(id: teamId, title: title))
        return teamId
    }

    /// Put an agent in a team, before another agent of it or at its end, leaving it in its other teams;
    /// one already in the team moves within it.
    public mutating func join(_ agentId: String, to teamId: String, before beforeAgentId: String? = nil) {
        guard agentId != beforeAgentId, let teamIndex = index(of: teamId) else {
            return
        }
        listTeams[teamIndex].listAgentIds.removeAll { $0 == agentId }
        let insertIndex = beforeAgentId
            .flatMap { listTeams[teamIndex].listAgentIds.firstIndex(of: $0) }
            ?? listTeams[teamIndex].listAgentIds.endIndex
        listTeams[teamIndex].listAgentIds.insert(agentId, at: insertIndex)
    }

    /// Take an agent out of one team.
    public mutating func leave(_ agentId: String, from teamId: String) {
        guard let teamIndex = index(of: teamId) else {
            return
        }
        listTeams[teamIndex].listAgentIds.removeAll { $0 == agentId }
    }

    /// Take in the teams roost holds: each keeps its place, its fold and the order of its agents here, with
    /// its name and members as roost has them; a member new to it goes at its end, a team new here at the
    /// end, and a team roost no longer holds is dropped.
    ///
    /// - Parameter listTeamResources: roost's teams, each with its `members` by agent id
    public mutating func adopt(_ listTeamResources: [FleetResource]) {
        let mapRoost = Dictionary(listTeamResources.map { ($0.id, $0) }) { first, _ in first }
        listTeams = listTeams.compactMap { team in
            guard let resource = mapRoost[team.id] else {
                return nil
            }
            var adopted = team
            let listMembers = Self.memberIds(of: resource)
            adopted.title = resource.name
            adopted.listAgentIds = team.listAgentIds.filter(listMembers.contains)
                + listMembers.filter { !team.listAgentIds.contains($0) }
            return adopted
        }
        let setKnown = Set(listTeams.map(\.id))
        for resource in listTeamResources where !setKnown.contains(resource.id) {
            listTeams.append(AgentTeam(id: resource.id, title: resource.name, listAgentIds: Self.memberIds(of: resource)))
        }
    }

    /// Note that the teams made here were carried over to roost.
    public mutating func noteOnRoost() {
        isOnRoost = true
    }

    /// A roost team's members, by agent id, in the order they joined.
    public static func memberIds(of resource: FleetResource) -> [String] {
        guard case .object(let mapMembers) = resource.mapAttributes["members"] else {
            return []
        }
        return mapMembers.keys.sorted { first, second in
            let firstJoined = mapMembers[first]?["joined_at"]?.stringValue ?? ""
            let secondJoined = mapMembers[second]?["joined_at"]?.stringValue ?? ""
            return (firstJoined, first) < (secondJoined, second)
        }
    }

    /// A member's duty in a roost team, or empty.
    public static func duty(of agentId: String, in resource: FleetResource) -> String {
        resource.mapAttributes["members"]?[agentId]?["duty"]?.stringValue ?? ""
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

    /// Move a team to just before another, or to the end.
    public mutating func moveTeam(_ teamId: String, before beforeTeamId: String?) {
        guard teamId != beforeTeamId, let teamIndex = index(of: teamId) else {
            return
        }
        let team = listTeams.remove(at: teamIndex)
        let insertIndex = beforeTeamId.flatMap(index(of:)) ?? listTeams.endIndex
        listTeams.insert(team, at: insertIndex)
    }

    private func index(of teamId: String) -> Int? {
        listTeams.firstIndex { $0.id == teamId }
    }
}
