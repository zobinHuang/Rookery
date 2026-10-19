/// A window-server window identifier, stable for the lifetime of the window.
public struct WindowId: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String {
        String(rawValue)
    }

    public static func < (lhs: WindowId, rhs: WindowId) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
