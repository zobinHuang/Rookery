import Foundation
import MuxShotsCore

/// Keeps the window registry in step with every running application, from Accessibility events
/// plus a periodic reconciliation against the window server.
public actor WindowTracker {
    private static let reconcileInterval = Duration.seconds(2)
    private static let messagingTimeoutSeconds: Float = 1

    private var registry = WindowRegistry()
    private var mapTrackers: [pid_t: ApplicationWindowTracker] = [:]
    private var mapSubscribers: [UUID: AsyncStream<WindowChange>.Continuation] = [:]
    private let snapshots: AsyncStream<ApplicationSnapshot>
    private let snapshotContinuation: AsyncStream<ApplicationSnapshot>.Continuation
    private var snapshotTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?

    public init() {
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(of: ApplicationSnapshot.self)
    }

    /// Begin tracking the given applications and reconciling periodically.
    public func start(listApplications: [RunningApplication]) {
        AccessibilityElement.applyGlobalMessagingTimeout(seconds: Self.messagingTimeoutSeconds)
        snapshotTask = Task { [snapshots] in
            for await snapshot in snapshots {
                apply(snapshot)
            }
        }
        for application in listApplications {
            applicationLaunched(application)
        }
        reconcileTask = Task {
            while !Task.isCancelled {
                reconcile()
                try? await Task.sleep(for: Self.reconcileInterval)
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
        for continuation in mapSubscribers.values {
            continuation.finish()
        }
        mapSubscribers.removeAll()
    }

    /// Start tracking an application that has just launched.
    public func applicationLaunched(_ application: RunningApplication) {
        guard mapTrackers[application.processId] == nil else {
            return
        }
        let tracker = ApplicationWindowTracker(application: application) { [snapshotContinuation] snapshot in
            snapshotContinuation.yield(snapshot)
        }
        mapTrackers[application.processId] = tracker
        tracker.start()
    }

    /// Stop tracking an application that has quit and drop its windows.
    public func applicationTerminated(processId: pid_t) {
        guard let tracker = mapTrackers.removeValue(forKey: processId) else {
            return
        }
        tracker.stop()
        publish(registry.removeApplication(processId: processId))
    }

    /// Refresh every application against the window server's current window list.
    public func reconcile() {
        let mapServerWindows = Dictionary(grouping: WindowServer.listWindows(), by: \.processId)
        for (processId, tracker) in mapTrackers {
            tracker.reconcile(listServerWindows: mapServerWindows[processId] ?? [])
        }
    }

    /// Every tracked window.
    public func listWindows() -> [WindowRecord] {
        registry.listWindows
    }

    /// A stream of every change from now on, ending when the tracker stops.
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

    private func unsubscribe(_ subscriberId: UUID) {
        mapSubscribers[subscriberId] = nil
    }

    private func apply(_ snapshot: ApplicationSnapshot) {
        guard mapTrackers[snapshot.application.processId] != nil else {
            return
        }
        publish(registry.apply(snapshot))
    }

    private func publish(_ listChanges: [WindowChange]) {
        for change in listChanges {
            for continuation in mapSubscribers.values {
                continuation.yield(change)
            }
        }
    }
}
