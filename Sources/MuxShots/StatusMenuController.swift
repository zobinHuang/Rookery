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
    private let showWorkspaceItem = NSMenuItem()
    private let onAccessGranted: @MainActor () -> Void
    private let onShowWorkspace: @MainActor () -> Void
    private var permissionPollTask: Task<Void, Never>?

    /// - Parameters:
    ///   - onAccessGranted: called whenever the permission is found granted
    ///   - onShowWorkspace: called when the user asks to see the managed windows
    init(onAccessGranted: @escaping @MainActor () -> Void, onShowWorkspace: @escaping @MainActor () -> Void) {
        self.onAccessGranted = onAccessGranted
        self.onShowWorkspace = onShowWorkspace
    }

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

        showWorkspaceItem.title = "Show Managed Windows…"
        showWorkspaceItem.target = self
        showWorkspaceItem.action = #selector(showWorkspace)

        let quitItem = NSMenuItem(
            title: "Quit MuxShots",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(permissionItem)
        menu.addItem(grantItem)
        menu.addItem(.separator())
        menu.addItem(showWorkspaceItem)
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
        showWorkspaceItem.isEnabled = isPermissionGranted
        if isPermissionGranted {
            onAccessGranted()
        }
    }

    @objc private func showWorkspace() {
        onShowWorkspace()
    }

    @objc private func grantAccess() {
        AccessibilityPermission.requestAccess()
        AccessibilityPermission.openSystemSettings()
    }
}
