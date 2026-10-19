import MuxShotsControl
import MuxShotsCore
import Observation

/// A tab of one connected browser, which identifies it across the browsers connected at once.
struct BrowserTabKey: Hashable, Sendable {
    let sessionId: Int
    let tabId: Int
}

/// A connected browser extension: its id, and the commands waiting to be sent to it.
struct BrowserSession: Sendable {
    let sessionId: Int
    let commands: AsyncStream<BrowserCommand>
}

/// A tab as the mixer shows it.
struct MixerBrowserTab: Identifiable, Equatable {
    let key: BrowserTabKey
    let tab: BrowserTab

    var id: BrowserTabKey {
        key
    }
}

/// The browser tabs the mixer can treat one by one, through the MuxShots browser extension: which tabs
/// the connected extensions report, the settings of each, and their meters. Settings last as long as the
/// tab's browser stays connected; when it disconnects, the extension gives every tab its sound back.
@MainActor
@Observable
final class BrowserTabMixer {
    /// How much of its level a tab's meter keeps from one report to the next, so it falls back smoothly.
    private static let meterDecay: Float = 0.7

    @ObservationIgnored private var mapContinuations: [Int: AsyncStream<BrowserCommand>.Continuation] = [:]
    @ObservationIgnored private var nextSessionId = 1
    @ObservationIgnored private var mapSessionTabs: [Int: [BrowserTab]] = [:]
    private var mapSettings: [BrowserTabKey: MixerTrackSettings] = [:]
    /// The tabs worth a strip: those playing or taken over, in the order their browsers list them.
    private(set) var listTabs: [MixerBrowserTab] = []
    /// How loud each processed tab is now, for its meter.
    private(set) var mapLevels: [BrowserTabKey: MixerLevels] = [:]
    /// How many browsers have the extension connected.
    private(set) var sessionCount = 0

    /// Register a newly connected extension.
    func openSession() -> BrowserSession {
        let sessionId = nextSessionId
        nextSessionId += 1
        let (commands, continuation) = AsyncStream.makeStream(of: BrowserCommand.self)
        mapContinuations[sessionId] = continuation
        sessionCount = mapContinuations.count
        return BrowserSession(sessionId: sessionId, commands: commands)
    }

    /// Forget an extension that disconnected, with its tabs and their settings.
    func closeSession(_ sessionId: Int) {
        mapContinuations.removeValue(forKey: sessionId)?.finish()
        mapSessionTabs[sessionId] = nil
        mapSettings = mapSettings.filter { $0.key.sessionId != sessionId }
        mapLevels = mapLevels.filter { $0.key.sessionId != sessionId }
        sessionCount = mapContinuations.count
        reloadTabs()
    }

    /// Take in what an extension reports.
    func receive(_ event: BrowserEvent, in sessionId: Int) {
        switch event {
        case .tabs(let listSessionTabs):
            let mapPreviousTabs = Dictionary(
                (mapSessionTabs[sessionId] ?? []).map { ($0.tabId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            mapSessionTabs[sessionId] = listSessionTabs
            // A tab muted or unmuted from the browser's own tab strip is muted or unmuted here too.
            for tab in listSessionTabs where mapPreviousTabs[tab.tabId].map({ $0.isMuted != tab.isMuted }) ?? tab.isMuted {
                mapSettings[BrowserTabKey(sessionId: sessionId, tabId: tab.tabId), default: MixerTrackSettings()].isMuted = tab.isMuted
            }
            // A tab the user captured from the browser's toolbar is taken over without the app asking.
            for tab in listSessionTabs where tab.mode == .captured {
                let key = BrowserTabKey(sessionId: sessionId, tabId: tab.tabId)
                if mapSettings[key] == nil {
                    var settings = MixerTrackSettings()
                    settings.isTakenOver = true
                    mapSettings[key] = settings
                }
            }
            reloadTabs()
        case .levels(let listLevels):
            var mapNewLevels = mapLevels.filter { $0.key.sessionId != sessionId }
            for levels in listLevels {
                let key = BrowserTabKey(sessionId: sessionId, tabId: levels.tabId)
                let previous = mapLevels[key] ?? MixerLevels()
                mapNewLevels[key] = MixerLevels(
                    left: max(levels.left, previous.left * Self.meterDecay),
                    right: max(levels.right, previous.right * Self.meterDecay)
                )
            }
            if mapNewLevels != mapLevels {
                mapLevels = mapNewLevels
            }
        }
    }

    func settings(of key: BrowserTabKey) -> MixerTrackSettings {
        mapSettings[key] ?? MixerTrackSettings()
    }

    /// Change a tab's settings and send them to its browser.
    func update(_ key: BrowserTabKey, _ change: (inout MixerTrackSettings) -> Void) {
        var settings = settings(of: key)
        change(&settings)
        settings = settings.clamped
        mapSettings[key] = settings
        mapContinuations[key.sessionId]?.yield(.apply(tabId: key.tabId, settings: settings))
        reloadTabs()
    }

    private func reloadTabs() {
        let listNewTabs = mapSessionTabs.keys.sorted().flatMap { sessionId in
            (mapSessionTabs[sessionId] ?? []).compactMap { tab -> MixerBrowserTab? in
                let key = BrowserTabKey(sessionId: sessionId, tabId: tab.tabId)
                guard tab.isAudible || tab.mode != .idle || settings(of: key).isCaptureNeeded else {
                    return nil
                }
                return MixerBrowserTab(key: key, tab: tab)
            }
        }
        if listNewTabs != listTabs {
            listTabs = listNewTabs
        }
    }
}
