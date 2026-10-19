import AppKit
import MuxShotsPlatform

/// Owns the application's long-lived controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusMenuController()
        statusMenuController = controller
        controller.start()
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.requestAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
    }
}
