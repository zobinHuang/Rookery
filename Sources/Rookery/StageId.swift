import Foundation

/// One open stage, of which each display has at most one.
struct StageId: Hashable {
    let rawValue: UUID

    /// A new identifier no other stage has.
    static func make() -> StageId {
        StageId(rawValue: UUID())
    }
}
