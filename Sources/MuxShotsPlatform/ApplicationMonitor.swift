import AppKit
import MuxShotsCore

/// Feeds application quits and Space changes from `NSWorkspace` into a window tracker.
@MainActor
public final class ApplicationMonitor {
    private let tracker: WindowTracker
    private var listObservers: [NSObjectProtocol] = []

    public init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    /// The running application with a process identifier, in tracker terms.
    ///
    /// - Returns: the application, or nil if no such process is running
    public static func application(processId: pid_t) -> RunningApplication? {
        guard let running = NSRunningApplication(processIdentifier: processId) else {
            return nil
        }
        return RunningApplication(
            processId: processId,
            bundleId: running.bundleIdentifier,
            name: running.localizedName ?? running.bundleIdentifier ?? String(processId)
        )
    }

    /// Start following quits and Space changes.
    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        listObservers = [
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [tracker] notification in
                guard
                    let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else {
                    return
                }
                let processId = running.processIdentifier
                Task {
                    await tracker.applicationTerminated(processId: processId)
                }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [tracker] _ in
                Task {
                    await tracker.reconcile()
                }
            },
        ]
    }

    /// Stop following the workspace.
    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in listObservers {
            center.removeObserver(observer)
        }
        listObservers.removeAll()
    }
}
