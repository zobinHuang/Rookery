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
    private var workspaceController: WorkspaceController?
    private var workspacePanelController: WorkspacePanelController?
    private var controlServer: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusMenuController(
            onAccessGranted: { [weak self] in
                self?.startManaging()
            },
            onShowWorkspace: { [weak self] in
                self?.workspacePanelController?.show()
            }
        )
        statusMenuController = controller
        controller.start()
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.requestAccess()
        }
    }

    /// Opening the app again, from Finder or `open`, shows the managed windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        workspacePanelController?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
        applicationMonitor?.stop()
        workspaceController?.stop()
        controlServer?.stop()
    }

    /// Start managing windows, once Accessibility access is granted.
    private func startManaging() {
        guard workspaceController == nil else {
            return
        }
        let monitor = ApplicationMonitor(tracker: tracker)
        applicationMonitor = monitor
        monitor.start()

        let workspace = WorkspaceController(tracker: tracker)
        let panel = WorkspacePanelController(controller: workspace)
        workspace.onChange = { [weak panel] in
            panel?.reload()
        }
        workspaceController = workspace
        workspacePanelController = panel
        workspace.start()

        do {
            let server = try ControlServer(tracker: tracker, workspaceController: workspace)
            controlServer = server
            server.start()
        } catch {
            Self.logger.error("cannot start control server: \(error)")
        }
    }
}
