import MuxShotsControl
import MuxShotsCore
import Observation
import os

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
/// the connected extensions report, the settings of each, and their meters. The extension keeps each tab's
/// settings across the app's restarts and hands them back on reconnecting. Here, settings last as long as the
/// tab's browser stays connected; when it disconnects, the extension gives every tab its sound back.
@MainActor
@Observable
final class BrowserTabMixer {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "browser")
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
    /// The tabs' videos shown in the sidebar.
    @ObservationIgnored let pictures = BrowserPictures()
    /// Whether a mixer shows the tabs' meters, so the browsers should measure and report their levels.
    @ObservationIgnored var isMeterWanted = false {
        didSet {
            guard isMeterWanted != oldValue else {
                return
            }
            for continuation in mapContinuations.values {
                continuation.yield(.meter(isWanted: isMeterWanted))
            }
            if !isMeterWanted {
                mapLevels = [:]
            }
        }
    }

    /// Register a newly connected extension.
    func openSession() -> BrowserSession {
        let sessionId = nextSessionId
        nextSessionId += 1
        let (commands, continuation) = AsyncStream.makeStream(of: BrowserCommand.self)
        continuation.yield(.hello)
        if isMeterWanted {
            continuation.yield(.meter(isWanted: true))
        }
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
        pictures.closeSession(sessionId)
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
            pictures.retitle(from: listSessionTabs, in: sessionId)
            // A tab muted or unmuted from the browser's own tab strip is muted or unmuted here too.
            for tab in listSessionTabs where mapPreviousTabs[tab.tabId].map({ $0.isMuted != tab.isMuted }) ?? tab.isMuted {
                mapSettings[BrowserTabKey(sessionId: sessionId, tabId: tab.tabId), default: MixerTrackSettings()].isMuted = tab.isMuted
            }
            // A tab keeps the settings the extension held for it while the app was away, and a tab the user
            // captured from the browser's toolbar is taken over without the app asking.
            for tab in listSessionTabs {
                let key = BrowserTabKey(sessionId: sessionId, tabId: tab.tabId)
                guard mapSettings[key] == nil else {
                    continue
                }
                if let settings = tab.settings {
                    mapSettings[key] = settings.clamped
                } else if tab.mode == .captured {
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
        case .pictureOffer(let tabId, let sdp):
            answerPicture(BrowserTabKey(sessionId: sessionId, tabId: tabId), offer: sdp)
        case .pictureState(let tabId, let isPaused):
            pictures.markPaused(isPaused, for: BrowserTabKey(sessionId: sessionId, tabId: tabId))
        case .pictureEnded(let tabId):
            pictures.close(BrowserTabKey(sessionId: sessionId, tabId: tabId))
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

    /// Show a tab's video in the sidebar, or stop showing it.
    func togglePicture(of browserTab: MixerBrowserTab) {
        let key = browserTab.key
        if pictures.contains(key) {
            pictures.close(key)
            mapContinuations[key.sessionId]?.yield(.pictureStop(tabId: key.tabId))
        } else {
            pictures.open(key, title: browserTab.tab.title) { [weak self] in
                self?.closePicture(key)
            }
            mapContinuations[key.sessionId]?.yield(.pictureStart(tabId: key.tabId))
        }
    }

    /// Accept a tab's offered video stream and send the answer back, or stop showing the tab when the stream
    /// cannot be accepted.
    private func answerPicture(_ key: BrowserTabKey, offer: String) {
        guard let picture = pictures.picture(for: key) else {
            return
        }
        Task {
            do {
                Self.logger.info("answering the video of tab \(key.tabId)")
                let answer = try await picture.receiver.answer(offer)
                Self.logger.info("answered the video of tab \(key.tabId) with \(answer.count) bytes")
                mapContinuations[key.sessionId]?.yield(.pictureAnswer(tabId: key.tabId, sdp: answer))
            } catch {
                Self.logger.error("cannot accept the video of tab \(key.tabId): \(error)")
                closePicture(key)
            }
        }
    }

    /// Stop showing a tab's video in the sidebar.
    func closePicture(_ key: BrowserTabKey) {
        pictures.close(key)
        mapContinuations[key.sessionId]?.yield(.pictureStop(tabId: key.tabId))
    }

    /// Play or pause a video shown in the sidebar.
    func playPicture(_ key: BrowserTabKey, isPlaying: Bool) {
        pictures.markPaused(!isPlaying, for: key)
        mapContinuations[key.sessionId]?.yield(.pictureControl(tabId: key.tabId, isPlaying: isPlaying))
    }

    /// Bring a tab and its browser window to the front.
    func focus(_ key: BrowserTabKey) {
        mapContinuations[key.sessionId]?.yield(.focusTab(tabId: key.tabId))
    }

    private func reloadTabs() {
        let listNewTabs = mapSessionTabs.keys.sorted().flatMap { sessionId in
            (mapSessionTabs[sessionId] ?? []).compactMap { tab -> MixerBrowserTab? in
                let key = BrowserTabKey(sessionId: sessionId, tabId: tab.tabId)
                guard tab.isAudible || tab.hasVideo || tab.mode != .idle || settings(of: key).isCaptureNeeded else {
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
