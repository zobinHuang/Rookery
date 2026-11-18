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
    /// The row at the top of each area that follows its end, by the area's key, while the user has
    /// scrolled it away from the end; rows of a lazy stack it has not laid out have no height to count by.
    @ObservationIgnored var mapScrollAnchors: [String: Int] = [:]
    /// What is typed to Raven in the Rookmaster console and not yet sent.
    var ravenDraft = ""
    /// The section of the settings shown.
    var settingsPane = SettingsPane.general
    /// The person open in the settings, as far as the user changed them.
    var personDraft: PersonDraft?
    /// The roost address and token typed in the settings and not yet used; nil for the ones kept.
    var roostAddressDraft: String?
    var roostTokenDraft: String?
    /// Which conversation the Mail page's Raven shows for each thread, by the thread's id: one of the
    /// thread's, or the empty id for a new one; a thread not here shows its latest.
    var mapMailRavenChoices: [Int: String] = [:]
    /// Whether Rookmaster's Raven lists the conversations started anywhere, not only on the board.
    var isRavenListingAll = false
    /// What the user is writing to Raven beside a mail, before sending it.
    var mailRavenDraft = ""
    /// The draft open in the Mail page's editor, by its id in Rookery's drafts.
    var openDraftId: String?
    /// The folder the Mail page shows.
    var mailPlace = MailPlace.allInboxes
    /// A page something asked the stage to show, as a draft's Open asks for Mail; the stage shows it and
    /// clears it.
    var requestedPage: StagePage?
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
    /// When the end is brought into view again after a jump to it, as a lazy stack lays out the rows it
    /// reaches only after the jump and leaves them blank until then.
    private static let listSettleDelays: [Duration] = [.milliseconds(80), .milliseconds(300)]
    private static let endButtonSize: CGFloat = 30
    /// How much of a row must show for it to count as shown, the top one kept as where the user was.
    private static let rowVisibleShare: Double = 0.3
    /// When a jump back to a row is checked, and given up for the end if it left the area at its top.
    private static let anchorCheckDelay: Duration = .milliseconds(120)

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
    /// The scrolls that settle the area at its end once the rows a jump reached are laid out.
    @State private var settleTask: Task<Void, Never>?

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
                guard followsEnd else {
                    memory.mapScrollOffsets[key] = geometry.contentOffset
                    return
                }
                guard isUserScrolling else {
                    return
                }
                let fromBottom = geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y
                let isNowAtEnd = fromBottom < Self.bottomSlack
                if isAtEnd != isNowAtEnd {
                    isAtEnd = isNowAtEnd
                }
                memory.mapScrollOffsets[key] = CGPoint(x: 0, y: isNowAtEnd ? 0 : max(0, fromBottom))
                memory.mapScrollAnchors[key] = isNowAtEnd ? nil : latest.topRowId
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: Self.rowVisibleShare) { listVisibleIds in
                latest.topRowId = listVisibleIds.min()
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
                jumpToEnd()
            }
            .onChange(of: isAtEnd) { _, isNowAtEnd in
                if isNowAtEnd, followsEnd {
                    memory.mapScrollOffsets[key] = .zero
                    memory.mapScrollAnchors[key] = nil
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if followsEnd, isRestored, !isAtEnd {
                    endButton
                        .padding(.trailing, 18)
                        .padding(.bottom, 14)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isAtEnd)
            .onDisappear {
                followTask?.cancel()
                settleTask?.cancel()
            }
    }

    /// The way back to the end, shown while the user has scrolled away from it.
    private var endButton: some View {
        Button {
            jumpToEnd()
        } label: {
            RookeryIconView(.chevronDown)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StageColors.primaryText)
                .frame(width: Self.endButtonSize, height: Self.endButtonSize)
                .background {
                    Circle()
                        .fill(StageColors.window)
                        .overlay {
                            Circle()
                                .fill(StageColors.card)
                        }
                }
                .overlay {
                    Circle()
                        .strokeBorder(StageColors.separator)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest")
    }

    /// Bring the end into view wherever the area was, and stay there.
    private func jumpToEnd() {
        isAtEnd = true
        withAnimation(.easeOut(duration: 0.25)) {
            position.scrollTo(edge: .bottom)
        }
        settleAtEnd()
    }

    /// Bring the end into view again once the rows a jump reached are laid out, unless the user has
    /// scrolled away meanwhile.
    private func settleAtEnd() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            for delay in Self.listSettleDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, isAtEnd, !isUserScrolling else {
                    return
                }
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
                settleAtEnd()
            }
        }
    }

    /// Put the area back where it was left, once its content is in.
    private func restoreIfReady() {
        guard !isRestored, isReady, latest.geometry != nil else {
            return
        }
        isRestored = true
        guard let saved = memory.mapScrollOffsets[key] else {
            if followsEnd {
                position.scrollTo(edge: .bottom)
                settleAtEnd()
            }
            return
        }
        if followsEnd {
            isAtEnd = saved.y < Self.bottomSlack
            guard !isAtEnd else {
                position.scrollTo(edge: .bottom)
                settleAtEnd()
                return
            }
            guard let anchor = memory.mapScrollAnchors[key] else {
                isAtEnd = true
                position.scrollTo(edge: .bottom)
                settleAtEnd()
                return
            }
            position.scrollTo(id: anchor, anchor: .top)
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: Self.anchorCheckDelay)
                guard !Task.isCancelled, !isUserScrolling, let geometry = latest.geometry else {
                    return
                }
                let isStuckAtTop = geometry.contentOffset.y <= 1 && geometry.contentSize.height > geometry.containerSize.height + Self.bottomSlack
                if isStuckAtTop || latest.topRowId == nil {
                    jumpToEnd()
                }
            }
        } else {
            position.scrollTo(point: saved)
        }
    }
}

/// A scroll area's latest geometry, held by reference so writing it redraws nothing.
@available(macOS 15, *)
final class LatestScrollGeometry {
    var geometry: ScrollGeometry?
    /// The row at the top of what shows, of an area whose rows are scroll targets.
    var topRowId: Int?
}

