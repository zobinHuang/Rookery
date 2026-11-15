import Foundation
import RookeryCore

/// How the browser extension is treating a tab's sound.
public enum BrowserTabMode: String, Codable, Sendable {
    /// The tab plays as it always would.
    case idle
    /// The extension is processing the page's audio and video elements.
    case page
    /// The tab is taken over, but no audio or video element has played yet.
    case waiting
    /// The tab is taken over, but its sound comes from somewhere the page cannot be processed, such as
    /// protected or cross-site media; capturing the whole tab from the extension's button handles it.
    case blocked
    /// The extension is capturing all of the tab's sound.
    case captured
}

/// A browser tab, as the extension reports it.
public struct BrowserTab: Codable, Equatable, Sendable {
    public let tabId: Int
    public let windowId: Int
    public let title: String
    public let url: String
    /// The tab's icon, as an address the app can load.
    public let favIconUrl: String?
    /// Whether the tab is playing sound, heard or not.
    public let isAudible: Bool
    /// Whether the browser has the tab muted, by the mixer or from its own tab strip.
    public let isMuted: Bool
    public let mode: BrowserTabMode
    /// The settings the extension keeps for the tab, which outlive the app's restarts but not the tab.
    public let settings: MixerTrackSettings?
    /// Whether the tab plays a video that could be shown in the sidebar.
    public let hasVideo: Bool

    public init(
        tabId: Int,
        windowId: Int,
        title: String,
        url: String,
        favIconUrl: String?,
        isAudible: Bool,
        isMuted: Bool,
        mode: BrowserTabMode,
        settings: MixerTrackSettings? = nil,
        hasVideo: Bool = false
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.title = title
        self.url = url
        self.favIconUrl = favIconUrl
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.mode = mode
        self.settings = settings
        self.hasVideo = hasVideo
    }

    /// Read a tab, taking it as unmuted and without kept settings from an extension too old to say.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabId = try container.decode(Int.self, forKey: .tabId)
        windowId = try container.decode(Int.self, forKey: .windowId)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        favIconUrl = try container.decodeIfPresent(String.self, forKey: .favIconUrl)
        isAudible = try container.decode(Bool.self, forKey: .isAudible)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        mode = try container.decode(BrowserTabMode.self, forKey: .mode)
        settings = try container.decodeIfPresent(MixerTrackSettings.self, forKey: .settings)
        hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
    }
}

/// How loud a tab's channels are, 0 silent to 1 full scale.
public struct BrowserTabLevels: Codable, Equatable, Sendable {
    public let tabId: Int
    public let left: Float
    public let right: Float

    public init(tabId: Int, left: Float, right: Float) {
        self.tabId = tabId
        self.left = left
        self.right = right
    }
}

/// A message from the browser extension to the app.
public enum BrowserEvent: Codable, Equatable, Sendable {
    /// Every tab the extension knows of, sent whenever one changes.
    case tabs(listTabs: [BrowserTab])
    /// How loud the tabs being processed are now.
    case levels(listLevels: [BrowserTabLevels])
    /// A tab offers its video for the sidebar as a WebRTC stream, by its session description.
    case pictureOffer(tabId: Int, sdp: String)
    /// A video shown in the sidebar was paused or played.
    case pictureState(tabId: Int, isPaused: Bool)
    /// A video is no longer shown, as it ended, could not be shown or its page went away.
    case pictureEnded(tabId: Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case listTabs
        case listLevels
        case tabId
        case sdp
        case isPaused
    }

    private enum Kind: String, Codable {
        case tabs
        case levels
        case pictureOffer = "picture_offer"
        case pictureState = "picture_state"
        case pictureEnded = "picture_ended"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .tabs:
            self = .tabs(listTabs: try container.decode([BrowserTab].self, forKey: .listTabs))
        case .levels:
            self = .levels(listLevels: try container.decode([BrowserTabLevels].self, forKey: .listLevels))
        case .pictureOffer:
            self = .pictureOffer(
                tabId: try container.decode(Int.self, forKey: .tabId),
                sdp: try container.decode(String.self, forKey: .sdp)
            )
        case .pictureState:
            self = .pictureState(
                tabId: try container.decode(Int.self, forKey: .tabId),
                isPaused: try container.decode(Bool.self, forKey: .isPaused)
            )
        case .pictureEnded:
            self = .pictureEnded(tabId: try container.decode(Int.self, forKey: .tabId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tabs(let listTabs):
            try container.encode(Kind.tabs, forKey: .type)
            try container.encode(listTabs, forKey: .listTabs)
        case .levels(let listLevels):
            try container.encode(Kind.levels, forKey: .type)
            try container.encode(listLevels, forKey: .listLevels)
        case .pictureOffer(let tabId, let sdp):
            try container.encode(Kind.pictureOffer, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(sdp, forKey: .sdp)
        case .pictureState(let tabId, let isPaused):
            try container.encode(Kind.pictureState, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(isPaused, forKey: .isPaused)
        case .pictureEnded(let tabId):
            try container.encode(Kind.pictureEnded, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
        }
    }
}

/// A message from the app to the browser extension.
public enum BrowserCommand: Codable, Equatable, Sendable {
    /// The app is ready: the extension applies the settings it kept for its tabs again.
    case hello
    /// Treat a tab's sound as the settings say, taking it over or giving it back.
    case apply(tabId: Int, settings: MixerTrackSettings)
    /// Show a tab's video in the sidebar.
    case pictureStart(tabId: Int)
    /// Accept a tab's offered video stream, by the answer's session description.
    case pictureAnswer(tabId: Int, sdp: String)
    /// Stop showing a tab's video in the sidebar.
    case pictureStop(tabId: Int)
    /// Play or pause the video a tab shows in the sidebar.
    case pictureControl(tabId: Int, isPlaying: Bool)
    /// Bring a tab and its browser window to the front.
    case focusTab(tabId: Int)
    /// Start or stop measuring and reporting the tabs' levels, as a mixer shows their meters or none does.
    case meter(isWanted: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case tabId
        case settings
        case isPlaying
        case sdp
        case isWanted
    }

    private enum Kind: String, Codable {
        case hello
        case apply
        case pictureStart = "picture_start"
        case pictureAnswer = "picture_answer"
        case pictureStop = "picture_stop"
        case pictureControl = "picture_control"
        case focusTab = "focus_tab"
        case meter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello
        case .pictureStart:
            self = .pictureStart(tabId: try container.decode(Int.self, forKey: .tabId))
        case .pictureAnswer:
            self = .pictureAnswer(
                tabId: try container.decode(Int.self, forKey: .tabId),
                sdp: try container.decode(String.self, forKey: .sdp)
            )
        case .pictureStop:
            self = .pictureStop(tabId: try container.decode(Int.self, forKey: .tabId))
        case .pictureControl:
            self = .pictureControl(
                tabId: try container.decode(Int.self, forKey: .tabId),
                isPlaying: try container.decode(Bool.self, forKey: .isPlaying)
            )
        case .focusTab:
            self = .focusTab(tabId: try container.decode(Int.self, forKey: .tabId))
        case .meter:
            self = .meter(isWanted: try container.decode(Bool.self, forKey: .isWanted))
        case .apply:
            self = .apply(
                tabId: try container.decode(Int.self, forKey: .tabId),
                settings: try container.decode(MixerTrackSettings.self, forKey: .settings)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello:
            try container.encode(Kind.hello, forKey: .type)
        case .pictureStart(let tabId):
            try container.encode(Kind.pictureStart, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
        case .pictureAnswer(let tabId, let sdp):
            try container.encode(Kind.pictureAnswer, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(sdp, forKey: .sdp)
        case .pictureStop(let tabId):
            try container.encode(Kind.pictureStop, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
        case .pictureControl(let tabId, let isPlaying):
            try container.encode(Kind.pictureControl, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(isPlaying, forKey: .isPlaying)
        case .focusTab(let tabId):
            try container.encode(Kind.focusTab, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
        case .meter(let isWanted):
            try container.encode(Kind.meter, forKey: .type)
            try container.encode(isWanted, forKey: .isWanted)
        case .apply(let tabId, let settings):
            try container.encode(Kind.apply, forKey: .type)
            try container.encode(tabId, forKey: .tabId)
            try container.encode(settings, forKey: .settings)
        }
    }
}

/// The JSON spelling the extension speaks, snake_case as its TypeScript names are.
public enum BrowserWire {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
