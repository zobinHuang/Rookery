import Foundation

/// A group the user dragged agents into, kept on this Mac only.
public struct AgentGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    /// The agents in the group, in the order the user put them.
    public var listAgentIds: [String]
    public var isCollapsed: Bool

    public init(id: String = UUID().uuidString, title: String, listAgentIds: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.listAgentIds = listAgentIds
        self.isCollapsed = isCollapsed
    }
}

/// How the user grouped the agents in the sidebar. An agent is in at most one group; those in none show
/// under the groups, ordered by the fleet.
public struct AgentGroups: Codable, Equatable, Sendable {
    public static let fileName = "agent-groups.json"

    public private(set) var listGroups: [AgentGroup]

    public init(listGroups: [AgentGroup] = []) {
        self.listGroups = listGroups
    }

    /// The group an agent is in, or nil.
    public func groupId(of agentId: String) -> String? {
        listGroups.first { $0.listAgentIds.contains(agentId) }?.id
    }

    /// Add an empty group at the end.
    ///
    /// - Parameter title: its name
    /// - Returns: its id
    @discardableResult
    public mutating func addGroup(title: String) -> String {
        let group = AgentGroup(title: title)
        listGroups.append(group)
        return group.id
    }

    /// Rename a group; an empty name leaves it as it was.
    public mutating func rename(_ groupId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let groupIndex = index(of: groupId) else {
            return
        }
        listGroups[groupIndex].title = trimmed
    }

    /// Remove a group; its agents go back to being in none.
    public mutating func removeGroup(_ groupId: String) {
        listGroups.removeAll { $0.id == groupId }
    }

    /// Fold a group away, or open it.
    public mutating func toggleCollapsed(_ groupId: String) {
        guard let groupIndex = index(of: groupId) else {
            return
        }
        listGroups[groupIndex].isCollapsed.toggle()
    }

    /// Move an agent into a group, before another agent of it or at its end; or out of every group.
    ///
    /// - Parameters:
    ///   - agentId: the agent
    ///   - groupId: the group, or nil for none
    ///   - beforeAgentId: the agent to put it before, or nil for the end
    public mutating func move(_ agentId: String, to groupId: String?, before beforeAgentId: String? = nil) {
        guard agentId != beforeAgentId else {
            return
        }
        for groupIndex in listGroups.indices {
            listGroups[groupIndex].listAgentIds.removeAll { $0 == agentId }
        }
        guard let groupId, let groupIndex = index(of: groupId) else {
            return
        }
        let insertIndex = beforeAgentId
            .flatMap { listGroups[groupIndex].listAgentIds.firstIndex(of: $0) }
            ?? listGroups[groupIndex].listAgentIds.endIndex
        listGroups[groupIndex].listAgentIds.insert(agentId, at: insertIndex)
    }

    /// Move a group to just before another, or to the end.
    public mutating func moveGroup(_ groupId: String, before beforeGroupId: String?) {
        guard groupId != beforeGroupId, let groupIndex = index(of: groupId) else {
            return
        }
        let group = listGroups.remove(at: groupIndex)
        let insertIndex = beforeGroupId.flatMap(index(of:)) ?? listGroups.endIndex
        listGroups.insert(group, at: insertIndex)
    }

    /// Forget agents rookd no longer knows of.
    ///
    /// - Parameter setKnownIds: the agents rookd knows
    public mutating func prune(keeping setKnownIds: Set<String>) {
        for groupIndex in listGroups.indices {
            listGroups[groupIndex].listAgentIds.removeAll { !setKnownIds.contains($0) }
        }
    }

    private func index(of groupId: String) -> Int? {
        listGroups.firstIndex { $0.id == groupId }
    }
}
