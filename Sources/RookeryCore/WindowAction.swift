/// Something MuxShots can do to a managed window.
public enum WindowAction: String, Codable, Sendable, CaseIterable {
    /// Bring the window to the front and give it keyboard focus.
    case focus
    /// Move the window off screen, remembering where it was.
    case hide
    /// Put a hidden window back where it was.
    case show
    /// Fill the usable area of the window's display, leaving native full screen first.
    case maximize
}
