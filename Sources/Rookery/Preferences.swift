import AppKit
import Carbon.HIToolbox
import Observation
import os
import RookeryCore
import RookeryPlatform

/// The appearance Rookery draws in. The high-contrast ones, after the editor themes of the same name, draw
/// on pure black or white and outline every panel, and the selected one in a second color.
enum Theme: String, CaseIterable {
    case light
    case dark
    case highContrastLight
    case highContrastDark

    /// The name the settings show.
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .highContrastLight: "Light High Contrast"
        case .highContrastDark: "Dark High Contrast"
        }
    }

    /// The system appearance that draws this theme's controls and text. An application cannot ask for the
    /// system's high-contrast appearances, which only its accessibility setting turns on, so the
    /// high-contrast themes draw their controls in the regular ones.
    var appearanceName: NSAppearance.Name {
        isDark ? .darkAqua : .aqua
    }

    /// Whether the theme draws light content on a dark background.
    var isDark: Bool {
        self == .dark || self == .highContrastDark
    }

    /// The theme of the same contrast on the other side of light and dark.
    var opposite: Theme {
        switch self {
        case .light: .dark
        case .dark: .light
        case .highContrastLight: .highContrastDark
        case .highContrastDark: .highContrastLight
        }
    }

    /// The theme an appearance draws in, at increased contrast when the system's accessibility setting
    /// asks for it.
    static func matching(_ appearance: NSAppearance) -> Theme {
        switch appearance.bestMatch(from: [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua: .dark
        case .accessibilityHighContrastAqua: .highContrastLight
        case .accessibilityHighContrastDarkAqua: .highContrastDark
        default: .light
        }
    }
}

/// The clock the Rookmaster log tells times by.
enum LogClock: String, CaseIterable {
    /// This Mac's time zone.
    case thisMac
    case utc

    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .utc: "UTC"
        }
    }

    var timeZone: TimeZone {
        switch self {
        case .thisMac: .current
        case .utc: TimeZone(identifier: "UTC") ?? .gmt
        }
    }
}

/// The user's settings, kept in `UserDefaults`; every change is saved at once and announced to observers.
@MainActor
@Observable
final class Preferences {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "preferences")
    private static let dropTrayKey = "isDropTrayEnabled"
    private static let returnDroppedKey = "isReturningDroppedWindows"
    private static let mixerEnabledKey = "isMixerEnabled"
    private static let groupModifiersKey = "groupModifiers"
    private static let showAllHotkeyKey = "showAllHotkey"
    private static let switcherHotkeyKey = "switcherHotkey"
    private static let cycleHotkeyKey = "cycleHotkey"
    private static let stageHotkeyKey = "stageHotkey"
    private static let stageSidebarCollapsedKey = "isStageSidebarCollapsed"
    private static let stageRightSidebarCollapsedKey = "isStageRightSidebarCollapsed"
    private static let stageRightSidebarTabKey = "stageRightSidebarTab"
    private static let themeKey = "theme"
    private static let screenSaverTextKey = "screenSaverText"
    private static let screenSaverTextSizeKey = "screenSaverTextSize"
    /// Where the world clock's cities were kept when they were time zones alone, read once to carry them over.
    private static let legacyClockTimeZonesKey = "clockTimeZoneIds"
    private static let clockCitiesKey = "clockCities"
    private static let agentAccountsKey = "agentAccounts"
    private static let roostAddressKey = "roostAddress"
    private static let logClockKey = "logClock"
    private static let ravenEngineKey = "ravenEngine"
    /// Where Claude Code keeps its default account, which is set up for the user when present.
    private static let defaultClaudeDirectory = "~/.claude"

    static let defaultGroupModifiers: NSEvent.ModifierFlags = [.control, .option]
    static let defaultShowAllHotkey = Hotkey(keyCode: kVK_ANSI_0, modifiers: [.control, .option])
    static let defaultSwitcherHotkey = Hotkey(keyCode: kVK_Tab, modifiers: [.option])
    static let defaultCycleHotkey = Hotkey(keyCode: kVK_ANSI_Grave, modifiers: [.control, .option])
    static let defaultStageHotkey = Hotkey(keyCode: kVK_Return, modifiers: [.control, .option])
    /// What the screen saver says while the user has set nothing.
    static let defaultScreenSaverText = "Be right back"
    static let defaultScreenSaverTextSize: Double = 72
    /// The sizes the screen saver's text can be set to, in points.
    static let screenSaverTextSizeRange: ClosedRange<Double> = 24...200

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any shortcut changes, so they can be registered again.
    @ObservationIgnored var onShortcutsChange: (() -> Void)?
    /// Called after the mixer is turned on or off, so it can start or give every application its sound back.
    @ObservationIgnored var onMixerEnabledChange: (() -> Void)?
    /// Called after the theme changes, so it can be applied.
    @ObservationIgnored var onThemeChange: (() -> Void)?
    /// Called after the world clock's cities change, so the stages can show them.
    @ObservationIgnored var onWorldClockChange: (() -> Void)?
    /// Called after the code agent accounts change, so their limits can be read again.
    @ObservationIgnored var onAgentAccountsChange: (() -> Void)?

    /// The code agent accounts whose plan limits the sidebar can show, in order.
    var listAgentAccounts: [AgentAccount] {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(listAgentAccounts), forKey: Self.agentAccountsKey)
            } catch {
                Self.logger.error("cannot store the code agent accounts: \(error)")
            }
            onAgentAccountsChange?()
        }
    }

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

    /// The text the screen saver shows in the content area, as the user typed it; empty for the default.
    /// The roost server the Agents list follows, as the user typed it; empty for none. Its token is in the
    /// keychain.
    var roostAddress: String {
        didSet {
            defaults.set(roostAddress, forKey: Self.roostAddressKey)
        }
    }

    /// The clock the Rookmaster log tells times by.
    var logClock: LogClock {
        didSet {
            defaults.set(logClock.rawValue, forKey: Self.logClockKey)
        }
    }

    /// The code agent a new conversation with Raven runs on: `claude` or `codex`.
    var ravenEngine: String {
        didSet {
            defaults.set(ravenEngine, forKey: Self.ravenEngineKey)
        }
    }

    var screenSaverText: String {
        didSet {
            defaults.set(screenSaverText, forKey: Self.screenSaverTextKey)
        }
    }

    /// The text the screen saver shows: the user's, else the default.
    var shownScreenSaverText: String {
        let text = screenSaverText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Self.defaultScreenSaverText : text
    }

    /// The screen saver's text size in points, within `screenSaverTextSizeRange`.
    var screenSaverTextSize: Double {
        didSet {
            defaults.set(screenSaverTextSize, forKey: Self.screenSaverTextSizeKey)
        }
    }

    /// Whether dragging a window offers the drop tray or panel.
    var isDropTrayEnabled: Bool {
        didSet {
            defaults.set(isDropTrayEnabled, forKey: Self.dropTrayKey)
        }
    }

    /// Whether the mixer runs: off by default, when no application's sound is taken over and the sidebar
    /// has no mixer.
    var isMixerEnabled: Bool {
        didSet {
            defaults.set(isMixerEnabled, forKey: Self.mixerEnabledKey)
            onMixerEnabledChange?()
        }
    }

    /// Whether a window dropped on Rookery goes back to where its drag started.
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

    /// Whether the stage shows its right sidebar as a narrow strip of icons.
    var isStageRightSidebarCollapsed: Bool {
        didSet {
            defaults.set(isStageRightSidebarCollapsed, forKey: Self.stageRightSidebarCollapsedKey)
        }
    }

    /// The right sidebar's tab: `calendar`, `mail` or `mixer`.
    var stageRightSidebarTab: String {
        didSet {
            defaults.set(stageRightSidebarTab, forKey: Self.stageRightSidebarTabKey)
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
        isMixerEnabled = defaults.bool(forKey: Self.mixerEnabledKey)
        isStageSidebarCollapsed = defaults.bool(forKey: Self.stageSidebarCollapsedKey)
        isStageRightSidebarCollapsed = defaults.bool(forKey: Self.stageRightSidebarCollapsedKey)
        stageRightSidebarTab = defaults.string(forKey: Self.stageRightSidebarTabKey) ?? "calendar"
        theme = defaults.string(forKey: Self.themeKey).flatMap(Theme.init(rawValue:))
        screenSaverText = defaults.string(forKey: Self.screenSaverTextKey) ?? ""
        roostAddress = defaults.string(forKey: Self.roostAddressKey) ?? ""
        logClock = defaults.string(forKey: Self.logClockKey).flatMap(LogClock.init(rawValue:)) ?? .thisMac
        ravenEngine = defaults.string(forKey: Self.ravenEngineKey) ?? RavenConversation.engineClaude
        screenSaverTextSize = (defaults.object(forKey: Self.screenSaverTextSizeKey) as? Double)
            .map { min(max($0, Self.screenSaverTextSizeRange.lowerBound), Self.screenSaverTextSizeRange.upperBound) }
            ?? Self.defaultScreenSaverTextSize
        listClockCities = Self.loadClockCities(from: defaults)
        listAgentAccounts = Self.loadAgentAccounts(from: defaults)
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
    /// The stored accounts, else Claude Code's default account when Claude Code is set up.
    private static func loadAgentAccounts(from defaults: UserDefaults) -> [AgentAccount] {
        if let data = defaults.data(forKey: agentAccountsKey) {
            do {
                return try JSONDecoder().decode([AgentAccount].self, from: data)
            } catch {
                logger.error("cannot read the code agent accounts: \(error)")
            }
        }
        guard FileManager.default.fileExists(atPath: NSString(string: defaultClaudeDirectory).expandingTildeInPath) else {
            return []
        }
        return [AgentAccount(harness: .claudeCode, label: AgentHarness.claudeCode.title, configDirectory: nil)]
    }

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
