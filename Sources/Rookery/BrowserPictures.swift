import AppKit
import Observation
import RookeryControl

/// A browser tab's video shown in the sidebar: the receiver its stream plays in, and what its tile shows
/// about it. Only its tile observes it.
@MainActor
@Observable
final class BrowserPicture: Identifiable {
    let key: BrowserTabKey
    var title: String
    @ObservationIgnored let receiver = PictureReceiver()
    /// The video's size in pixels, zero until its stream starts.
    var videoSize: CGSize = .zero
    /// Whether the stream has started playing.
    var isStreaming = false
    var isPaused = false

    init(key: BrowserTabKey, title: String) {
        self.key = key
        self.title = title
    }

    nonisolated var id: BrowserTabKey {
        key
    }

    /// Width over height.
    var aspectRatio: CGFloat {
        videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : BrowserPictures.defaultAspectRatio
    }
}

/// The browser videos shown in the sidebar, in the order they were opened. The list changes only as videos
/// are opened and closed; each video's state changes on the video itself, so it redraws only its tile.
@MainActor
@Observable
final class BrowserPictures {
    /// The shape assumed until a video's stream starts.
    static let defaultAspectRatio: CGFloat = 16 / 9

    private(set) var listPictures: [BrowserPicture] = []
    /// Called after a video is opened or closed.
    @ObservationIgnored var onChange: (() -> Void)?

    func contains(_ key: BrowserTabKey) -> Bool {
        listPictures.contains { $0.key == key }
    }

    func picture(for key: BrowserTabKey) -> BrowserPicture? {
        listPictures.first { $0.key == key }
    }

    /// Make room for a tab's video, before its stream arrives.
    ///
    /// - Parameters:
    ///   - key: the tab
    ///   - title: the tab's title
    ///   - onFailure: called when the stream fails
    func open(_ key: BrowserTabKey, title: String, onFailure: @escaping () -> Void) {
        guard !contains(key) else {
            return
        }
        let picture = BrowserPicture(key: key, title: title)
        picture.receiver.onSize = { [weak picture] size in
            picture?.videoSize = size
        }
        picture.receiver.onPlaying = { [weak picture] in
            picture?.isStreaming = true
        }
        picture.receiver.onFailure = onFailure
        listPictures.append(picture)
        onChange?()
    }

    func close(_ key: BrowserTabKey) {
        guard let picture = picture(for: key) else {
            return
        }
        picture.receiver.close()
        listPictures.removeAll { $0.key == key }
        onChange?()
    }

    /// Forget every video of a browser that disconnected.
    func closeSession(_ sessionId: Int) {
        let listSessionPictures = listPictures.filter { $0.key.sessionId == sessionId }
        guard !listSessionPictures.isEmpty else {
            return
        }
        for picture in listSessionPictures {
            picture.receiver.close()
        }
        listPictures.removeAll { $0.key.sessionId == sessionId }
        onChange?()
    }

    func markPaused(_ isPaused: Bool, for key: BrowserTabKey) {
        listPictures.first { $0.key == key }?.isPaused = isPaused
    }

    /// Keep each video's title in step with its tab's.
    func retitle(from listTabs: [BrowserTab], in sessionId: Int) {
        for tab in listTabs {
            let key = BrowserTabKey(sessionId: sessionId, tabId: tab.tabId)
            if let picture = listPictures.first(where: { $0.key == key }), picture.title != tab.title {
                picture.title = tab.title
            }
        }
    }
}
