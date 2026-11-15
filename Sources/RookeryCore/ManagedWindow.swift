import CoreGraphics

/// A window the user has handed to Rookery, with enough identity to show it while its application is not tracked.
public struct ManagedWindow: Codable, Equatable, Sendable {
    /// The window-server identifier.
    public let windowId: WindowId
    /// The application that owns the window.
    public let application: RunningApplication
    /// The last title seen.
    public var title: String
    /// A name the user gave the window, shown in place of its title; nil to show the title.
    public var customName: String?
    /// Where the window was before Rookery hid it, in global screen coordinates with the origin at the
    /// top-left of the main display; nil while the window is not hidden.
    public var restoreFrame: CGRect?
    /// Where the window was before the stage took it over, in the same coordinates; the window goes back
    /// there when it leaves the stage. Nil while the window is not on the stage.
    public var homeFrame: CGRect?

    public init(
        windowId: WindowId,
        application: RunningApplication,
        title: String,
        customName: String? = nil,
        restoreFrame: CGRect? = nil,
        homeFrame: CGRect? = nil
    ) {
        self.windowId = windowId
        self.application = application
        self.title = title
        self.customName = customName
        self.restoreFrame = restoreFrame
        self.homeFrame = homeFrame
    }

    /// The name to show: the user's name for the window, else its title, else its application's name.
    public var displayName: String {
        if let customName {
            return customName
        }
        return title.isEmpty ? application.name : title
    }

    /// Whether Rookery has moved the window off screen.
    public var isHidden: Bool {
        restoreFrame != nil
    }
}
