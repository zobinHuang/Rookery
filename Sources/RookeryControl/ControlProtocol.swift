import Foundation
import RookeryCore

/// A request `rookeryctl` sends to the running app.
public enum ControlRequest: Codable, Sendable {
    /// Reply once with the groups and the observed state of their windows.
    case list
    /// Reply with the groups and their windows, then stream every window change until the client disconnects.
    case watch
    /// Manage a window in a group, named or by 1-based position, or in a new group when nil.
    case manage(windowId: WindowId, groupNameOrPosition: String?)
    /// Stop managing a window.
    case release(windowId: WindowId)
    /// Act on a managed window.
    case act(action: WindowAction, windowId: WindowId)
    /// Show a group, named or by 1-based position, hiding the others; nil shows every managed window.
    case switchGroup(nameOrPosition: String?)
    /// Open or close the stage.
    case stage(isOpen: Bool)
    /// Reply with the mixer's tracks.
    case mixer
    /// Change how the mixer treats an application's or a browser tab's sound, taking it over or giving it
    /// back as the settings say, then reply with the mixer's tracks.
    case mixerApply(target: MixerTarget, settings: MixerTrackSettings)
    /// Show a browser tab's video in the sidebar, or stop showing it, then reply with the mixer's tracks.
    case mixerTogglePicture(sessionId: Int, tabId: Int)
    /// Reply with the code agent accounts the sidebar shows and their plan limits.
    case agentUsage
    /// Keep the connection open for the browser extension: `BrowserEvent`s come in and `BrowserCommand`s go
    /// out, one JSON line each, spelled as `BrowserWire` says, until either side closes. The browser's
    /// process is the one that started the native messaging host.
    case browserSession(browserProcessId: Int32)
    /// Report what the app can read of Mail and the calendars: its access, the shape of Mail's library, the
    /// accounts and the calendars; no message's content.
    case mailProbe
    /// Run one of Rookery's mail and calendar tools, as the `rookery-mail` MCP server asks for a code agent,
    /// with its arguments as a JSON object.
    case mailTool(name: String, argumentsJSON: String)
    /// Ask the user whether Raven may take an action on their Mac, as Claude Code asks its permission
    /// prompt tool; answered once the user decides, however long that takes.
    case ravenApproval(RavenApprovalRequest)
}

/// What a mixer track carries: an application's sound, or one browser tab's.
public enum MixerTarget: Codable, Equatable, Sendable, CustomStringConvertible {
    case application(bundleId: String)
    /// A tab of a browser connected through the Rookery extension.
    case browserTab(sessionId: Int, tabId: Int)

    private static let tabPrefix = "tab:"
    private static let tabSeparator: Character = "."

    /// Read a target as `description` writes it: a bundle id, or `tab:<session>.<tab>`.
    public init(_ text: String) {
        let listParts = text.dropFirst(Self.tabPrefix.count).split(separator: Self.tabSeparator)
        if
            text.hasPrefix(Self.tabPrefix),
            listParts.count == 2,
            let sessionId = Int(listParts[0]),
            let tabId = Int(listParts[1])
        {
            self = .browserTab(sessionId: sessionId, tabId: tabId)
        } else {
            self = .application(bundleId: text)
        }
    }

    public var description: String {
        switch self {
        case .application(let bundleId):
            bundleId
        case .browserTab(let sessionId, let tabId):
            "\(Self.tabPrefix)\(sessionId)\(Self.tabSeparator)\(tabId)"
        }
    }
}

/// A browser tab's sound as the mixer sees it.
public struct MixerTabStatus: Codable, Equatable, Sendable {
    public let sessionId: Int
    public let tab: BrowserTab
    public let settings: MixerTrackSettings
    /// How loud the tab is now, 0 to 1.
    public let level: Float
    /// The size of the latest picture of the tab's video shown in the sidebar, in pixels: nil while it is
    /// not shown, zero until its first picture arrives.
    public let pictureSize: CGSize?

    public init(sessionId: Int, tab: BrowserTab, settings: MixerTrackSettings, level: Float, pictureSize: CGSize?) {
        self.sessionId = sessionId
        self.tab = tab
        self.settings = settings
        self.level = level
        self.pictureSize = pictureSize
    }
}

/// A code agent account as the sidebar shows it: its limits as last read, or why they could not be.
public struct AgentAccountStatus: Codable, Equatable, Sendable {
    public let account: AgentAccount
    public let usage: AgentUsage?
    public let error: String?

    public init(account: AgentAccount, usage: AgentUsage?, error: String?) {
        self.account = account
        self.usage = usage
        self.error = error
    }
}

/// An application's sound as the mixer sees it.
public struct MixerTrackStatus: Codable, Equatable, Sendable {
    public let bundleId: String
    public let name: String
    /// Whether the application, or a helper of it, is playing sound.
    public let isPlaying: Bool
    /// Whether Rookery is capturing the sound right now, rather than waiting for it to play.
    public let isCapturing: Bool
    /// Why taking the sound over last failed.
    public let error: String?
    public let settings: MixerTrackSettings

    public init(bundleId: String, name: String, isPlaying: Bool, isCapturing: Bool, error: String?, settings: MixerTrackSettings) {
        self.bundleId = bundleId
        self.name = name
        self.isPlaying = isPlaying
        self.isCapturing = isCapturing
        self.error = error
        self.settings = settings
    }
}

/// A message the running app sends back.
public enum ControlMessage: Codable, Sendable {
    case workspace(listGroups: [WindowGroup], setActiveGroupIds: Set<GroupId>, listWindows: [WindowRecord])
    case change(WindowChange)
    /// The mixer's tracks, with how loud each captured one is now, 0 to 1, by bundle id,
    /// and the browser tabs it can mix.
    case mixer(listTracks: [MixerTrackStatus], mapLevels: [String: Float], listTabs: [MixerTabStatus])
    /// The code agent accounts the sidebar shows, with their limits, and when they are read next.
    case agentUsage(listAccounts: [AgentAccountStatus], nextRefreshAt: Date?)
    case mailProbe(MailProbeReport)
    /// What a mail or calendar tool gave: its text, and whether it failed.
    case mailToolResult(text: String, isError: Bool)
    /// Whether the user allowed the action Raven asked to take.
    case ravenApprovalResult(isAllowed: Bool)
    case done
    case failure(message: String)
}

/// What the app can read of Mail and the calendars, for checking it can before reading messages.
public struct MailProbeReport: Codable, Sendable {
    /// Mail's library directory, or nil when it cannot be found.
    public var libraryPath: String?
    public var listTables: [MailTableShape]
    /// Some mailboxes' URLs, which name their account and folder.
    public var listMailboxURLs: [String]
    /// Some message files' paths under the library, which show how they are laid out.
    public var listMessagePaths: [String]
    public var listAccounts: [MailScriptAccount]
    public var calendarAuthorization: String
    public var listCalendars: [CalendarSummary]
    /// What could not be read, and why.
    public var listProblems: [String]

    public init() {
        listTables = []
        listMailboxURLs = []
        listMessagePaths = []
        listAccounts = []
        calendarAuthorization = ""
        listCalendars = []
        listProblems = []
    }
}

/// Where the running app listens for control connections.
public enum ControlSocket {
    private static let fileName = "control.sock"

    /// The socket path, inside the app's data directory.
    public static var url: URL {
        DataDirectory.file(named: fileName)
    }
}
