import Foundation
import MuxShotsCore

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
    /// Whether the tab is playing sound.
    public let isAudible: Bool
    public let mode: BrowserTabMode

    public init(
        tabId: Int,
        windowId: Int,
        title: String,
        url: String,
        favIconUrl: String?,
        isAudible: Bool,
        mode: BrowserTabMode
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.title = title
        self.url = url
        self.favIconUrl = favIconUrl
        self.isAudible = isAudible
        self.mode = mode
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

    private enum CodingKeys: String, CodingKey {
        case type
        case listTabs
        case listLevels
    }

    private enum Kind: String, Codable {
        case tabs
        case levels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .tabs:
            self = .tabs(listTabs: try container.decode([BrowserTab].self, forKey: .listTabs))
        case .levels:
            self = .levels(listLevels: try container.decode([BrowserTabLevels].self, forKey: .listLevels))
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
        }
    }
}

/// A message from the app to the browser extension.
public enum BrowserCommand: Codable, Equatable, Sendable {
    /// Treat a tab's sound as the settings say, taking it over or giving it back.
    case apply(tabId: Int, settings: MixerTrackSettings)

    private enum CodingKeys: String, CodingKey {
        case type
        case tabId
        case settings
    }

    private enum Kind: String, Codable {
        case apply
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
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
