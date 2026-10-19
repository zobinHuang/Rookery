/// A window the user has handed to MuxShots, with enough identity to show it while its application is not tracked.
public struct ManagedWindow: Codable, Equatable, Sendable {
    /// The window-server identifier.
    public let windowId: WindowId
    /// The application that owns the window.
    public let application: RunningApplication
    /// The last title seen.
    public var title: String

    public init(windowId: WindowId, application: RunningApplication, title: String) {
        self.windowId = windowId
        self.application = application
        self.title = title
    }
}
