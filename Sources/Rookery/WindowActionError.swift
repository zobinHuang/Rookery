import RookeryCore

/// Why an action on a managed window failed.
enum WindowActionError: Error, CustomStringConvertible {
    case notManaged(windowId: WindowId)
    case notHidden(windowId: WindowId)
    case cannotMove(windowId: WindowId)
    case cannotRaise(windowId: WindowId)
    case cannotMinimize(windowId: WindowId)
    case stuckInFullscreen(windowId: WindowId)
    case noDisplay(windowId: WindowId)

    var description: String {
        switch self {
        case .notManaged(let windowId):
            "window \(windowId) is not managed"
        case .notHidden(let windowId):
            "window \(windowId) is not hidden"
        case .cannotMove(let windowId):
            "window \(windowId) refused to move"
        case .cannotRaise(let windowId):
            "window \(windowId) could not be raised"
        case .cannotMinimize(let windowId):
            "window \(windowId) refused to minimize"
        case .stuckInFullscreen(let windowId):
            "window \(windowId) did not leave full screen"
        case .noDisplay(let windowId):
            "window \(windowId) is on no display"
        }
    }
}
