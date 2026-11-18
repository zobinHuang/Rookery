import Observation
import RookeryCore
import SwiftUI

/// Where the user left the agents' pages and the Rookmaster console, so going back to one finds it as it
/// was: the tab, the selection, the filters and how far each scroll area was scrolled. Kept while the app
/// runs, shared by every stage.
@MainActor
@Observable
final class PageMemory {
    var rookmasterTab = RookmasterTab.board
    /// The message the mail page shows, by its id in Mail's library.
    var selectedMailId: Int?
    var rookmasterSelectedRef: FleetRef?
    var panelTab = RookmasterPanelTab.raven
    /// The height the user dragged the panel to.
    var panelHeight = RookmasterPanel.defaultHeight
    var isPanelExpanded = true
    var logFilter = ""
    var logClearedThroughSeq = 0
    var boardQuery = ""
    var boardWindow = BoardWindow.all
    var isBoardLiveOnly = true
    var setBoardHiddenKinds: Set<String> = []
    var isBoardLocked = false
    var mapBoardFrozenOrder: [String: [FleetRef]] = [:]
    var boardSelectedRef: FleetRef?
    /// The agent whose subagents the board lays out in a column beside the agents, if any.
    var boardSubagentsOf: String?
    /// The repositories whose skills the board lays out one by one, by repository address; the others
    /// fold their skills into one card.
    var setBoardOpenRepos: Set<String> = []
    /// The folded runs of tool calls the user opened in each agent's conversation, by agent.
    var mapOpenTranscriptBlocks: [String: Set<Int>] = [:]
    /// Each kind list's search, by kind.
    var mapListQueries: [String: String] = [:]
    /// How far each scroll area was scrolled, by the area's key: from the top, or for an area that
    /// follows its end, how far above its bottom.
    @ObservationIgnored var mapScrollOffsets: [String: CGPoint] = [:]
    /// What is typed to Raven in the Rookmaster console and not yet sent.
    var ravenDraft = ""
    /// The section of the settings shown.
    var settingsPane = SettingsPane.general
    /// The person open in the settings, as far as the user changed them.
    var personDraft: PersonDraft?
    /// The roost address and token typed in the settings and not yet used; nil for the ones kept.
    var roostAddressDraft: String?
    var roostTokenDraft: String?
    /// The git host's token being added or replaced in the settings, as the user left it; kept while the
    /// app runs, never written down.
    var gitCredentialDraft: GitCredentialDraft?
    /// The search for a city to add to the world clock.
    @ObservationIgnored let clockCitySearch = WorldClockCitySearch()
}

/// A token for a git host being added or replaced in the settings, as the user left it: the host being
/// replaced (empty for a new one), the host, the token, the user name, the repository to try it on and
/// what trying it said.
struct GitCredentialDraft {
    let replacedHost: String
    var host: String
    var token = ""
    var username: String
    var repo = ""
    var checkResult: String?
}

/// A person open in the settings to change, as the user left them: their name, their addresses, an
/// address being typed and a picture being framed for their photo.
struct PersonDraft {
    let personId: String
    /// Whether the person was just added, so cancelling removes them.
    let isNew: Bool
    var name: String
    var listAddresses: [String]
    var newAddress = ""
    var croppedPicture: NSImage?
}

/// A scroll area that opens where the user left it, by a key; one that follows its end, as a
/// conversation does, opens at its bottom the first time without moving there, and keeps to the bottom as
/// it grows while the user is there, but not after they scrolled up.
struct RememberedScroll: ViewModifier {
    let key: String
    let memory: PageMemory
    /// Whether the area follows its end.
    var followsEnd = false
    /// Whether the content is in: the offset is put back only then.
    var isReady = true
    /// Changes when content is added at the end.
    var endToken = 0
    /// Changes when the user acts to see the end, which brings it into view wherever the area was.
    var jumpToken = 0

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(RememberedScrollPosition(
                key: key,
                memory: memory,
                followsEnd: followsEnd,
                isReady: isReady,
                endToken: endToken,
                jumpToken: jumpToken
            ))
        } else {
            content.defaultScrollAnchor(followsEnd ? .bottom : .topLeading)
        }
    }
}

/// `RememberedScroll` where the scroll position can be read and set.
@available(macOS 15, *)
private struct RememberedScrollPosition: ViewModifier {
    /// How near the bottom still counts as being there.
    private static let bottomSlack: CGFloat = 24
    /// How long a burst of arriving content is gathered before the end is brought into view.
    private static let followDelay: Duration = .milliseconds(150)

    let key: String
    let memory: PageMemory
    let followsEnd: Bool
    let isReady: Bool
    let endToken: Int
    let jumpToken: Int

    @State private var position = ScrollPosition()
    @State private var isRestored = false
    @State private var isAtEnd = true
    /// The latest geometry, kept where changing it redraws nothing: it changes on every frame the area
    /// scrolls and every time its content grows.
    @State private var latest = LatestScrollGeometry()
    /// Whether the user is moving the area, by dragging, the wheel or the glide after: only then does
    /// where it stands say where they want to be, not when Rookery moves it or its content grows.
    @State private var isUserScrolling = false
    /// The scroll to the end waiting for a burst of content to finish arriving.
    @State private var followTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(followsEnd ? .bottom : .topLeading, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                latest.geometry = geometry
                guard isRestored else {
                    restoreIfReady()
                    return
                }
                let fromBottom = geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y
                let isNowAtEnd = fromBottom < Self.bottomSlack
                if isUserScrolling, isAtEnd != isNowAtEnd {
                    isAtEnd = isNowAtEnd
                }
                memory.mapScrollOffsets[key] = followsEnd
                    ? CGPoint(x: 0, y: max(0, fromBottom))
                    : geometry.contentOffset
            }
            .onScrollPhaseChange { _, phase in
                let isByUser = phase == .tracking || phase == .interacting || phase == .decelerating
                if isUserScrolling != isByUser {
                    isUserScrolling = isByUser
                }
            }
            .onChange(of: isReady) {
                restoreIfReady()
            }
            .onChange(of: endToken) {
                followEnd()
            }
            .onChange(of: jumpToken) {
                isAtEnd = true
                withAnimation(.easeOut(duration: 0.25)) {
                    position.scrollTo(edge: .bottom)
                }
            }
    }

    /// Keep to the end as content arrives, once for a burst of it: lines streaming in a few at a time
    /// bring the end into view together rather than one scroll each.
    private func followEnd() {
        guard followsEnd, isRestored, isAtEnd, followTask == nil else {
            return
        }
        followTask = Task { @MainActor in
            try? await Task.sleep(for: Self.followDelay)
            followTask = nil
            if isAtEnd {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Put the area back where it was left, once its content is in.
    private func restoreIfReady() {
        guard !isRestored, isReady, let geometry = latest.geometry else {
            return
        }
        isRestored = true
        guard let saved = memory.mapScrollOffsets[key] else {
            if followsEnd {
                position.scrollTo(edge: .bottom)
            }
            return
        }
        if followsEnd {
            isAtEnd = saved.y < Self.bottomSlack
            guard !isAtEnd else {
                position.scrollTo(edge: .bottom)
                return
            }
            position.scrollTo(y: max(0, geometry.contentSize.height - geometry.containerSize.height - saved.y))
        } else {
            position.scrollTo(point: saved)
        }
    }
}

/// A scroll area's latest geometry, held by reference so writing it redraws nothing.
@available(macOS 15, *)
final class LatestScrollGeometry {
    var geometry: ScrollGeometry?
}

