import RookeryCore
import SwiftUI

/// The frames of the board's cards, by resource, for its edges to be drawn between, and of the team
/// headings and Raven's tab, for Raven's links to what it works on.
struct CardAnchorsKey: PreferenceKey {
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
    /// Whether something went the other way between the two cards too, drawn on the same line.
    var isMutual = false

    var id: String {
        Self.key(source, target)
    }

    /// The one key of the line between two cards, whichever way it goes.
    static func key(_ first: FleetRef, _ second: FleetRef) -> String {
        let firstKey = "\(first.kind)/\(first.id)"
        let secondKey = "\(second.kind)/\(second.id)"
        return firstKey < secondKey ? "\(firstKey)|\(secondKey)" : "\(secondKey)|\(firstKey)"
    }
}

/// The Rookmaster board: one column per kind, teams leftmost with a line to each of their agents beside
/// them, then the playbooks they follow and the skills those use, each other column's cards ordered by when they were last used, so whatever moved last rises;
/// edges draw what acted on what. A subagent folds into its
/// session's card. Locking freezes the order; the filters narrow it down; hovering or selecting a card
/// brings forward it, its neighbours and the edges between them.
struct RookmasterBoard: View {
    /// The verb of the line from a team to each of its agents.
    private static let memberVerb = "member"
    /// The kind of the card a repository's skills fold into.
    private static let repoKind = "skill-repo"
    private static let skillKind = "skill"
    private static let playbookKind = "playbook"
    /// The verb of an agent following a playbook.
    private static let followsVerb = "follows"
    /// What an agent does with a skill that, for a skill its playbook brings, the playbook's lines say.
    private static let setPlaybookSkillVerbs: Set<String> = ["mounts", "uses"]
    /// The fewest skills of one repository that fold into a card of their own.
    private static let repoFoldCount = 2
    private static let repoRailInset: CGFloat = 14
    private static let cardWidth: CGFloat = 210
    private static let columnSpacing: CGFloat = 60
    private static let columnLimit = 150
    private static let reorderAnimation = Animation.spring(response: 0.45, dampingFraction: 0.85)
    private static let boardSpace = "board"
    private static let controlHeight: CGFloat = 26
    private static let chipRavenSide: CGFloat = 20
    private static let chipRavenScale: CGFloat = 0.62
    /// The key the open subagent column's cards go under among the columns.
    private static let subagentColumnKey = "rookmaster.subagents"

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

    /// The kinds that lead the board, in the order the work flows: teams, the agents they hold, the
    /// playbooks the agents follow and the skills the playbooks use.
    private static let listLeadingKinds = [AgentFleet.teamKind, AgentFleet.agentKind, "playbook", skillKind]

    /// The kinds shown, those leading the board first, then the others in roost's order.
    private var listShownKinds: [FleetKind] {
        let listShown = listKinds.filter { !memory.setBoardHiddenKinds.contains($0.name) }
        let listLeading = Self.listLeadingKinds.compactMap { name in listShown.first { $0.name == name } }
        return listLeading + listShown.filter { !Self.listLeadingKinds.contains($0.name) }
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
                            if
                                kind.name == AgentFleet.agentKind,
                                let parentId = memory.boardSubagentsOf,
                                foldingTeam(of: parentId) == nil
                            {
                                subagentColumn(
                                    of: parentId,
                                    listSubagents: mapColumns[Self.subagentColumnKey] ?? [],
                                    setFocus: setFocus,
                                    now: context.date
                                )
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(24)
                    .backgroundPreferenceValue(CardAnchorsKey.self) { mapAnchors in
                        GeometryReader { proxy in
                            edgeCanvas(listEdges, mapAnchors: mapAnchors, proxy: proxy, setFocus: setFocus)
                        }
                    }
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    memory.boardSelectedRef = nil
                                }
                            }
                    }
                    .animation(Self.reorderAnimation, value: mapColumns.mapValues { $0.map(\.id) })
                    .animation(Self.reorderAnimation, value: memory.boardSubagentsOf)
                    .animation(Self.reorderAnimation, value: memory.setBoardFoldedTeams)
                    .animation(Self.reorderAnimation, value: ravenScopeId)
                }
                .modifier(RememberedScroll(key: "rookmaster.board", memory: memory))
                }
            }
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ mapColumns: [String: [FleetResource]]) -> some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if let scopeId = ravenScopeId {
                        ravenScopeChip(scopeId)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    searchField
                    well {
                        ForEach(BoardWindow.allCases) { choice in
                            windowSegment(choice)
                        }
                    }
                    well {
                        liveOnlySegment
                    }
                    well {
                        ForEach(listKinds) { kind in
                            kindSegment(kind, count: mapColumns[kind.name]?.count ?? 0)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            well {
                lockSegment(mapColumns)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(Self.segmentAnimation, value: memory.setBoardHiddenKinds)
        .animation(Self.segmentAnimation, value: memory.isBoardLiveOnly)
        .animation(Self.segmentAnimation, value: memory.isBoardLocked)
        .animation(Self.segmentAnimation, value: memory.boardWindow)
        .animation(Self.segmentAnimation, value: ravenScopeId)
    }

    /// The Raven conversation chosen below the board while it is in a team: the board then shows only
    /// its teams and what their agents touch.
    private var ravenScopeId: String? {
        guard let conversationId = fleetModel.raven.openConversationId, !fleetModel.raven.teams(of: conversationId).isEmpty else {
            return nil
        }
        return conversationId
    }

    /// What the board is narrowed to: the chosen conversation's teams, their agents, and every card
    /// those agents, their subagents and the playbooks they follow touch; nil while no conversation in a
    /// team is chosen.
    private func ravenScope(of conversationId: String) -> Set<FleetRef> {
        let listTeams = fleetModel.raven.teams(of: conversationId)
        var setScope = Set(listTeams.map { FleetRef(kind: AgentFleet.teamKind, id: $0.id) })
        let setAgentIds = Set(listTeams.flatMap { AgentTeams.memberIds(of: $0) })
        setScope.formUnion(setAgentIds.map { FleetRef(kind: AgentFleet.agentKind, id: $0) })
        let listRelations = Array(graph.mapRelations.values)
        var setPlaybooks: Set<FleetRef> = []
        for relation in listRelations where relation.source.kind == AgentFleet.agentKind {
            let sessionId = fleetModel.fleet.mapAgents[relation.source.id]?.parentId ?? relation.source.id
            guard setAgentIds.contains(sessionId) else {
                continue
            }
            setScope.insert(relation.target)
            if relation.target.kind == Self.playbookKind {
                setPlaybooks.insert(relation.target)
            }
        }
        for relation in listRelations where setPlaybooks.contains(relation.source) {
            setScope.insert(relation.target)
        }
        return setScope
    }

    /// The mark of the board narrowed to a Raven conversation's teams, and the way back to all of it.
    private func ravenScopeChip(_ conversationId: String) -> some View {
        let title = fleetModel.raven.conversations.conversation(conversationId)?.title ?? "Raven"
        return Button {
            withAnimation(Self.reorderAnimation) {
                fleetModel.raven.openConversationId = nil
            }
        } label: {
            HStack(spacing: 6) {
                RavenView(isWorking: fleetModel.raven.isRunning(conversationId))
                    .scaleEffect(Self.chipRavenScale)
                    .frame(width: Self.chipRavenSide, height: Self.chipRavenSide)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .padding(.horizontal, 9)
            .frame(height: Self.controlHeight)
            .background(StageColors.selectedRow, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.6))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("The board shows only the teams of the Raven conversation chosen below, and what their agents touch. Click to show everything again.")
    }

    private static let segmentAnimation = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// A recessed capsule that holds a group of segments.
    private func well<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(2)
        .frame(height: Self.controlHeight)
        .background(StageColors.segmentGroove, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(StageColors.segmentGrooveBorder)
        }
    }

    /// One segment of a well. A choice of one, as the time window, is in the theme's colors turned over
    /// when chosen, as every switch is; a filter that is on or off, of which several may be on, is raised
    /// in no color of its own and in full ink when on, flat and faint when off.
    private func segment<Label: View>(isOn: Bool, isToggle: Bool = false, @ViewBuilder label: () -> Label) -> some View {
        label()
            .font(.system(size: 11, weight: isOn ? .semibold : .medium))
            .foregroundStyle(
                isOn
                    ? (isToggle ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.selectedSegmentText))
                    : AnyShapeStyle(StageColors.tertiaryText)
            )
            .padding(.horizontal, 9)
            .frame(height: Self.controlHeight - 4)
            .background {
                if isOn {
                    Capsule()
                        .fill(isToggle ? StageColors.selectedRow : StageColors.selectedSegment)
                        .strokeBorder(isToggle ? StageColors.segmentGrooveBorder : StageColors.contrastActiveBorder)
                        .shadow(color: .black.opacity(isToggle ? 0.08 : 0.14), radius: 1.5, y: 0.5)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .contentShape(Capsule())
            .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            RookeryIconView(.search)
                .foregroundStyle(StageColors.tertiaryText)
            TextField("Filter by name", text: Bindable(memory).boardQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .frame(width: 150)
            if !memory.boardQuery.isEmpty {
                Button {
                    memory.boardQuery = ""
                } label: {
                    RookeryIconView(.close)
                        .foregroundStyle(StageColors.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .transition(.opacity)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 11)
        .frame(height: Self.controlHeight)
        .background(StageColors.segmentGroove, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isSearchFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(StageColors.contrastBorder),
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
        }
        .animation(.easeOut(duration: 0.15), value: isSearchFocused)
        .animation(.easeOut(duration: 0.15), value: memory.boardQuery.isEmpty)
    }

    private func windowSegment(_ choice: BoardWindow) -> some View {
        let isSelected = memory.boardWindow == choice
        return Button {
            memory.boardWindow = choice
        } label: {
            segment(isOn: isSelected) {
                Text(choice.shortTitle)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .help(choice.title)
    }

    private var liveOnlySegment: some View {
        let isOn = memory.isBoardLiveOnly
        return Button {
            memory.isBoardLiveOnly.toggle()
        } label: {
            segment(isOn: isOn, isToggle: true) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOn ? Color.green : Color.clear)
                        .overlay {
                            Circle()
                                .strokeBorder(isOn ? Color.green : Color.secondary.opacity(0.6), lineWidth: 1.2)
                        }
                        .frame(width: 7, height: 7)
                    Text("Live only")
                }
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "Showing live agents only; click to show ended ones too" : "Showing ended agents too; click to show live ones only")
    }

    private func lockSegment(_ mapColumns: [String: [FleetResource]]) -> some View {
        let isLocked = memory.isBoardLocked
        return Button {
            toggleLock(mapColumns)
        } label: {
            segment(isOn: isLocked, isToggle: true) {
                RookeryLabel(isLocked ? "Locked" : "Lock", icon: isLocked ? .lock : .unlock, spacing: 4)
            }
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Let cards rise as they are used again" : "Hold the cards where they are")
    }

    private func kindSegment(_ kind: FleetKind, count: Int) -> some View {
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
            segment(isOn: isShown, isToggle: true) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isShown ? AnyShapeStyle(tint) : AnyShapeStyle(StageColor.clear))
                        .overlay {
                            Circle()
                                .strokeBorder(isShown ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.55)), lineWidth: 1.2)
                        }
                        .frame(width: 7, height: 7)
                    Text(kind.pluralTitle)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(StageColors.tertiaryText)
                        .contentTransition(.numericText())
                }
            }
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
                Text(countText(shown: listResources.count, of: kind))
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
                    .help(kind.name == AgentFleet.agentKind ? "Sessions shown after the filters, of every session roost holds; subagents fold into theirs" : "")
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
            if kind.name == Self.skillKind {
                skillRows(listResources, setFocus: setFocus, now: now)
            } else {
                ForEach(listResources, id: \.id) { resource in
                    card(resource, setFocus: setFocus, now: now)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .frame(width: Self.cardWidth, alignment: .topLeading)
    }

    /// The skills column: a repository holding several of them as one card, its skills under it on a rail
    /// once opened, and the others one by one, in the order the first of each was last used.
    @ViewBuilder
    private func skillRows(_ listSkills: [FleetResource], setFocus: Set<FleetRef>?, now: Date) -> some View {
        let mapGroups = repoGroups(of: listSkills)
        ForEach(skillRowIds(listSkills, groups: mapGroups), id: \.self) { rowId in
            if let listMembers = mapGroups[rowId] {
                VStack(alignment: .leading, spacing: 8) {
                    repoCard(rowId, listMembers: listMembers, setFocus: setFocus, now: now)
                    if memory.setBoardOpenRepos.contains(rowId) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(listMembers, id: \.id) { resource in
                                card(resource, setFocus: setFocus, now: now, width: Self.cardWidth - Self.repoRailInset)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .padding(.leading, Self.repoRailInset)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(RookmasterStyle.tint(of: Self.skillKind).opacity(0.35))
                                .frame(width: 2)
                                .padding(.leading, 5)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let resource = listSkills.first(where: { $0.id == rowId }) {
                card(resource, setFocus: setFocus, now: now)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    /// A repository's card: its name, how many skills it holds and when one was last used; clicking opens
    /// or folds its skills. Folded, it stands for each of them, so lines to them come to it.
    private func repoCard(_ repoUrl: String, listMembers: [FleetResource], setFocus: Set<FleetRef>?, now: Date) -> some View {
        let ref = FleetRef(kind: Self.repoKind, id: repoUrl)
        let isOpen = memory.setBoardOpenRepos.contains(repoUrl)
        let isDimmed = setFocus.map { !$0.contains(ref) } ?? false
        let lastUsedAt = listMembers.map(\.lastUsedAt).max() ?? ""
        return HStack(spacing: 8) {
            RookeryIconView(.folder)
                .foregroundStyle(RookmasterStyle.tint(of: Self.skillKind))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                FittingText(Self.repoTitle(of: repoUrl), size: 12, weight: .semibold)
                Text("\(listMembers.count) skills")
                    .font(.system(size: 10))
                    .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 0)
            Text(RookmasterStyle.age(of: lastUsedAt, now: now))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(StageColors.tertiaryText)
            RookeryIconView(.chevronRight)
                .foregroundStyle(StageColors.tertiaryText)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.cardWidth)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator, lineWidth: 1)
        }
        .opacity(isDimmed ? 0.32 : 1)
        .background(StageColors.content, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(hoveredRef == ref ? 1.02 : 1)
        .anchorPreference(key: CardAnchorsKey.self, value: .bounds) { anchor in
            var mapAnchors = [ref: anchor]
            if !isOpen {
                for resource in listMembers {
                    mapAnchors[FleetRef(kind: resource.kind, id: resource.id)] = anchor
                }
            }
            return mapAnchors
        }
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
        .onTapGesture {
            withAnimation(Self.reorderAnimation) {
                if isOpen {
                    memory.setBoardOpenRepos.remove(repoUrl)
                } else {
                    memory.setBoardOpenRepos.insert(repoUrl)
                }
            }
        }
        .help("\(repoUrl)\nClick to \(isOpen ? "fold its skills into this card" : "show its skills one by one")")
    }

    /// The skills of each repository holding enough of them to fold, by the repository's address.
    private func repoGroups(of listSkills: [FleetResource]) -> [String: [FleetResource]] {
        Dictionary(grouping: listSkills.filter { Self.repoUrl(of: $0) != nil }) { Self.repoUrl(of: $0) ?? "" }
            .filter { $0.value.count >= Self.repoFoldCount }
    }

    /// The rows of the skills column, each a repository's address or a skill's id, where the first of
    /// them stands.
    private func skillRowIds(_ listSkills: [FleetResource], groups mapGroups: [String: [FleetResource]]) -> [String] {
        var listRowIds: [String] = []
        var setSeen: Set<String> = []
        for resource in listSkills {
            let rowId = Self.repoUrl(of: resource).flatMap { mapGroups[$0] == nil ? nil : $0 } ?? resource.id
            if setSeen.insert(rowId).inserted {
                listRowIds.append(rowId)
            }
        }
        return listRowIds
    }

    private static func repoUrl(of resource: FleetResource) -> String? {
        guard let repoUrl = resource.mapAttributes["repo_url"]?.stringValue, !repoUrl.isEmpty else {
            return nil
        }
        return repoUrl
    }

    /// A repository as `owner/repo`, its host and scheme left off.
    private static func repoTitle(of repoUrl: String) -> String {
        let path = URL(string: repoUrl)?.path ?? repoUrl
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: ".git", with: "")
        return trimmed.isEmpty ? repoUrl : trimmed
    }

    /// A column's count: those shown, and of how many when the filters leave some agents out.
    private func countText(shown: Int, of kind: FleetKind) -> String {
        guard kind.name == AgentFleet.agentKind else {
            return "\(shown)"
        }
        let total = fleetModel.fleet.listSessions.count
        return shown == total ? "\(shown)" : "\(shown) of \(total)"
    }

    /// One agent's subagents, those last active first, beside the agents.
    private func subagentColumn(of parentId: String, listSubagents: [FleetResource], setFocus: Set<FleetRef>?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RookeryIconView(.agent)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Subagents")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(listSubagents.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    FittingText("of \(graph.name(of: FleetRef(kind: AgentFleet.agentKind, id: parentId)))", size: 10)
                        .foregroundStyle(StageColors.secondaryText)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Self.reorderAnimation) {
                        memory.boardSubagentsOf = nil
                    }
                } label: {
                    RookeryIconView(.close)
                        .foregroundStyle(StageColors.tertiaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fold the subagents away")
            }
            .padding(.leading, 4)
            .padding(.bottom, 2)
            if listSubagents.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.tertiaryText)
                    .padding(.leading, 4)
            }
            ForEach(listSubagents, id: \.id) { subagent in
                card(subagent, setFocus: setFocus, now: now)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: Self.cardWidth, alignment: .topLeading)
    }

    /// The fold that lays out an agent's subagents in a column of their own.
    private func subagentToggle(of agentId: String, count: Int) -> some View {
        let isOpen = memory.boardSubagentsOf == agentId
        return Button {
            withAnimation(Self.reorderAnimation) {
                memory.boardSubagentsOf = isOpen ? nil : agentId
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(.chevronRight)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(count == 1 ? "1 subagent" : "\(count) subagents")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Fold the subagents away" : "Show the subagents beside the agents")
    }

    private func card(_ resource: FleetResource, setFocus: Set<FleetRef>?, now: Date, width: CGFloat = cardWidth) -> some View {
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
                FittingText(cardName(of: resource, agent: agent), size: 12, weight: .semibold)
                if resource.kind == AgentFleet.teamKind {
                    teamToggle(
                        of: resource.id,
                        count: fleetModel.teams.listTeams.first { $0.id == resource.id }?.listAgentIds.count ?? 0
                    )
                    .padding(.top, 1)
                } else {
                    Text(subtitle(of: resource, agent: agent))
                        .font(.system(size: 10))
                        .foregroundStyle(agent?.state.needsAttention == true ? AnyShapeStyle(Color.orange) : AnyShapeStyle(StageColors.secondaryText))
                        .lineLimit(1)
                }
                if let agent, agent.parentId == nil {
                    let subagentCount = fleetModel.fleet.listSubagents(of: agent.id).count
                    if subagentCount > 0 {
                        subagentToggle(of: agent.id, count: subagentCount)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(RookmasterStyle.age(of: resource.lastUsedAt, now: now))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(StageColors.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.separator),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .opacity(isDimmed ? 0.32 : 1)
        .background(StageColors.content, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .help("\(resource.displayName)\nClick to bring forward what it touches; double-click to open")
    }

    /// What a card is called: a subagent by its kind of agent, as Explore, anything else by its name.
    private func cardName(of resource: FleetResource, agent: FleetAgent?) -> String {
        guard agent?.parentId != nil, let agentType = resource.name.split(separator: "/").last else {
            return graph.name(of: FleetRef(kind: resource.kind, id: resource.id))
        }
        return String(agentType)
    }

    private func subtitle(of resource: FleetResource, agent: FleetAgent?) -> String {
        if let agent {
            return agent.state.title
        }
        if resource.kind == AgentFleet.teamKind {
            let memberCount = fleetModel.teams.listTeams.first { $0.id == resource.id }?.listAgentIds.count ?? 0
            return memberCount == 1 ? "1 agent" : "\(memberCount) agents"
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
        let mapFrames = mapAnchors.mapValues { proxy[$0] }
        return Canvas { context, _ in
            for edge in listEdges {
                guard let sourceFrame = mapFrames[edge.source], let targetFrame = mapFrames[edge.target] else {
                    continue
                }
                let isFocused = setFocus.map { $0.contains(edge.source) && $0.contains(edge.target) } ?? true
                let isQuiet = setFocus == nil
                let sourceColumn = Int(sourceFrame.minX.rounded())
                let targetColumn = Int(targetFrame.minX.rounded())
                let path = Self.path(
                    from: sourceFrame,
                    to: targetFrame,
                    sourceColumn: sourceColumn,
                    targetColumn: targetColumn,
                    isMutual: edge.isMutual
                )
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

    /// An edge's curve, ending in an arrowhead at its target, and at its source too when things went both
    /// ways, leaving the side of each card that faces the other.
    private static func path(
        from source: CGRect,
        to target: CGRect,
        sourceColumn: Int,
        targetColumn: Int,
        isMutual: Bool
    ) -> Path {
        let arrowLength: CGFloat = 7
        let startEdge: CGPoint
        let endEdge: CGPoint
        let leaving: CGFloat
        let arriving: CGFloat
        if sourceColumn == targetColumn {
            startEdge = CGPoint(x: source.maxX, y: source.midY)
            endEdge = CGPoint(x: target.maxX, y: target.midY)
            leaving = 1
            arriving = -1
        } else if sourceColumn < targetColumn {
            startEdge = CGPoint(x: source.maxX, y: source.midY)
            endEdge = CGPoint(x: target.minX, y: target.midY)
            leaving = 1
            arriving = 1
        } else {
            startEdge = CGPoint(x: source.minX, y: source.midY)
            endEdge = CGPoint(x: target.maxX, y: target.midY)
            leaving = -1
            arriving = -1
        }
        let start = isMutual ? CGPoint(x: startEdge.x + arrowLength * leaving, y: startEdge.y) : startEdge
        let end = CGPoint(x: endEdge.x - arrowLength * arriving, y: endEdge.y)
        let reach: CGFloat
        if sourceColumn == targetColumn {
            reach = 28 + min(abs(end.y - start.y) * 0.25, 60)
        } else {
            reach = max(abs(end.x - start.x) / 2, 30)
        }
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + reach * leaving, y: start.y),
            control2: CGPoint(x: end.x - reach * arriving, y: end.y)
        )
        path.addLine(to: endEdge)
        Self.addArrowhead(to: &path, base: end, tip: endEdge)
        if isMutual {
            path.move(to: start)
            path.addLine(to: startEdge)
            Self.addArrowhead(to: &path, base: start, tip: startEdge)
        }
        return path
    }

    /// The two strokes of an arrowhead whose point is at the tip, across its base.
    private static func addArrowhead(to path: inout Path, base: CGPoint, tip: CGPoint) {
        let halfWidth: CGFloat = 4
        path.move(to: CGPoint(x: base.x, y: base.y - halfWidth))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x, y: base.y + halfWidth))
    }

    // MARK: - What the board shows

    /// Each shown kind's cards, in order, after the filters.
    private func columns(now: Date) -> [String: [FleetResource]] {
        let trimmedQuery = memory.boardQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let cutoff = memory.boardWindow.seconds.map { now.addingTimeInterval(-$0) }
        let setScope = ravenScopeId.map(ravenScope(of:))
        var mapColumns: [String: [FleetResource]] = [:]
        for kind in listShownKinds {
            var listResources = graph.listResources(of: kind.name).filter { resource in
                if resource.isRookeryOwn {
                    return false
                }
                if let setScope, !setScope.contains(FleetRef(kind: resource.kind, id: resource.id)) {
                    return false
                }
                if kind.name == AgentFleet.agentKind {
                    let agent = fleetModel.fleet.mapAgents[resource.id]
                    if agent?.parentId != nil || foldingTeam(of: resource.id) != nil {
                        return false
                    }
                    if memory.isBoardLiveOnly && agent?.state == .ended {
                        return false
                    }
                }
                if !trimmedQuery.isEmpty && !"\(resource.displayName) \(resource.name) \(resource.id)".lowercased().contains(trimmedQuery) {
                    return false
                }
                if
                    kind.name != AgentFleet.teamKind,
                    let cutoff,
                    let used = FleetTimestamp.date(from: resource.lastUsedAt),
                    used < cutoff
                {
                    return false
                }
                return true
            }
            if kind.name == AgentFleet.agentKind {
                listResources = byTeam(listResources)
            } else if kind.name == AgentFleet.teamKind {
                let mapTeamIndices = Dictionary(
                    fleetModel.teams.listTeams.enumerated().map { ($1.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                listResources.sort { (mapTeamIndices[$0.id] ?? Int.max) < (mapTeamIndices[$1.id] ?? Int.max) }
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
        if
            listShownKinds.contains(where: { $0.name == AgentFleet.agentKind }),
            let parentId = memory.boardSubagentsOf,
            foldingTeam(of: parentId) == nil
        {
            mapColumns[Self.subagentColumnKey] = graph.listResources(of: AgentFleet.agentKind).filter { resource in
                fleetModel.fleet.mapAgents[resource.id]?.parentId == parentId
            }
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

    /// The edges between shown cards, a subagent's drawn from its session and a folded repository's
    /// skills' from its card. An agent mounting or using a skill of a playbook it follows draws no edge of
    /// its own: its line to the playbook and the playbook's to the skill say so already.
    private func edges(among mapColumns: [String: [FleetResource]]) -> [BoardEdge] {
        var setShown = Set(mapColumns.values.flatMap { $0.map { FleetRef(kind: $0.kind, id: $0.id) } })
        var mapFolded: [FleetRef: FleetRef] = [:]
        for (repoUrl, listMembers) in repoGroups(of: mapColumns[Self.skillKind] ?? []) where !memory.setBoardOpenRepos.contains(repoUrl) {
            let repoRef = FleetRef(kind: Self.repoKind, id: repoUrl)
            setShown.insert(repoRef)
            for resource in listMembers {
                mapFolded[FleetRef(kind: resource.kind, id: resource.id)] = repoRef
            }
        }
        let mapPlaybookSkills = graph.mapRelations.values.reduce(into: [FleetRef: Set<FleetRef>]()) { map, relation in
            if relation.source.kind == Self.playbookKind, relation.target.kind == Self.skillKind {
                map[relation.source, default: []].insert(relation.target)
            }
        }
        let mapPlaybookMounts = graph.mapRelations.values.reduce(into: [FleetRef: Set<FleetRef>]()) { map, relation in
            if relation.verb == Self.followsVerb, relation.target.kind == Self.playbookKind {
                map[shownRef(of: relation.source, among: setShown), default: []].formUnion(mapPlaybookSkills[relation.target] ?? [])
            }
        }
        var mapEdges: [String: BoardEdge] = [:]
        for relation in graph.mapRelations.values {
            if
                Self.setPlaybookSkillVerbs.contains(relation.verb),
                mapPlaybookMounts[shownRef(of: relation.source, among: setShown)]?.contains(relation.target) == true
            {
                continue
            }
            let source = mapFolded[relation.source] ?? shownRef(of: relation.source, among: setShown)
            let target = mapFolded[relation.target] ?? shownRef(of: relation.target, among: setShown)
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
                known.isMutual = known.isMutual || known.source != source
                mapEdges[edge.id] = known
            } else {
                mapEdges[edge.id] = edge
            }
        }
        for team in fleetModel.teams.listTeams {
            let teamRef = FleetRef(kind: AgentFleet.teamKind, id: team.id)
            guard setShown.contains(teamRef) else {
                continue
            }
            for agentId in team.listAgentIds {
                let agentRef = FleetRef(kind: AgentFleet.agentKind, id: agentId)
                guard setShown.contains(agentRef) else {
                    continue
                }
                let edge = BoardEdge(source: teamRef, target: agentRef, listVerbs: [Self.memberVerb], count: 1, lastAt: "")
                if mapEdges[edge.id] == nil {
                    mapEdges[edge.id] = edge
                }
            }
        }
        return mapEdges.values.sorted { $0.lastAt < $1.lastAt }
    }

    /// The card a resource shows on: its own; its session's for a subagent whose own is not laid out; and
    /// its team's for an agent, or a subagent of one, whose teams are all folded.
    private func shownRef(of ref: FleetRef, among setShown: Set<FleetRef>) -> FleetRef {
        guard ref.kind == AgentFleet.agentKind, !setShown.contains(ref) else {
            return ref
        }
        let sessionRef = fleetModel.fleet.mapAgents[ref.id]?.parentId.map { FleetRef(kind: ref.kind, id: $0) } ?? ref
        if let teamId = foldingTeam(of: sessionRef.id) {
            return FleetRef(kind: AgentFleet.teamKind, id: teamId)
        }
        return sessionRef
    }

    /// The folded team an agent's card folds into, when every team it is in is folded; nil while it is in
    /// no team or in one laid out.
    private func foldingTeam(of agentId: String) -> String? {
        let listTeamIds = fleetModel.teams.teamIds(of: agentId)
        guard !listTeamIds.isEmpty, listTeamIds.allSatisfy(memory.setBoardFoldedTeams.contains) else {
            return nil
        }
        return listTeamIds.first
    }

    /// The fold that lays a team's agents out beside it or folds them, and the lines they draw, into its
    /// card.
    private func teamToggle(of teamId: String, count: Int) -> some View {
        let isFolded = memory.setBoardFoldedTeams.contains(teamId)
        return Button {
            withAnimation(Self.reorderAnimation) {
                if isFolded {
                    memory.setBoardFoldedTeams.remove(teamId)
                } else {
                    memory.setBoardFoldedTeams.insert(teamId)
                    if let parentId = memory.boardSubagentsOf, foldingTeam(of: parentId) != nil {
                        memory.boardSubagentsOf = nil
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(.chevronRight)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                Text(count == 1 ? "1 agent" : "\(count) agents")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(isFolded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolded ? "Lay the team's agents out" : "Fold the team's agents, and their lines, into the team")
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
