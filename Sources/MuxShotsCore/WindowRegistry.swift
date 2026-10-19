/// The table of every tracked window, the single source of truth that policy and UI read.
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

    /// Replace everything known about one application with a fresh snapshot of it.
    ///
    /// - Parameter snapshot: the application's complete current window set
    /// - Returns: the changes, removals first
    public mutating func apply(_ snapshot: ApplicationSnapshot) -> [WindowChange] {
        var listChanges: [WindowChange] = []
        let setSnapshotIds = Set(snapshot.listWindows.map(\.windowId))

        for windowId in windowIds(ofProcess: snapshot.application.processId) where !setSnapshotIds.contains(windowId) {
            mapWindows[windowId] = nil
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
