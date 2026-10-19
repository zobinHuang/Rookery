import AppKit
import MuxShotsPlatform
import os

/// Owns the application's long-lived controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "app")

    private let tracker = WindowTracker()
    private var statusMenuController: StatusMenuController?
    private var applicationMonitor: ApplicationMonitor?
    private var controlServer: ControlServer?

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
        controlServer?.stop()
    }

    /// Start tracking windows, once Accessibility access is granted.
    private func startTracking() {
        guard applicationMonitor == nil else {
            return
        }
        let monitor = ApplicationMonitor(tracker: tracker)
        applicationMonitor = monitor
        monitor.start()
        do {
            let server = try ControlServer(tracker: tracker)
            controlServer = server
            server.start()
        } catch {
            Self.logger.error("cannot start control server: \(error)")
        }
    }
}
