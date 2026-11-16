import RookeryCore
import SwiftUI

/// The frames of the board's cards, by resource, for its edges to be drawn between.
private struct CardAnchorsKey: PreferenceKey {
    static let defaultValue: [FleetRef: Anchor<CGRect>] = [:]

    static func reduce(value: inout [FleetRef: Anchor<CGRect>], nextValue: () -> [FleetRef: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

/// How long ago a resource must have been used to stay on the board.
enum BoardWindow: String, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case all

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hour: "Last Hour"
        case .day: "Last Day"
        case .week: "Last Week"
        case .all: "All Time"
        }
    }

    /// The title in a segmented control's few letters.
    var shortTitle: String {
        switch self {
        case .hour: "1h"
        case .day: "1d"
        case .week: "1w"
        case .all: "All"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        case .all: nil
        }
    }
}

/// One edge of the board: what one card did to another, however many relations of the fleet it stands for
/// once subagents are folded into their sessions.
struct BoardEdge: Identifiable, Equatable {
    let source: FleetRef
    let target: FleetRef
    var listVerbs: [String]
    var count: Int
    var lastAt: String

    var id: String {
        "\(source.kind)/\(source.id)>\(target.kind)/\(target.id)"
    }
}

/// The Rookmaster board: one column per kind, agents leftmost, each column's cards ordered by when they
/// were last used, so whatever moved last rises; edges draw what acted on what. A subagent folds into its
/// session's card. Locking freezes the order; the filters narrow it down; hovering or selecting a card
/// brings forward it, its neighbours and the edges between them.
struct RookmasterBoard: View {
    private static let cardWidth: CGFloat = 210
    private static let columnSpacing: CGFloat = 60
    private static let columnLimit = 150
    private static let reorderAnimation = Animation.spring(response: 0.45, dampingFraction: 0.85)
    private static let boardSpace = "board"
    private static let controlHeight: CGFloat = 26

    let fleetModel: FleetModel
    let listKinds: [FleetKind]
    let onOpen: (FleetRef) -> Void

    @State private var hoveredRef: FleetRef?
    @FocusState private var isSearchFocused: Bool
    @Namespace private var chipNamespace

    private var memory: PageMemory {
        fleetModel.pageMemory
    }

    private var graph: ResourceGraph {
        fleetModel.graph
    }

    private var listShownKinds: [FleetKind] {
        listKinds.filter { !memory.setBoardHiddenKinds.contains($0.name) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let mapColumns = columns(now: context.date)
            let listEdges = edges(among: mapColumns)
            let setFocus = focus(listEdges)
            VStack(spacing: 0) {
                toolbar(mapColumns)
                GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: Self.columnSpacing) {
                        ForEach(listShownKinds) { kind in
                            column(kind, listResources: mapColumns[kind.name] ?? [], setFocus: setFocus, now: context.date)
                        }
                    }
                    .padding(24)
                    .backgroundPreferenceValue(CardAnchorsKey.self) { mapAnchors in
                        GeometryReader { proxy in
                            edgeCanvas(listEdges, mapAnchors: mapAnchors, proxy: proxy, setFocus: setFocus)
                        }
                    }
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                    .animation(Self.reorderAnimation, value: mapColumns.mapValues { $0.map(\.id) })
                }
                .modifier(RememberedScroll(key: "rookmaster.board", memory: memory))
                }
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            memory.boardSelectedRef = nil
                        }
                }
            }
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ mapColumns: [String: [FleetResource]]) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    searchField
                    windowPicker
                    liveOnlyChip
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)
                    ForEach(listKinds) { kind in
                        kindChip(kind, count: mapColumns[kind.name]?.count ?? 0)
                    }
                }
                .padding(.vertical, 1)
            }
            lockChip(mapColumns)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.15), value: memory.setBoardHiddenKinds)
        .animation(.easeOut(duration: 0.15), value: memory.isBoardLiveOnly)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: memory.boardWindow)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            RookeryIconView(.search)
                .foregroundStyle(StageColors.secondaryText)
            TextField("Filter by name", text: Bindable(memory).boardQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .frame(width: 160)
            if !memory.boardQuery.isEmpty {
                Button {
                    memory.boardQuery = ""
                } label: {
                    RookeryIconView(.close)
                        .foregroundStyle(StageColors.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: Self.controlHeight)
        .background(StageColors.groove, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(isSearchFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(StageColors.separator))
        }
    }

    /// How far back the board looks, as a segmented capsule.
    private var windowPicker: some View {
        HStack(spacing: 2) {
            ForEach(BoardWindow.allCases) { choice in
                windowSegment(choice)
            }
        }
        .padding(2)
        .background(StageColors.groove, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(StageColors.separator)
        }
    }

    private func windowSegment(_ choice: BoardWindow) -> some View {
        let isSelected = memory.boardWindow == choice
        let textStyle = isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText)
        return Button {
            memory.boardWindow = choice
        } label: {
            Text(choice.shortTitle)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(textStyle)
                .padding(.horizontal, 9)
                .frame(height: Self.controlHeight - 4)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(StageColors.selectedSegment)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "window", in: chipNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(choice.title)
    }

    private var liveOnlyChip: some View {
        let isOn = memory.isBoardLiveOnly
        return Button {
            memory.isBoardLiveOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                RookeryIconView(isOn ? .check : .appPlaceholder)
                Text("Live agents")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 10)
            .frame(height: Self.controlHeight)
            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(StageColors.groove), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(StageColors.separator))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing live agents only; click to show ended ones too" : "Showing ended agents too; click to show live ones only")
    }

    private func lockChip(_ mapColumns: [String: [FleetResource]]) -> some View {
        let isLocked = memory.isBoardLocked
        return Button {
            toggleLock(mapColumns)
        } label: {
            RookeryLabel(isLocked ? "Locked" : "Lock Order", icon: isLocked ? .lock : .unlock, spacing: 5)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isLocked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                .padding(.horizontal, 10)
                .frame(height: Self.controlHeight)
                .background(isLocked ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(StageColors.groove), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isLocked ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(StageColors.separator))
                }
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Let cards rise as they are used again" : "Hold the cards where they are")
    }

    private func kindChip(_ kind: FleetKind, count: Int) -> some View {
        let isShown = !memory.setBoardHiddenKinds.contains(kind.name)
        let tint = RookmasterStyle.tint(of: kind.name)
        return Button {
            withAnimation(Self.reorderAnimation) {
                if isShown {
                    memory.setBoardHiddenKinds.insert(kind.name)
                } else {
                    memory.setBoardHiddenKinds.remove(kind.name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isShown ? AnyShapeStyle(tint) : AnyShapeStyle(StageColor.clear))
                    .overlay {
                        Circle()
                            .strokeBorder(tint, lineWidth: 1.5)
                    }
                    .frame(width: 8, height: 8)
                Text(kind.pluralTitle)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isShown ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.tertiaryText))
            .padding(.horizontal, 10)
            .frame(height: Self.controlHeight)
            .background(isShown ? AnyShapeStyle(tint.opacity(0.12)) : AnyShapeStyle(StageColor.clear), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isShown ? AnyShapeStyle(tint.opacity(0.35)) : AnyShapeStyle(StageColors.separator),
                        style: StrokeStyle(lineWidth: 1, dash: isShown ? [] : [3, 2])
                    )
            }
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(isShown ? "Hide \(kind.pluralTitle)" : "Show \(kind.pluralTitle)")
    }

    // MARK: - Columns and cards

    private func column(_ kind: FleetKind, listResources: [FleetResource], setFocus: Set<FleetRef>?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RookeryIconView(RookeryIcon.kind(kind.name))
                    .foregroundStyle(RookmasterStyle.tint(of: kind.name))
                Text(kind.pluralTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(listResources.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .padding(.leading, 4)
            .padding(.bottom, 2)
            if listResources.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
                    .frame(width: Self.cardWidth, alignment: .leading)
                    .padding(.leading, 4)
            }
            ForEach(Array(listResources.enumerated()), id: \.element.id) { index, resource in
                if kind.name == AgentFleet.agentKind, let heading = teamHeading(at: index, in: listResources) {
                    teamHeader(heading)
                }
                card(resource, setFocus: setFocus, now: now)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: Self.cardWidth, alignment: .topLeading)
    }

    private func card(_ resource: FleetResource, setFocus: Set<FleetRef>?, now: Date) -> some View {
        let ref = FleetRef(kind: resource.kind, id: resource.id)
        let isSelected = memory.boardSelectedRef == ref
        let isDimmed = setFocus.map { !$0.contains(ref) } ?? false
        let agent = resource.kind == AgentFleet.agentKind ? fleetModel.fleet.mapAgents[resource.id] : nil
        return HStack(spacing: 8) {
            if let agent {
                CrowView(state: agent.state)
            } else {
                RookeryIconView(RookeryIcon.kind(resource.kind))
                    .foregroundStyle(RookmasterStyle.tint(of: resource.kind))
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(graph.name(of: ref))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle(of: resource, agent: agent))
                    .font(.system(size: 10))
                    .foregroundStyle(agent?.state.needsAttention == true ? AnyShapeStyle(Color.orange) : AnyShapeStyle(StageColors.secondaryText))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(RookmasterStyle.age(of: resource.lastUsedAt, now: now))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(StageColors.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.cardWidth)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.separator),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .opacity(isDimmed ? 0.32 : 1)
        .scaleEffect(hoveredRef == ref ? 1.02 : 1)
        .anchorPreference(key: CardAnchorsKey.self, value: .bounds) { [ref: $0] }
        .contentShape(Rectangle())
        .onHover { isInside in
            withAnimation(.easeOut(duration: 0.15)) {
                if isInside {
                    hoveredRef = ref
                } else if hoveredRef == ref {
                    hoveredRef = nil
                }
            }
        }
        .onTapGesture(count: 2) {
            onOpen(ref)
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                memory.boardSelectedRef = isSelected ? nil : ref
            }
        }
        .help("\(resource.name)\nClick to bring forward what it touches; double-click to open")
    }

    private func subtitle(of resource: FleetResource, agent: FleetAgent?) -> String {
        if let agent {
            let subagentCount = fleetModel.fleet.listSubagents(of: agent.id).count
            return subagentCount > 0 ? "\(agent.state.title) with \(subagentCount) subagents" : agent.state.title
        }
        let relationCount = graph.listRelations(touching: FleetRef(kind: resource.kind, id: resource.id)).count
        if let description = resource.mapAttributes["description"]?.stringValue {
            return description
        }
        return relationCount == 1 ? "1 relation" : "\(relationCount) relations"
    }

    // MARK: - Edges

    private func edgeCanvas(
        _ listEdges: [BoardEdge],
        mapAnchors: [FleetRef: Anchor<CGRect>],
        proxy: GeometryProxy,
        setFocus: Set<FleetRef>?
    ) -> some View {
        let mapColumnIndices = Dictionary(uniqueKeysWithValues: listShownKinds.enumerated().map { ($1.name, $0) })
        let mapFrames = mapAnchors.mapValues { proxy[$0] }
        return Canvas { context, _ in
            for edge in listEdges {
                guard let sourceFrame = mapFrames[edge.source], let targetFrame = mapFrames[edge.target] else {
                    continue
                }
                let isFocused = setFocus.map { $0.contains(edge.source) && $0.contains(edge.target) } ?? true
                let isQuiet = setFocus == nil
                let sourceColumn = mapColumnIndices[edge.source.kind] ?? 0
                let targetColumn = mapColumnIndices[edge.target.kind] ?? 0
                let path = Self.path(from: sourceFrame, to: targetFrame, sourceColumn: sourceColumn, targetColumn: targetColumn)
                let tint = RookmasterStyle.tint(ofVerb: edge.listVerbs.first ?? "")
                let opacity = isQuiet ? 0.4 : (isFocused ? 0.95 : 0.06)
                let width = min(1 + log2(Double(edge.count)), 3.5)
                context.stroke(
                    path,
                    with: .color(tint.opacity(opacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// An edge's curve, ending in an arrowhead at its target, leaving the side of each card that faces the
    /// other.
    private static func path(from source: CGRect, to target: CGRect, sourceColumn: Int, targetColumn: Int) -> Path {
        let arrowLength: CGFloat = 7
        let start: CGPoint
        let end: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let direction: CGFloat
        if sourceColumn == targetColumn {
            start = CGPoint(x: source.maxX, y: source.midY)
            end = CGPoint(x: target.maxX + arrowLength, y: target.midY)
            let bulge = 28 + min(abs(target.midY - source.midY) * 0.25, 60)
            control1 = CGPoint(x: start.x + bulge, y: start.y)
            control2 = CGPoint(x: end.x + bulge, y: end.y)
            direction = -1
        } else if sourceColumn < targetColumn {
            start = CGPoint(x: source.maxX, y: source.midY)
            end = CGPoint(x: target.minX - arrowLength, y: target.midY)
            let reach = max((end.x - start.x) / 2, 30)
            control1 = CGPoint(x: start.x + reach, y: start.y)
            control2 = CGPoint(x: end.x - reach, y: end.y)
            direction = 1
        } else {
            start = CGPoint(x: source.minX, y: source.midY)
            end = CGPoint(x: target.maxX + arrowLength, y: target.midY)
            let reach = max((start.x - end.x) / 2, 30)
            control1 = CGPoint(x: start.x - reach, y: start.y)
            control2 = CGPoint(x: end.x + reach, y: end.y)
            direction = -1
        }
        let tip = CGPoint(x: end.x + arrowLength * direction, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: end.x, y: end.y - 4))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: end.x, y: end.y + 4))
        return path
    }

    // MARK: - What the board shows

    /// Each shown kind's cards, in order, after the filters.
    private func columns(now: Date) -> [String: [FleetResource]] {
        let trimmedQuery = memory.boardQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let cutoff = memory.boardWindow.seconds.map { now.addingTimeInterval(-$0) }
        var mapColumns: [String: [FleetResource]] = [:]
        for kind in listShownKinds {
            var listResources = graph.listResources(of: kind.name).filter { resource in
                if kind.name == AgentFleet.agentKind {
                    let agent = fleetModel.fleet.mapAgents[resource.id]
                    if agent?.parentId != nil {
                        return false
                    }
                    if memory.isBoardLiveOnly && agent?.state == .ended {
                        return false
                    }
                }
                if !trimmedQuery.isEmpty && !"\(resource.name) \(resource.id)".lowercased().contains(trimmedQuery) {
                    return false
                }
                if let cutoff, let used = FleetTimestamp.date(from: resource.lastUsedAt), used < cutoff {
                    return false
                }
                return true
            }
            if kind.name == AgentFleet.agentKind {
                listResources = byTeam(listResources)
            }
            if memory.isBoardLocked, let listFrozen = memory.mapBoardFrozenOrder[kind.name] {
                let mapRanks = Dictionary(listFrozen.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                listResources.sort { first, second in
                    let firstRank = mapRanks[FleetRef(kind: first.kind, id: first.id)] ?? Int.max
                    let secondRank = mapRanks[FleetRef(kind: second.kind, id: second.id)] ?? Int.max
                    return firstRank < secondRank
                }
            }
            mapColumns[kind.name] = Array(listResources.prefix(Self.columnLimit))
        }
        return mapColumns
    }

    /// The agents with each team's together, in the teams' order and each team's own, then those in none.
    private func byTeam(_ listAgents: [FleetResource]) -> [FleetResource] {
        let teams = fleetModel.teams
        let mapTeamIndices = Dictionary(uniqueKeysWithValues: teams.listTeams.enumerated().map { ($1.id, $0) })
        let mapMemberIndices = Dictionary(
            teams.listTeams.flatMap { team in team.listAgentIds.enumerated().map { ($1, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return listAgents.enumerated().sorted { first, second in
            let firstTeam = teams.teamId(of: first.element.id).flatMap { mapTeamIndices[$0] } ?? Int.max
            let secondTeam = teams.teamId(of: second.element.id).flatMap { mapTeamIndices[$0] } ?? Int.max
            if firstTeam != secondTeam {
                return firstTeam < secondTeam
            }
            if firstTeam != Int.max {
                return (mapMemberIndices[first.element.id] ?? 0) < (mapMemberIndices[second.element.id] ?? 0)
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// The team heading above the agent at an index, when it starts a team's run, or the unassigned ones
    /// after the teams; nil within a run, or when there are no teams.
    private func teamHeading(at index: Int, in listAgents: [FleetResource]) -> String? {
        let teams = fleetModel.teams
        guard !teams.listTeams.isEmpty, listAgents.indices.contains(index) else {
            return nil
        }
        let teamId = teams.teamId(of: listAgents[index].id)
        if index > 0, teams.teamId(of: listAgents[index - 1].id) == teamId {
            return nil
        }
        guard let teamId else {
            return "Unassigned"
        }
        return teams.listTeams.first { $0.id == teamId }?.title
    }

    private func teamHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
        }
        .padding(.leading, 4)
        .padding(.top, 6)
    }

    /// The edges between shown cards, a subagent's drawn from its session.
    private func edges(among mapColumns: [String: [FleetResource]]) -> [BoardEdge] {
        let setShown = Set(mapColumns.values.flatMap { $0.map { FleetRef(kind: $0.kind, id: $0.id) } })
        var mapEdges: [String: BoardEdge] = [:]
        for relation in graph.mapRelations.values {
            let source = shownRef(of: relation.source)
            let target = shownRef(of: relation.target)
            guard source != target, setShown.contains(source), setShown.contains(target) else {
                continue
            }
            let edge = BoardEdge(source: source, target: target, listVerbs: [relation.verb], count: relation.count, lastAt: relation.lastAt)
            if var known = mapEdges[edge.id] {
                if !known.listVerbs.contains(relation.verb) {
                    known.listVerbs.append(relation.verb)
                }
                known.count += relation.count
                known.lastAt = max(known.lastAt, relation.lastAt)
                mapEdges[edge.id] = known
            } else {
                mapEdges[edge.id] = edge
            }
        }
        return mapEdges.values.sorted { $0.lastAt < $1.lastAt }
    }

    /// The card a resource shows on: its own, or its session's for a subagent.
    private func shownRef(of ref: FleetRef) -> FleetRef {
        guard ref.kind == AgentFleet.agentKind, let parentId = fleetModel.fleet.mapAgents[ref.id]?.parentId else {
            return ref
        }
        return FleetRef(kind: ref.kind, id: parentId)
    }

    /// The card in focus and its neighbours, or nil when no card is hovered or selected.
    private func focus(_ listEdges: [BoardEdge]) -> Set<FleetRef>? {
        guard let center = hoveredRef ?? memory.boardSelectedRef else {
            return nil
        }
        var setFocus: Set<FleetRef> = [center]
        for edge in listEdges where edge.source == center || edge.target == center {
            setFocus.insert(edge.source)
            setFocus.insert(edge.target)
        }
        return setFocus
    }

    private func toggleLock(_ mapColumns: [String: [FleetResource]]) {
        withAnimation(.easeOut(duration: 0.2)) {
            memory.isBoardLocked.toggle()
        }
        memory.mapBoardFrozenOrder = memory.isBoardLocked ? mapColumns.mapValues { $0.map { FleetRef(kind: $0.kind, id: $0.id) } } : [:]
    }
}
