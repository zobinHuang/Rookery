import AppKit
import MuxShotsPlatform

/// Owns the application's long-lived controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tracker = WindowTracker()
    private var statusMenuController: StatusMenuController?
    private var applicationMonitor: ApplicationMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusMenuController { [weak self] in
            self?.startTracking()
        }
        statusMenuController = controller
        controller.start()
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.requestAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
    }

    /// Start tracking windows, once Accessibility access is granted.
    private func startTracking() {
        guard applicationMonitor == nil else {
            return
        }
        let monitor = ApplicationMonitor(tracker: tracker)
        applicationMonitor = monitor
        monitor.start()
    }
}
