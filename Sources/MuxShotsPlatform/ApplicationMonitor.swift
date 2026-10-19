import AppKit
import MuxShotsCore

/// Feeds application launches, quits and Space changes from `NSWorkspace` into a window tracker.
@MainActor
public final class ApplicationMonitor {
    private let tracker: WindowTracker
    private var listObservers: [NSObjectProtocol] = []

    public init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    /// Start tracking every regular application already running, then follow launches and quits.
    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        listObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) {
                [tracker] notification in
                guard let application = Self.trackedApplication(from: notification) else {
                    return
                }
                Task {
                    await tracker.applicationLaunched(application)
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [tracker] notification in
                guard let application = Self.trackedApplication(from: notification) else {
                    return
                }
                Task {
                    await tracker.applicationTerminated(processId: application.processId)
                }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [tracker] _ in
                Task {
                    await tracker.reconcile()
                }
            },
        ]

        let listApplications = NSWorkspace.shared.runningApplications.compactMap(Self.trackedApplication(from:))
        Task { [tracker] in
            await tracker.start(listApplications: listApplications)
        }
    }

    /// Stop following the workspace and stop the tracker.
    public func stop() async {
        let center = NSWorkspace.shared.notificationCenter
        for observer in listObservers {
            center.removeObserver(observer)
        }
        listObservers.removeAll()
        await tracker.stop()
    }

    private nonisolated static func trackedApplication(from notification: Notification) -> RunningApplication? {
        guard let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return nil
        }
        return trackedApplication(from: running)
    }

    /// The application in tracker terms, or nil for background agents and MuxShots itself.
    private nonisolated static func trackedApplication(from running: NSRunningApplication) -> RunningApplication? {
        guard
            running.activationPolicy == .regular,
            running.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }
        return RunningApplication(
            processId: running.processIdentifier,
            bundleId: running.bundleIdentifier,
            name: running.localizedName ?? running.bundleIdentifier ?? String(running.processIdentifier)
        )
    }
}
