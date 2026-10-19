/// One change to the set of tracked windows.
public enum WindowChange: Codable, Equatable, Sendable {
    case added(window: WindowRecord)
    case updated(window: WindowRecord)
    case removed(windowId: WindowId)
}
