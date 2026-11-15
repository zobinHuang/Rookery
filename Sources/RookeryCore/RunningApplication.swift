/// An application process whose windows Rookery tracks.
public struct RunningApplication: Codable, Hashable, Sendable {
    /// The process identifier.
    public let processId: Int32
    /// The bundle identifier, absent for unbundled executables.
    public let bundleId: String?
    /// The user-visible application name.
    public let name: String

    public init(processId: Int32, bundleId: String?, name: String) {
        self.processId = processId
        self.bundleId = bundleId
        self.name = name
    }
}
