/// What one application tracker observed of its managed windows at one moment.
public struct ApplicationSnapshot: Sendable {
    /// The application the snapshot describes.
    public let application: RunningApplication
    /// The current state of every managed window the tracker can see.
    public let listWindows: [WindowRecord]
    /// Managed windows that no longer exist.
    public let listClosedIds: [WindowId]

    public init(application: RunningApplication, listWindows: [WindowRecord], listClosedIds: [WindowId] = []) {
        self.application = application
        self.listWindows = listWindows
        self.listClosedIds = listClosedIds
    }
}
