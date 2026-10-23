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
    private let stageItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let onAccessGranted: @MainActor () -> Void
    private let onShowWorkspace: @MainActor () -> Void
    private let workspaceProvider: @MainActor () -> Workspace?
    private let isStageOpenProvider: @MainActor () -> Bool
    private let onToggleStage: @MainActor () -> Void
    private let onShowSettings: @MainActor () -> Void
    private let groupModifiersProvider: @MainActor () -> NSEvent.ModifierFlags
    private let onSwitch: @MainActor (GroupId?) -> Void
    private var listGroupItems: [NSMenuItem] = []
    private var permissionPollTask: Task<Void, Never>?

    /// - Parameters:
    ///   - onAccessGranted: called whenever the permission is found granted
    ///   - onShowWorkspace: called when the user asks to see the managed windows
    ///   - workspaceProvider: the groups to list, or nil before managing starts
    ///   - isStageOpenProvider: whether the stage is open, which names the stage item
    ///   - onToggleStage: called when the user opens or closes the stage
    ///   - onShowSettings: called when the user asks for the settings
    ///   - groupModifiersProvider: the modifiers of the group shortcuts, shown beside each group
    ///   - onSwitch: called with the group to show, or nil to show every window
    init(
        onAccessGranted: @escaping @MainActor () -> Void,
        onShowWorkspace: @escaping @MainActor () -> Void,
        workspaceProvider: @escaping @MainActor () -> Workspace?,
        isStageOpenProvider: @escaping @MainActor () -> Bool,
        onToggleStage: @escaping @MainActor () -> Void,
        onShowSettings: @escaping @MainActor () -> Void,
        groupModifiersProvider: @escaping @MainActor () -> NSEvent.ModifierFlags,
        onSwitch: @escaping @MainActor (GroupId?) -> Void
    ) {
        self.onAccessGranted = onAccessGranted
        self.onShowWorkspace = onShowWorkspace
        self.workspaceProvider = workspaceProvider
        self.isStageOpenProvider = isStageOpenProvider
        self.onToggleStage = onToggleStage
        self.onShowSettings = onShowSettings
        self.groupModifiersProvider = groupModifiersProvider
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

        stageItem.title = "Enter Stage"
        stageItem.target = self
        stageItem.action = #selector(toggleStage)

        showWorkspaceItem.title = "Show Managed Windows…"
        showWorkspaceItem.target = self
        showWorkspaceItem.action = #selector(showWorkspace)

        settingsItem.title = "Settings…"
        settingsItem.keyEquivalent = ","
        settingsItem.target = self
        settingsItem.action = #selector(showSettings)

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
        menu.addItem(stageItem)
        menu.addItem(.separator())
        menu.addItem(showWorkspaceItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        refreshPermission()
        guard !AccessibilityPermission.isGranted else {
            return
        }
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
        stageItem.isEnabled = isPermissionGranted
        settingsItem.isEnabled = isPermissionGranted
        if isPermissionGranted {
            permissionPollTask?.cancel()
            permissionPollTask = nil
            onAccessGranted()
        }
    }

    /// Rebuild the group list each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPermission()
        stageItem.title = isStageOpenProvider() ? "Exit Stage" : "Enter Stage"
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
                item.keyEquivalentModifierMask = groupModifiersProvider()
            }
            listGroupItems.append(item)
        }
        let showAllItem = NSMenuItem(title: "Show All Windows", action: #selector(showAllWindows), keyEquivalent: "")
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

    @objc private func toggleStage() {
        onToggleStage()
    }

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func showWorkspace() {
        onShowWorkspace()
    }

    @objc private func grantAccess() {
        AccessibilityPermission.requestAccess()
        AccessibilityPermission.openSystemSettings()
    }
}
