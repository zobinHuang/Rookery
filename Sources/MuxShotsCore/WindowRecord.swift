import CoreGraphics

/// The observed state of one window.
public struct WindowRecord: Codable, Equatable, Sendable {
    /// The window-server identifier.
    public let windowId: WindowId
    /// The application that owns the window.
    public let application: RunningApplication
    /// The window title, empty when the window has none.
    public let title: String
    /// The frame in global screen coordinates, origin at the top-left of the main display.
    public let frame: CGRect
    /// Whether the window is minimized to the Dock.
    public let isMinimized: Bool
    /// Whether the window is in native full-screen mode, on a Space of its own.
    public let isFullscreen: Bool
    /// Whether the window is on screen in the current Space.
    public let isOnScreen: Bool

    public init(
        windowId: WindowId,
        application: RunningApplication,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        isFullscreen: Bool,
        isOnScreen: Bool
    ) {
        self.windowId = windowId
        self.application = application
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isOnScreen = isOnScreen
    }
}
