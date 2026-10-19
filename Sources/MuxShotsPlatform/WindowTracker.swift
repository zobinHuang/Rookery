import Foundation
import MuxShotsCore

/// Keeps the window registry in step with the managed windows, from Accessibility events plus a periodic
/// reconciliation against the window server. Applications without managed windows are not touched.
public actor WindowTracker {
    private static let reconcileInterval = Duration.seconds(2)
    private static let messagingTimeoutSeconds: Float = 1

    private var registry = WindowRegistry()
    private var mapTrackers: [pid_t: ApplicationWindowTracker] = [:]
    private var mapManagedProcessIds: [WindowId: pid_t] = [:]
    private var mapSubscribers: [UUID: AsyncStream<WindowChange>.Continuation] = [:]
    private let snapshots: AsyncStream<ApplicationSnapshot>
    private let snapshotContinuation: AsyncStream<ApplicationSnapshot>.Continuation
    private var snapshotTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?

    public init() {
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(of: ApplicationSnapshot.self)
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
    public func applyFrame(_ frame: CGRect, to windowId: WindowId) {
        guard let processId = mapManagedProcessIds[windowId] else {
            return
        }
        mapTrackers[processId]?.applyFrame(frame, to: windowId)
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
        let mapServerWindows = Dictionary(grouping: WindowServer.listWindows(), by: \.processId)
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

    private func startTracker(for application: RunningApplication) -> ApplicationWindowTracker {
        let tracker = ApplicationWindowTracker(application: application) { [snapshotContinuation] snapshot in
            snapshotContinuation.yield(snapshot)
        }
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

    private func apply(_ snapshot: ApplicationSnapshot) {
        let processId = snapshot.application.processId
        let listWindows = snapshot.listWindows.filter { mapManagedProcessIds[$0.windowId] == processId }
        for windowId in snapshot.listClosedIds where mapManagedProcessIds[windowId] == processId {
            mapManagedProcessIds[windowId] = nil
        }
        publish(registry.apply(ApplicationSnapshot(
            application: snapshot.application,
            listWindows: listWindows,
            listClosedIds: snapshot.listClosedIds
        )))
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
