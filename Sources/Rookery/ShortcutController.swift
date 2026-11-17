import AppKit
import Carbon.HIToolbox
import os
import RookeryPlatform

/// The global shortcuts, as the preferences define them: the group modifiers with 1–9 show a group, and
/// separate shortcuts show every window, open the group switcher and cycle the active group's windows.
@MainActor
final class ShortcutController {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "shortcuts")
    /// The number keys 1–9, whose virtual key codes are not consecutive.
    static let listGroupKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// The arrow keys that move an open switcher's selection.
    private static let mapArrowDirections: [Int: SwitcherDirection] = [
        kVK_LeftArrow: .left,
        kVK_RightArrow: .right,
        kVK_UpArrow: .up,
        kVK_DownArrow: .down,
    ]

    private let workspaceController: WorkspaceController
    private let preferences: Preferences
    private let hotkeyCenter = HotkeyCenter()
    private let stages: StageCoordinator
    private let launcher: LauncherController
    private lazy var switcher = SwitcherController(hotkeyCenter: hotkeyCenter) { [preferences] in
        preferences.theme
    }
    private lazy var keyInterceptor = KeyInterceptor { [weak self] keyCode, modifiers in
        self?.intercept(keyCode: keyCode, modifiers: modifiers) ?? false
    }
    private var isSuspended = false

    init(workspaceController: WorkspaceController, preferences: Preferences, stages: StageCoordinator, launcher: LauncherController) {
        self.workspaceController = workspaceController
        self.preferences = preferences
        self.stages = stages
        self.launcher = launcher
    }

    /// Register every shortcut, and register them again whenever the preferences change.
    func start() {
        hotkeyCenter.start()
        if !keyInterceptor.start() {
            Self.logger.error("cannot take over ⌘⇥: the key event tap was refused")
        }
        preferences.onShortcutsChange = { [weak self] in
            self?.registerAll()
        }
        registerAll()
    }

    func stop() {
        hotkeyCenter.stop()
        keyInterceptor.stop()
    }

    /// Release every shortcut while the user records a new one, so pressing a taken combination records it
    /// instead of running it.
    func suspend() {
        isSuspended = true
        hotkeyCenter.unregisterAll()
    }

    func resume() {
        isSuspended = false
        registerAll()
    }

    private func registerAll() {
        hotkeyCenter.unregisterAll()
        guard !isSuspended else {
            return
        }
        for (position, keyCode) in Self.listGroupKeyCodes.enumerated() {
            bind(Hotkey(keyCode: keyCode, modifiers: preferences.groupModifiers), name: "group \(position + 1)") {
                [weak self] in
                self?.switchToGroup(atPosition: position)
            }
        }
        bind(preferences.stageHotkey, name: "stage") { [weak self] in
            self?.stages.toggleOnCursorDisplay()
        }
        bind(preferences.rightSidebarHotkey, name: "right sidebar") { [weak self] in
            self?.stages.toggleRightSidebarOnCursorDisplay()
        }
        bind(preferences.showAllHotkey, name: "all windows") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.switchTo(nil)
            }
        }
        bind(preferences.previousTabHotkey, name: "previous tab") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.stepActiveGroupWindow(by: -1)
            }
        }
        bind(preferences.nextTabHotkey, name: "next tab") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.stepActiveGroupWindow(by: 1)
            }
        }
        bind(preferences.cycleHotkey, name: "cycle windows") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.cycleActiveGroupWindow()
            }
        }
        let switcherHotkey = preferences.switcherHotkey
        let holdModifiers = switcherHotkey.modifiers.subtracting(.shift)
        bind(switcherHotkey, name: "switcher") { [weak self] in
            self?.advanceGroupSwitcher(by: 1, holding: holdModifiers)
        }
        let backwardHotkey = Hotkey(keyCode: Int(switcherHotkey.keyCode), modifiers: switcherHotkey.modifiers.union(.shift))
        if backwardHotkey != switcherHotkey {
            bind(backwardHotkey, name: "switcher backwards") { [weak self] in
                self?.advanceGroupSwitcher(by: -1, holding: holdModifiers)
            }
        }
    }

    private func advanceGroupSwitcher(by step: Int, holding holdModifiers: NSEvent.ModifierFlags) {
        switcher.advance(by: step, holding: holdModifiers) { [workspaceController] in
            workspaceController.groupSwitcherRequest()
        }
    }

    /// Take the arrow keys while a switcher is open, and ⌘⇥ while the user works on the stage.
    ///
    /// - Returns: whether the key press was taken
    private func intercept(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let setShortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let launcherHotkey = preferences.launcherHotkey
        if
            !isSuspended,
            keyCode == Int(launcherHotkey.keyCode),
            modifiers.intersection(setShortcutModifiers) == launcherHotkey.modifiers.intersection(setShortcutModifiers)
        {
            DispatchQueue.main.async { [launcher] in
                launcher.toggle()
            }
            return true
        }
        if
            switcher.isShowing,
            let direction = Self.mapArrowDirections[keyCode]
        {
            switcher.move(direction)
            return true
        }
        return interceptWindowSwitch(keyCode: keyCode, modifiers: modifiers)
    }

    /// Take ⌘⇥ over while the user works on the stage, switching between recently used windows across
    /// groups; elsewhere it stays the system's application switcher.
    ///
    /// - Returns: whether the key press was taken
    private func interceptWindowSwitch(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard
            !isSuspended,
            keyCode == kVK_Tab,
            modifiers.contains(.command),
            modifiers.isDisjoint(with: [.control, .option])
        else {
            return false
        }
        if !switcher.isShowing {
            guard workspaceController.isStageFocused else {
                let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
                Self.logger.info("⌘⇥ left to the system: \(frontmostName, privacy: .public) in front is not on the stage")
                return false
            }
            guard workspaceController.windowSwitcherRequest() != nil else {
                Self.logger.info("⌘⇥ left to the system: fewer than two managed windows")
                return false
            }
            Self.logger.info("⌘⇥ opens the window switcher")
        }
        switcher.advance(by: modifiers.contains(.shift) ? -1 : 1, holding: [.command]) { [workspaceController] in
            workspaceController.windowSwitcherRequest()
        }
        return true
    }

    private func bind(_ hotkey: Hotkey, name: String, action: @escaping @MainActor () -> Void) {
        if !hotkeyCenter.register(hotkey, action: action) {
            Self.logger.error("shortcut \(hotkey.description, privacy: .public) for \(name, privacy: .public) is taken")
        }
    }

    private func switchToGroup(atPosition position: Int) {
        let listGroups = workspaceController.listSwitchableGroups
        guard listGroups.indices.contains(position) else {
            return
        }
        let groupId = listGroups[position].groupId
        Task { [workspaceController] in
            await workspaceController.switchTo(groupId)
        }
    }
}
