import AppKit
import MuxShotsCore
import MuxShotsPlatform

/// The menu bar item: shows whether MuxShots can manage windows and offers the way to grant access.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private static let symbolName = "rectangle.stack"
    private static let permissionPollInterval = Duration.seconds(1)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let permissionItem = NSMenuItem()
    private let grantItem = NSMenuItem()
    private let showWorkspaceItem = NSMenuItem()
    private let onAccessGranted: @MainActor () -> Void
    private let onShowWorkspace: @MainActor () -> Void
    private let workspaceProvider: @MainActor () -> Workspace?
    private let onSwitch: @MainActor (GroupId?) -> Void
    private var listGroupItems: [NSMenuItem] = []
    private var permissionPollTask: Task<Void, Never>?

    /// - Parameters:
    ///   - onAccessGranted: called whenever the permission is found granted
    ///   - onShowWorkspace: called when the user asks to see the managed windows
    ///   - workspaceProvider: the groups to list, or nil before managing starts
    ///   - onSwitch: called with the group to show, or nil to show every window
    init(
        onAccessGranted: @escaping @MainActor () -> Void,
        onShowWorkspace: @escaping @MainActor () -> Void,
        workspaceProvider: @escaping @MainActor () -> Workspace?,
        onSwitch: @escaping @MainActor (GroupId?) -> Void
    ) {
        self.onAccessGranted = onAccessGranted
        self.onShowWorkspace = onShowWorkspace
        self.workspaceProvider = workspaceProvider
        self.onSwitch = onSwitch
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
        menu.delegate = self
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

    /// Rebuild the group list each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in listGroupItems {
            menu.removeItem(item)
        }
        listGroupItems.removeAll()
        guard let workspace = workspaceProvider(), !workspace.listGroups.isEmpty else {
            return
        }
        for (position, group) in workspace.listGroups.enumerated() {
            let item = NSMenuItem(title: group.name, action: #selector(switchToGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.groupId.rawValue
            item.state = workspace.isActive(group.groupId) ? .on : .off
            if ShortcutController.listGroupKeyCodes.indices.contains(position) {
                item.keyEquivalent = String(position + 1)
                item.keyEquivalentModifierMask = [.control, .option]
            }
            listGroupItems.append(item)
        }
        let showAllItem = NSMenuItem(title: "Show All Windows", action: #selector(showAllWindows), keyEquivalent: "0")
        showAllItem.keyEquivalentModifierMask = [.control, .option]
        showAllItem.target = self
        showAllItem.isEnabled = !workspace.setActiveGroupIds.isEmpty
        listGroupItems.append(showAllItem)
        listGroupItems.append(.separator())
        let insertionIndex = menu.index(of: showWorkspaceItem)
        for (offset, item) in listGroupItems.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    @objc private func switchToGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? String else {
            return
        }
        onSwitch(GroupId(rawValue: rawId))
    }

    @objc private func showAllWindows() {
        onSwitch(nil)
    }

    @objc private func showWorkspace() {
        onShowWorkspace()
    }

    @objc private func grantAccess() {
        AccessibilityPermission.requestAccess()
        AccessibilityPermission.openSystemSettings()
    }
}
