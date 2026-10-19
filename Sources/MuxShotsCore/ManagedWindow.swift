import CoreGraphics

/// A window the user has handed to MuxShots, with enough identity to show it while its application is not tracked.
public struct ManagedWindow: Codable, Equatable, Sendable {
    /// The window-server identifier.
    public let windowId: WindowId
    /// The application that owns the window.
    public let application: RunningApplication
    /// The last title seen.
    public var title: String
    /// Where the window was before MuxShots hid it, in global screen coordinates with the origin at the
    /// top-left of the main display; nil while the window is not hidden.
    public var restoreFrame: CGRect?

    public init(windowId: WindowId, application: RunningApplication, title: String, restoreFrame: CGRect? = nil) {
        self.windowId = windowId
        self.application = application
        self.title = title
        self.restoreFrame = restoreFrame
    }

    /// Whether MuxShots has moved the window off screen.
    public var isHidden: Bool {
        restoreFrame != nil
    }
}
