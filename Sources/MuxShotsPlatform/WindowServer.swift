import CoreGraphics
import Foundation
import MuxShotsCore

/// A window as the window server lists it, across every Space.
public struct WindowServerWindow: Sendable {
    public let windowId: WindowId
    public let processId: pid_t
    /// The frame in global screen coordinates, origin at the top-left of the main display.
    public let frame: CGRect
    public let isOnScreen: Bool
    /// Whether the window is shown on some Space; false for minimized windows, windows of hidden
    /// applications and windows an application has closed but keeps alive.
    public let isOrderedIn: Bool
}

/// Read-only queries of the window server's window list.
public enum WindowServer {
    private static let normalWindowLayer = 0
    private static let transparentAlpha = 0.0

    /// Every visible normal-layer window of every application, on any Space.
    public static func listWindows() -> [WindowServerWindow] {
        windows(options: [.optionAll, .excludeDesktopElements], relativeTo: kCGNullWindowID)
    }

    /// One window, if it still exists.
    public static func window(withId windowId: WindowId) -> WindowServerWindow? {
        windows(options: [.optionIncludingWindow], relativeTo: windowId.rawValue).first
    }

    /// The frontmost on-screen normal window under a point, ignoring windows of one process.
    ///
    /// - Parameters:
    ///   - point: the point in global screen coordinates, origin at the top-left of the main display
    ///   - excludedProcessId: the process whose windows never match, typically MuxShots itself
    public static func frontmostWindow(at point: CGPoint, excluding excludedProcessId: pid_t) -> WindowServerWindow? {
        windows(options: [.optionOnScreenOnly, .excludeDesktopElements], relativeTo: kCGNullWindowID)
            .first { $0.processId != excludedProcessId && $0.frame.contains(point) }
    }

    /// Normal-layer, non-transparent windows in front-to-back order.
    private static func windows(options: CGWindowListOption, relativeTo windowId: CGWindowID) -> [WindowServerWindow] {
        guard let listInfo = CGWindowListCopyWindowInfo(options, windowId) as? [[String: Any]] else {
            return []
        }
        let connectionId = cgsMainConnectionId()
        return listInfo.compactMap { info in
            guard
                let rawId = info[kCGWindowNumber as String] as? UInt32,
                let processId = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == normalWindowLayer,
                info[kCGWindowAlpha as String] as? Double != transparentAlpha,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsInfo)
            else {
                return nil
            }
            var isOrderedIn = false
            _ = cgsWindowIsOrderedIn(connectionId, rawId, &isOrderedIn)
            return WindowServerWindow(
                windowId: WindowId(rawValue: rawId),
                processId: processId,
                frame: frame,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                isOrderedIn: isOrderedIn
            )
        }
    }
}
