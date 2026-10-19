import AppKit
import MuxShotsPlatform

/// The menu bar item: shows whether MuxShots can manage windows and offers the way to grant access.
@MainActor
final class StatusMenuController: NSObject {
    private static let symbolName = "rectangle.stack"
    private static let permissionPollInterval = Duration.seconds(1)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let permissionItem = NSMenuItem()
    private let grantItem = NSMenuItem()
    private var permissionPollTask: Task<Void, Never>?

    /// Install the menu and start tracking the Accessibility permission.
    func start() {
        statusItem.button?.image = NSImage(
            systemSymbolName: Self.symbolName,
            accessibilityDescription: "MuxShots"
        )

        permissionItem.isEnabled = false
        grantItem.title = "Grant Accessibility Access…"
        grantItem.target = self
        grantItem.action = #selector(grantAccess)

        let quitItem = NSMenuItem(
            title: "Quit MuxShots",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let menu = NSMenu()
        menu.addItem(permissionItem)
        menu.addItem(grantItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        refreshPermission()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.permissionPollInterval)
                self?.refreshPermission()
            }
        }
    }

    /// Stop tracking the permission and remove the menu bar item.
    func stop() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func refreshPermission() {
        let isPermissionGranted = AccessibilityPermission.isGranted
        permissionItem.title = isPermissionGranted
            ? "Accessibility access granted"
            : "Accessibility access required"
        grantItem.isHidden = isPermissionGranted
    }

    @objc private func grantAccess() {
        AccessibilityPermission.requestAccess()
        AccessibilityPermission.openSystemSettings()
    }
}
