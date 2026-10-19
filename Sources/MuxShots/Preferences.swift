import AppKit
import Carbon.HIToolbox
import MuxShotsPlatform
import Observation
import os

/// The user's settings, kept in `UserDefaults`; every change is saved at once and announced to observers.
@MainActor
@Observable
final class Preferences {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "preferences")
    private static let dropTrayKey = "isDropTrayEnabled"
    private static let returnDroppedKey = "isReturningDroppedWindows"
    private static let groupModifiersKey = "groupModifiers"
    private static let showAllHotkeyKey = "showAllHotkey"
    private static let switcherHotkeyKey = "switcherHotkey"
    private static let cycleHotkeyKey = "cycleHotkey"

    static let defaultGroupModifiers: NSEvent.ModifierFlags = [.control, .option]
    static let defaultShowAllHotkey = Hotkey(keyCode: kVK_ANSI_0, modifiers: [.control, .option])
    static let defaultSwitcherHotkey = Hotkey(keyCode: kVK_Tab, modifiers: [.option])
    static let defaultCycleHotkey = Hotkey(keyCode: kVK_ANSI_Grave, modifiers: [.control, .option])

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any shortcut changes, so they can be registered again.
    @ObservationIgnored var onShortcutsChange: (() -> Void)?

    /// Whether dragging a window offers the drop tray or panel.
    var isDropTrayEnabled: Bool {
        didSet {
            defaults.set(isDropTrayEnabled, forKey: Self.dropTrayKey)
        }
    }

    /// Whether a window dropped on MuxShots goes back to where its drag started.
    var isReturningDroppedWindows: Bool {
        didSet {
            defaults.set(isReturningDroppedWindows, forKey: Self.returnDroppedKey)
        }
    }

    /// The modifiers that, with 1–9, show a group.
    var groupModifiers: NSEvent.ModifierFlags {
        didSet {
            defaults.set(groupModifiers.rawValue, forKey: Self.groupModifiersKey)
            onShortcutsChange?()
        }
    }

    var showAllHotkey: Hotkey {
        didSet {
            store(showAllHotkey, forKey: Self.showAllHotkeyKey)
        }
    }

    /// Opens the group switcher; its modifiers are the ones held while choosing, and adding ⇧ goes backwards.
    var switcherHotkey: Hotkey {
        didSet {
            store(switcherHotkey, forKey: Self.switcherHotkeyKey)
        }
    }

    var cycleHotkey: Hotkey {
        didSet {
            store(cycleHotkey, forKey: Self.cycleHotkeyKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDropTrayEnabled = defaults.object(forKey: Self.dropTrayKey) as? Bool ?? true
        isReturningDroppedWindows = defaults.object(forKey: Self.returnDroppedKey) as? Bool ?? true
        groupModifiers = (defaults.object(forKey: Self.groupModifiersKey) as? UInt)
            .map(NSEvent.ModifierFlags.init(rawValue:)) ?? Self.defaultGroupModifiers
        showAllHotkey = Self.load(forKey: Self.showAllHotkeyKey, from: defaults) ?? Self.defaultShowAllHotkey
        switcherHotkey = Self.load(forKey: Self.switcherHotkeyKey, from: defaults) ?? Self.defaultSwitcherHotkey
        cycleHotkey = Self.load(forKey: Self.cycleHotkeyKey, from: defaults) ?? Self.defaultCycleHotkey
    }

    /// Put every shortcut back to its default.
    func restoreDefaultShortcuts() {
        groupModifiers = Self.defaultGroupModifiers
        showAllHotkey = Self.defaultShowAllHotkey
        switcherHotkey = Self.defaultSwitcherHotkey
        cycleHotkey = Self.defaultCycleHotkey
    }

    private func store(_ hotkey: Hotkey, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(hotkey), forKey: key)
        } catch {
            Self.logger.error("cannot save shortcut \(key, privacy: .public): \(error, privacy: .public)")
        }
        onShortcutsChange?()
    }

    private static func load(forKey key: String, from defaults: UserDefaults) -> Hotkey? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Hotkey.self, from: data)
        } catch {
            logger.error("ignoring unreadable shortcut \(key, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}
