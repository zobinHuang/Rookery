import AppKit
import Carbon.HIToolbox
import MuxShotsPlatform
import os

/// The global shortcuts: ⌃⌥1–9 show a group, ⌃⌥0 shows every window, ⌥⇥ opens the group switcher and
/// ⌃⌥` cycles the active group's windows.
@MainActor
final class ShortcutController {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "shortcuts")
    private static let groupModifiers: NSEvent.ModifierFlags = [.control, .option]
    /// The number keys 1–9, whose virtual key codes are not consecutive.
    static let listGroupKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    private let workspaceController: WorkspaceController
    private let hotkeyCenter = HotkeyCenter()
    private lazy var switcher = SwitcherController(workspaceController: workspaceController, hotkeyCenter: hotkeyCenter)

    init(workspaceController: WorkspaceController) {
        self.workspaceController = workspaceController
    }

    /// Register every shortcut.
    func start() {
        hotkeyCenter.start()
        for (position, keyCode) in Self.listGroupKeyCodes.enumerated() {
            bind(Hotkey(keyCode: keyCode, modifiers: Self.groupModifiers), name: "group \(position + 1)") { [weak self] in
                self?.switchToGroup(atPosition: position)
            }
        }
        bind(Hotkey(keyCode: kVK_ANSI_0, modifiers: Self.groupModifiers), name: "all windows") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.switchTo(nil)
            }
        }
        bind(Hotkey(keyCode: kVK_ANSI_Grave, modifiers: Self.groupModifiers), name: "cycle windows") { [weak self] in
            guard let workspaceController = self?.workspaceController else {
                return
            }
            Task {
                await workspaceController.cycleActiveGroupWindow()
            }
        }
        bind(Hotkey(keyCode: kVK_Tab, modifiers: [.option]), name: "switcher") { [weak self] in
            self?.switcher.advance(by: 1)
        }
        bind(Hotkey(keyCode: kVK_Tab, modifiers: [.option, .shift]), name: "switcher backwards") { [weak self] in
            self?.switcher.advance(by: -1)
        }
    }

    func stop() {
        hotkeyCenter.stop()
    }

    private func bind(_ hotkey: Hotkey, name: String, action: @escaping @MainActor () -> Void) {
        if !hotkeyCenter.register(hotkey, action: action) {
            Self.logger.error("shortcut for \(name, privacy: .public) is taken by another application")
        }
    }

    private func switchToGroup(atPosition position: Int) {
        let listGroups = workspaceController.workspace.listGroups
        guard listGroups.indices.contains(position) else {
            return
        }
        let groupId = listGroups[position].groupId
        Task { [workspaceController] in
            await workspaceController.switchTo(groupId)
        }
    }
}
