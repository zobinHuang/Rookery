import AppKit
import Carbon.HIToolbox
import MuxShotsPlatform
import Observation
import os

/// The appearance MuxShots draws in.
enum Theme: String {
    case light
    case dark
}

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
    private static let stageHotkeyKey = "stageHotkey"
    private static let stageSidebarCollapsedKey = "isStageSidebarCollapsed"
    private static let themeKey = "theme"
    /// Where the world clock's cities were kept when they were time zones alone, read once to carry them over.
    private static let legacyClockTimeZonesKey = "clockTimeZoneIds"
    private static let clockCitiesKey = "clockCities"

    static let defaultGroupModifiers: NSEvent.ModifierFlags = [.control, .option]
    static let defaultShowAllHotkey = Hotkey(keyCode: kVK_ANSI_0, modifiers: [.control, .option])
    static let defaultSwitcherHotkey = Hotkey(keyCode: kVK_Tab, modifiers: [.option])
    static let defaultCycleHotkey = Hotkey(keyCode: kVK_ANSI_Grave, modifiers: [.control, .option])
    static let defaultStageHotkey = Hotkey(keyCode: kVK_Return, modifiers: [.control, .option])

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any shortcut changes, so they can be registered again.
    @ObservationIgnored var onShortcutsChange: (() -> Void)?
    /// Called after the theme changes, so it can be applied.
    @ObservationIgnored var onThemeChange: (() -> Void)?
    /// Called after the world clock's cities change, so the stages can show them.
    @ObservationIgnored var onWorldClockChange: (() -> Void)?

    /// The cities the world clock shows, in order.
    var listClockCities: [WorldClockCity] {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(listClockCities), forKey: Self.clockCitiesKey)
            } catch {
                Self.logger.error("cannot store the world clock's cities: \(error)")
            }
            onWorldClockChange?()
        }
    }

    /// The appearance the user chose, or nil to follow the system's.
    var theme: Theme? {
        didSet {
            defaults.set(theme?.rawValue, forKey: Self.themeKey)
            onThemeChange?()
        }
    }

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

    /// Whether the stage shows its sidebar as a narrow strip of icons.
    var isStageSidebarCollapsed: Bool {
        didSet {
            defaults.set(isStageSidebarCollapsed, forKey: Self.stageSidebarCollapsedKey)
        }
    }

    /// Opens or closes the stage.
    var stageHotkey: Hotkey {
        didSet {
            store(stageHotkey, forKey: Self.stageHotkeyKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDropTrayEnabled = defaults.object(forKey: Self.dropTrayKey) as? Bool ?? true
        isReturningDroppedWindows = defaults.object(forKey: Self.returnDroppedKey) as? Bool ?? true
        isStageSidebarCollapsed = defaults.bool(forKey: Self.stageSidebarCollapsedKey)
        theme = defaults.string(forKey: Self.themeKey).flatMap(Theme.init(rawValue:))
        listClockCities = Self.loadClockCities(from: defaults)
        groupModifiers = (defaults.object(forKey: Self.groupModifiersKey) as? UInt)
            .map(NSEvent.ModifierFlags.init(rawValue:)) ?? Self.defaultGroupModifiers
        showAllHotkey = Self.load(forKey: Self.showAllHotkeyKey, from: defaults) ?? Self.defaultShowAllHotkey
        switcherHotkey = Self.load(forKey: Self.switcherHotkeyKey, from: defaults) ?? Self.defaultSwitcherHotkey
        cycleHotkey = Self.load(forKey: Self.cycleHotkeyKey, from: defaults) ?? Self.defaultCycleHotkey
        stageHotkey = Self.load(forKey: Self.stageHotkeyKey, from: defaults) ?? Self.defaultStageHotkey
    }

    /// Put every shortcut back to its default.
    func restoreDefaultShortcuts() {
        groupModifiers = Self.defaultGroupModifiers
        showAllHotkey = Self.defaultShowAllHotkey
        switcherHotkey = Self.defaultSwitcherHotkey
        cycleHotkey = Self.defaultCycleHotkey
        stageHotkey = Self.defaultStageHotkey
    }

    private func store(_ hotkey: Hotkey, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(hotkey), forKey: key)
        } catch {
            Self.logger.error("cannot save shortcut \(key, privacy: .public): \(error, privacy: .public)")
        }
        onShortcutsChange?()
    }

    /// The stored cities, else those kept as time zones alone by earlier versions, else the defaults.
    private static func loadClockCities(from defaults: UserDefaults) -> [WorldClockCity] {
        if let data = defaults.data(forKey: clockCitiesKey) {
            do {
                return try JSONDecoder().decode([WorldClockCity].self, from: data)
            } catch {
                logger.error("cannot read the world clock's cities: \(error)")
            }
        }
        if let listTimeZoneIds = defaults.stringArray(forKey: legacyClockTimeZonesKey) {
            return listTimeZoneIds.map(WorldClock.city(forTimeZoneId:))
        }
        return WorldClock.listDefaultCities
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
