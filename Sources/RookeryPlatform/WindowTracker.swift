import Foundation
import RookeryCore

/// Keeps the window registry in step with the managed windows, from Accessibility events plus a periodic
/// reconciliation against the window server. Applications without managed windows are not touched.
public actor WindowTracker {
    /// Accessibility notifications handle normal changes; this is only a fallback for missed events.
    private static let reconcileInterval = Duration.seconds(10)
    private static let messagingTimeoutSeconds: Float = 1

    private var registry = WindowRegistry()
    private var mapTrackers: [pid_t: ApplicationWindowTracker] = [:]
    private var mapManagedProcessIds: [WindowId: pid_t] = [:]
    private var mapSubscribers: [UUID: AsyncStream<WindowChange>.Continuation] = [:]
    private let focusEvents: AsyncStream<WindowId>
    private let focusContinuation: AsyncStream<WindowId>.Continuation
    private let snapshots: AsyncStream<ApplicationSnapshot>
    private let snapshotContinuation: AsyncStream<ApplicationSnapshot>.Continuation
    private var snapshotTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?

    public init() {
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(of: ApplicationSnapshot.self)
        (focusEvents, focusContinuation) = AsyncStream.makeStream(of: WindowId.self)
    }

    /// Managed windows as their applications focus them, for a single consumer.
    public nonisolated var focusedWindows: AsyncStream<WindowId> {
        focusEvents
    }

    /// The managed window an application has focused, if it has one.
    public func focusedWindowId(ofProcess processId: pid_t) async -> WindowId? {
        guard let tracker = mapTrackers[processId] else {
            return nil
        }
        return await tracker.focusedWindowId()
    }

    /// Begin consuming tracker snapshots and reconciling periodically.
    public func start() {
        AccessibilityElement.applyGlobalMessagingTimeout(seconds: Self.messagingTimeoutSeconds)
        snapshotTask = Task { [snapshots] in
            for await snapshot in snapshots {
                apply(snapshot)
            }
        }
        reconcileTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reconcileInterval)
                reconcile()
            }
        }
    }

    /// Stop every application tracker and end all subscriptions.
    public func stop() {
        reconcileTask?.cancel()
        snapshotTask?.cancel()
        for tracker in mapTrackers.values {
            tracker.stop()
        }
        mapTrackers.removeAll()
        mapManagedProcessIds.removeAll()
        for continuation in mapSubscribers.values {
            continuation.finish()
        }
        mapSubscribers.removeAll()
    }

    /// Start tracking a window, and its application if this is the application's first managed window.
    public func manage(_ windowId: WindowId, of application: RunningApplication) {
        if let previousProcessId = mapManagedProcessIds[windowId], previousProcessId != application.processId {
            release(windowId)
        }
        mapManagedProcessIds[windowId] = application.processId
        let tracker = mapTrackers[application.processId] ?? startTracker(for: application)
        tracker.manage(windowId)
    }

    /// Stop tracking a window, and its application if no other managed window remains.
    public func release(_ windowId: WindowId) {
        guard let processId = mapManagedProcessIds.removeValue(forKey: windowId) else {
            return
        }
        mapTrackers[processId]?.release(windowId)
        stopTrackerIfUnused(processId: processId)
        publish(registry.remove(windowId))
    }

    /// Move and resize a managed window.
    ///
    /// - Parameter frame: the frame in global screen coordinates, origin at the top-left of the main display
    /// - Returns: the frame after the move, or nil if the window is not managed or could not be moved
    @discardableResult
    public func applyFrame(_ frame: CGRect, to windowId: WindowId) async -> CGRect? {
        guard let tracker = tracker(of: windowId) else {
            return nil
        }
        return await tracker.applyFrame(frame, to: windowId)
    }

    /// Where a managed window is, as Accessibility reports it.
    public func frame(of windowId: WindowId) async -> CGRect? {
        guard let tracker = tracker(of: windowId) else {
            return nil
        }
        return await tracker.frame(of: windowId)
    }

    /// Bring a managed window to the front of its application; activating the application is the caller's.
    ///
    /// - Returns: whether the window was raised
    public func raise(_ windowId: WindowId) async -> Bool {
        guard let tracker = tracker(of: windowId) else {
            return false
        }
        return await tracker.raise(windowId)
    }

    /// Minimize a managed window to the Dock, or restore it from there where it was last placed.
    ///
    /// - Returns: whether the window took the request
    public func applyMinimized(_ isMinimized: Bool, to windowId: WindowId) async -> Bool {
        guard let tracker = tracker(of: windowId) else {
            return false
        }
        return await tracker.applyMinimized(isMinimized, to: windowId)
    }

    /// Whether a managed window is minimized to the Dock.
    public func isMinimized(_ windowId: WindowId) async -> Bool {
        guard let tracker = tracker(of: windowId) else {
            return false
        }
        return await tracker.isMinimized(windowId)
    }

    /// Whether a managed window is in native full screen.
    public func isFullscreen(_ windowId: WindowId) async -> Bool {
        guard let tracker = tracker(of: windowId) else {
            return false
        }
        return await tracker.isFullscreen(windowId)
    }

    /// Ask a managed window to leave native full screen; the transition finishes asynchronously.
    ///
    /// - Returns: whether the request was accepted
    public func requestExitFullscreen(_ windowId: WindowId) async -> Bool {
        guard let tracker = tracker(of: windowId) else {
            return false
        }
        return await tracker.requestExitFullscreen(windowId)
    }

    /// The process that owns a managed window.
    public func processId(of windowId: WindowId) -> pid_t? {
        mapManagedProcessIds[windowId]
    }

    /// Drop the windows of an application that has quit.
    public func applicationTerminated(processId: pid_t) {
        guard let tracker = mapTrackers.removeValue(forKey: processId) else {
            return
        }
        tracker.stop()
        mapManagedProcessIds = mapManagedProcessIds.filter { $0.value != processId }
        publish(registry.removeApplication(processId: processId))
    }

    /// Refresh every tracked application against the window server's current window list.
    public func reconcile() {
        guard !mapTrackers.isEmpty else {
            return
        }
        let mapServerWindows = Dictionary(
            grouping: WindowServer.listWindows(orderedWindowIds: Set(mapManagedProcessIds.keys)),
            by: \.processId
        )
        for (processId, tracker) in mapTrackers {
            tracker.reconcile(listServerWindows: mapServerWindows[processId] ?? [])
        }
    }

    /// Every tracked window.
    public func listWindows() -> [WindowRecord] {
        registry.listWindows
    }

    /// A stream of every change from now on, ending when the tracker stops. A removal means the window
    /// closed or MuxShots stopped managing it.
    public func changes() -> AsyncStream<WindowChange> {
        let subscriberId = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: WindowChange.self)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.unsubscribe(subscriberId)
            }
        }
        mapSubscribers[subscriberId] = continuation
        return stream
    }

    private func tracker(of windowId: WindowId) -> ApplicationWindowTracker? {
        mapManagedProcessIds[windowId].flatMap { mapTrackers[$0] }
    }

    private func startTracker(for application: RunningApplication) -> ApplicationWindowTracker {
        let tracker = ApplicationWindowTracker(
            application: application,
            onSnapshot: { [snapshotContinuation] snapshot in
                snapshotContinuation.yield(snapshot)
            },
            onFocus: { [focusContinuation] windowId in
                focusContinuation.yield(windowId)
            }
        )
        mapTrackers[application.processId] = tracker
        tracker.start()
        return tracker
    }

    private func stopTrackerIfUnused(processId: pid_t) {
        guard !mapManagedProcessIds.values.contains(processId) else {
            return
        }
        mapTrackers.removeValue(forKey: processId)?.stop()
    }

    private func unsubscribe(_ subscriberId: UUID) {
        mapSubscribers[subscriberId] = nil
    }

    /// Record a tracker's snapshot. A managed window that closed is reported removed even if it closed before
    /// it was ever observed, as a window an application merges away right after it is dropped on MuxShots.
    private func apply(_ snapshot: ApplicationSnapshot) {
        let processId = snapshot.application.processId
        let listWindows = snapshot.listWindows.filter { mapManagedProcessIds[$0.windowId] == processId }
        let listClosedIds = snapshot.listClosedIds.filter { mapManagedProcessIds[$0] == processId }
        for windowId in listClosedIds {
            mapManagedProcessIds[windowId] = nil
        }
        var listChanges = registry.apply(ApplicationSnapshot(
            application: snapshot.application,
            listWindows: listWindows,
            listClosedIds: listClosedIds
        ))
        let setReportedIds = Set(listChanges.compactMap { change -> WindowId? in
            if case .removed(let windowId) = change {
                return windowId
            }
            return nil
        })
        listChanges += listClosedIds.filter { !setReportedIds.contains($0) }.map { .removed(windowId: $0) }
        publish(listChanges)
        stopTrackerIfUnused(processId: processId)
    }

    private func publish(_ listChanges: [WindowChange]) {
        for change in listChanges {
            for continuation in mapSubscribers.values {
                continuation.yield(change)
            }
        }
    }
}
