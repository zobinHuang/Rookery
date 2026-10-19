import CoreGraphics
import MuxShotsCore

/// A window as the window server lists it, across every Space.
struct WindowServerWindow: Sendable {
    let windowId: WindowId
    let processId: pid_t
    let isOnScreen: Bool
    /// Whether the window is shown on some Space; false for minimized windows, windows of hidden
    /// applications and windows an application has closed but keeps alive.
    let isOrderedIn: Bool
}

/// Read-only queries of the window server: its window list and its Spaces.
enum WindowServer {
    private static let normalWindowLayer = 0
    private static let transparentAlpha = 0.0
    private static let allSpacesMask: Int32 = 0x7
    private static let currentSpaceKey = "Current Space"
    private static let managedSpaceIdKey = "ManagedSpaceID"

    /// Every visible normal-layer window of every application, on any Space.
    static func listWindows() -> [WindowServerWindow] {
        guard
            let listInfo = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }
        let connectionId = cgsMainConnectionId()
        return listInfo.compactMap { info in
            guard
                let rawId = info[kCGWindowNumber as String] as? UInt32,
                let processId = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == normalWindowLayer,
                info[kCGWindowAlpha as String] as? Double != transparentAlpha
            else {
                return nil
            }
            var isOrderedIn = false
            _ = cgsWindowIsOrderedIn(connectionId, rawId, &isOrderedIn)
            return WindowServerWindow(
                windowId: WindowId(rawValue: rawId),
                processId: processId,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                isOrderedIn: isOrderedIn
            )
        }
    }

    /// The Space currently shown on each display.
    static func currentSpaceIds() -> Set<UInt64> {
        guard
            let listDisplays = cgsCopyManagedDisplaySpaces(cgsMainConnectionId())?
                .takeRetainedValue() as? [[String: Any]]
        else {
            return []
        }
        return Set(listDisplays.compactMap { display in
            (display[currentSpaceKey] as? [String: Any])?[managedSpaceIdKey] as? UInt64
        })
    }

    /// The Spaces a window belongs to.
    static func spaceIds(ofWindow windowId: WindowId) -> Set<UInt64> {
        let listWindowIds = [windowId.rawValue] as CFArray
        guard
            let listSpaceIds = cgsCopySpacesForWindows(cgsMainConnectionId(), allSpacesMask, listWindowIds)?
                .takeRetainedValue() as? [UInt64]
        else {
            return []
        }
        return Set(listSpaceIds)
    }
}
