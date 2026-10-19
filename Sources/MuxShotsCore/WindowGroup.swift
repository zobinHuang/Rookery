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

    public init(groupId: GroupId, name: String, listMembers: [ManagedWindow] = []) {
        self.groupId = groupId
        self.name = name
        self.listMembers = listMembers
    }
}
