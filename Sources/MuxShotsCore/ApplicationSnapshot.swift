/// The complete set of windows one application has at one moment.
public struct ApplicationSnapshot: Sendable {
    /// The application the snapshot describes.
    public let application: RunningApplication
    /// Every window the application currently has.
    public let listWindows: [WindowRecord]

    public init(application: RunningApplication, listWindows: [WindowRecord]) {
        self.application = application
        self.listWindows = listWindows
    }
}
