import CoreGraphics
import Foundation

/// Which windows MuxShots manages and how they are grouped; a window belongs to at most one group.
public struct Workspace: Codable, Equatable, Sendable {
    private static let defaultGroupNamePrefix = "Group "

    private enum CodingKeys: String, CodingKey {
        case listGroups
        case setActiveGroupIds
    }

    /// The groups in creation order; a group with no members is removed.
    public private(set) var listGroups: [WindowGroup] = []
    /// The groups currently shown, at most one per display, with other groups' windows on those displays
    /// hidden; empty when no group is active.
    public private(set) var setActiveGroupIds: Set<GroupId> = []

    public init(listGroups: [WindowGroup] = [], setActiveGroupIds: Set<GroupId> = []) {
        self.listGroups = listGroups.filter { !$0.listMembers.isEmpty }
        self.setActiveGroupIds = setActiveGroupIds.filter { groupId in
            self.listGroups.contains { $0.groupId == groupId }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            listGroups: try container.decode([WindowGroup].self, forKey: .listGroups),
            setActiveGroupIds: try container.decodeIfPresent(Set<GroupId>.self, forKey: .setActiveGroupIds) ?? []
        )
    }

    /// Whether a group is currently shown.
    public func isActive(_ groupId: GroupId) -> Bool {
        setActiveGroupIds.contains(groupId)
    }

    /// The groups currently shown, in creation order.
    public var listActiveGroups: [WindowGroup] {
        listGroups.filter { setActiveGroupIds.contains($0.groupId) }
    }

    /// Show a group in place of the active groups it displaces from its displays.
    ///
    /// - Parameters:
    ///   - groupId: the group to show
    ///   - setDisplacedIds: the active groups that shared a display with it
    public mutating func activate(_ groupId: GroupId, displacing setDisplacedIds: Set<GroupId>) {
        guard listGroups.contains(where: { $0.groupId == groupId }) else {
            return
        }
        setActiveGroupIds.subtract(setDisplacedIds)
        setActiveGroupIds.insert(groupId)
    }

    /// Leave group mode: no group is active.
    public mutating func deactivateAll() {
        setActiveGroupIds.removeAll()
    }

    /// Record a group's front-to-back order of members, ignoring identifiers that are not its members.
    public mutating func recordStack(of groupId: GroupId, frontToBack listWindowIds: [WindowId]) {
        guard let groupIndex = listGroups.firstIndex(where: { $0.groupId == groupId }) else {
            return
        }
        let setMemberIds = Set(listGroups[groupIndex].listMembers.map(\.windowId))
        listGroups[groupIndex].listStackIds = listWindowIds.filter { setMemberIds.contains($0) }
    }

    /// A group by name, ignoring case, or by its 1-based position.
    public func group(named nameOrPosition: String) -> WindowGroup? {
        if let group = listGroups.first(where: { $0.name.caseInsensitiveCompare(nameOrPosition) == .orderedSame }) {
            return group
        }
        guard let position = Int(nameOrPosition), listGroups.indices.contains(position - 1) else {
            return nil
        }
        return listGroups[position - 1]
    }

    /// Every managed window, in group order.
    public var listManagedWindows: [ManagedWindow] {
        listGroups.flatMap(\.listMembers)
    }

    /// Whether MuxShots manages a window.
    public func isManaged(_ windowId: WindowId) -> Bool {
        group(containing: windowId) != nil
    }

    /// The group a window belongs to.
    ///
    /// - Returns: the group, or nil if the window is not managed
    public func group(containing windowId: WindowId) -> WindowGroup? {
        listGroups.first { group in
            group.listMembers.contains { $0.windowId == windowId }
        }
    }

    /// Put a window into a group, taking it out of any group it was in.
    ///
    /// - Parameters:
    ///   - window: the window to manage
    ///   - groupId: the destination group, or nil for a new group
    /// - Returns: the destination group's identifier
    @discardableResult
    public mutating func adopt(_ window: ManagedWindow, into groupId: GroupId?) -> GroupId {
        removeMember(window.windowId)
        if let groupId, let groupIndex = listGroups.firstIndex(where: { $0.groupId == groupId }) {
            listGroups[groupIndex].listMembers.append(window)
            return groupId
        }
        let group = WindowGroup(groupId: .make(), name: nextGroupName(), listMembers: [window])
        listGroups.append(group)
        return group.groupId
    }

    /// Stop managing a window, as when the user releases it or it closes.
    ///
    /// - Returns: whether the window was managed
    @discardableResult
    public mutating func release(_ windowId: WindowId) -> Bool {
        let wasManaged = isManaged(windowId)
        removeMember(windowId)
        return wasManaged
    }

    /// Record a managed window's latest title.
    public mutating func updateTitle(of windowId: WindowId, to title: String) {
        modifyMember(windowId) { $0.title = title }
    }

    /// The managed windows MuxShots has moved off screen.
    public var listHiddenWindows: [ManagedWindow] {
        listManagedWindows.filter(\.isHidden)
    }

    /// Remember where a window was before hiding it.
    ///
    /// - Parameters:
    ///   - windowId: the window
    ///   - restoreFrame: where to put the window back
    public mutating func markHidden(_ windowId: WindowId, restoreFrame: CGRect) {
        modifyMember(windowId) { $0.restoreFrame = restoreFrame }
    }

    /// Forget that a window is hidden.
    ///
    /// - Returns: where the window was before it was hidden, or nil if it was not hidden
    @discardableResult
    public mutating func markShown(_ windowId: WindowId) -> CGRect? {
        let restoreFrame = listManagedWindows.first { $0.windowId == windowId }?.restoreFrame
        modifyMember(windowId) { $0.restoreFrame = nil }
        return restoreFrame
    }

    /// Rename a group; a blank name leaves the group unchanged.
    public mutating func rename(_ groupId: GroupId, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedName.isEmpty,
            let groupIndex = listGroups.firstIndex(where: { $0.groupId == groupId })
        else {
            return
        }
        listGroups[groupIndex].name = trimmedName
    }

    private mutating func modifyMember(_ windowId: WindowId, _ modify: (inout ManagedWindow) -> Void) {
        for groupIndex in listGroups.indices {
            if let memberIndex = listGroups[groupIndex].listMembers.firstIndex(where: { $0.windowId == windowId }) {
                modify(&listGroups[groupIndex].listMembers[memberIndex])
            }
        }
    }

    private mutating func removeMember(_ windowId: WindowId) {
        for groupIndex in listGroups.indices {
            listGroups[groupIndex].listMembers.removeAll { $0.windowId == windowId }
        }
        listGroups.removeAll { $0.listMembers.isEmpty }
        setActiveGroupIds = setActiveGroupIds.filter { groupId in
            listGroups.contains { $0.groupId == groupId }
        }
    }

    /// The lowest "Group N" name not in use.
    private func nextGroupName() -> String {
        let setNames = Set(listGroups.map(\.name))
        var number = 1
        while setNames.contains(Self.defaultGroupNamePrefix + String(number)) {
            number += 1
        }
        return Self.defaultGroupNamePrefix + String(number)
    }
}
