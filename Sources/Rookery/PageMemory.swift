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
    /// The folded runs of tool calls the user opened in each agent's conversation, by agent.
    var mapOpenTranscriptBlocks: [String: Set<Int>] = [:]
    /// Each kind list's search, by kind.
    var mapListQueries: [String: String] = [:]
    /// How far each scroll area was scrolled, by the area's key: from the top, or for an area that
    /// follows its end, how far above its bottom.
    @ObservationIgnored var mapScrollOffsets: [String: CGPoint] = [:]
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

    let key: String
    let memory: PageMemory
    let followsEnd: Bool
    let isReady: Bool
    let endToken: Int
    let jumpToken: Int

    @State private var position = ScrollPosition()
    @State private var isRestored = false
    @State private var isAtEnd = true
    @State private var latestGeometry: ScrollGeometry?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(followsEnd ? .bottom : .topLeading, for: .initialOffset)
            .defaultScrollAnchor(followsEnd && isAtEnd ? .bottom : .topLeading, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                latestGeometry = geometry
                guard isRestored else {
                    restoreIfReady()
                    return
                }
                let fromBottom = geometry.contentSize.height - geometry.containerSize.height - geometry.contentOffset.y
                isAtEnd = fromBottom < Self.bottomSlack
                memory.mapScrollOffsets[key] = followsEnd
                    ? CGPoint(x: 0, y: max(0, fromBottom))
                    : geometry.contentOffset
            }
            .onChange(of: isReady) {
                restoreIfReady()
            }
            .onChange(of: endToken) {
                if followsEnd, isRestored, isAtEnd {
                    position.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: jumpToken) {
                isAtEnd = true
                withAnimation(.easeOut(duration: 0.25)) {
                    position.scrollTo(edge: .bottom)
                }
            }
    }

    /// Put the area back where it was left, once its content is in.
    private func restoreIfReady() {
        guard !isRestored, isReady, let geometry = latestGeometry else {
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
