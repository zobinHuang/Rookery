/// The table of every tracked window, the single source of truth for their observed state.
public struct WindowRegistry: Sendable {
    private var mapWindows: [WindowId: WindowRecord] = [:]

    public init() {}

    /// Every tracked window, ordered by application name and then by window identifier.
    public var listWindows: [WindowRecord] {
        mapWindows.values.sorted { lhs, rhs in
            if lhs.application.name != rhs.application.name {
                return lhs.application.name < rhs.application.name
            }
            return lhs.windowId < rhs.windowId
        }
    }

    /// Look up a tracked window.
    ///
    /// - Parameter windowId: the window-server identifier
    /// - Returns: the window, or nil if it is not tracked
    public func window(withId windowId: WindowId) -> WindowRecord? {
        mapWindows[windowId]
    }

    /// Record what an application tracker observed. A window missing from the snapshot keeps its last
    /// state, since a tracker can lose sight of a window that still exists; only closed windows are removed.
    ///
    /// - Parameter snapshot: the observed windows and the closed ones
    /// - Returns: the changes, removals first
    public mutating func apply(_ snapshot: ApplicationSnapshot) -> [WindowChange] {
        var listChanges: [WindowChange] = []
        for windowId in snapshot.listClosedIds.sorted() where mapWindows.removeValue(forKey: windowId) != nil {
            listChanges.append(.removed(windowId: windowId))
        }
        for window in snapshot.listWindows {
            switch mapWindows[window.windowId] {
            case nil:
                listChanges.append(.added(window: window))
            case let previous? where previous != window:
                listChanges.append(.updated(window: window))
            default:
                break
            }
            mapWindows[window.windowId] = window
        }
        return listChanges
    }

    /// Forget one window, as when Rookery stops managing it.
    ///
    /// - Returns: the removal, or nothing if the window was not tracked
    public mutating func remove(_ windowId: WindowId) -> [WindowChange] {
        mapWindows.removeValue(forKey: windowId) == nil ? [] : [.removed(windowId: windowId)]
    }

    /// Forget every window of an application that has quit.
    ///
    /// - Parameter processId: the application's process identifier
    /// - Returns: the removals
    public mutating func removeApplication(processId: Int32) -> [WindowChange] {
        let listRemovedIds = windowIds(ofProcess: processId)
        for windowId in listRemovedIds {
            mapWindows[windowId] = nil
        }
        return listRemovedIds.map { .removed(windowId: $0) }
    }

    private func windowIds(ofProcess processId: Int32) -> [WindowId] {
        mapWindows.values
            .filter { $0.application.processId == processId }
            .map(\.windowId)
            .sorted()
    }
}
