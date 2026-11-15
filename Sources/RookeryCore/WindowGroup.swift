import Foundation

/// The stable identifier of a window group.
public struct GroupId: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new identifier no other group has.
    public static func make() -> GroupId {
        GroupId(rawValue: UUID().uuidString)
    }

    public var description: String {
        rawValue
    }
}

/// A named set of managed windows that MuxShots shows, hides and switches as one.
public struct WindowGroup: Codable, Equatable, Sendable {
    public let groupId: GroupId
    public var name: String
    /// The members in the order they joined.
    public var listMembers: [ManagedWindow]
    /// The members' front-to-back order when the group was last switched away from; nil until then.
    public var listStackIds: [WindowId]?

    public init(groupId: GroupId, name: String, listMembers: [ManagedWindow] = [], listStackIds: [WindowId]? = nil) {
        self.groupId = groupId
        self.name = name
        self.listMembers = listMembers
        self.listStackIds = listStackIds
    }

    /// The members front to back: the last recorded stacking first, then members that joined since.
    public var listMembersFrontToBack: [ManagedWindow] {
        let listStackIds = listStackIds ?? []
        let mapStackIndices = Dictionary(listStackIds.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        return listMembers.enumerated()
            .sorted { lhs, rhs in
                let lhsIndex = mapStackIndices[lhs.element.windowId] ?? listStackIds.count + lhs.offset
                let rhsIndex = mapStackIndices[rhs.element.windowId] ?? listStackIds.count + rhs.offset
                return lhsIndex < rhsIndex
            }
            .map(\.element)
    }
}
