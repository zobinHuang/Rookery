import AppKit
import RookeryCore
import SwiftUI

/// What an agent drag carries, as text: an agent, or one of the user's teams of agents.
enum AgentPayload {
    /// An agent, and the team it was dragged out of, if any.
    case agent(String, fromTeam: String?)
    case team(String)

    private static let agentPrefix = "rookery-agent:"
    private static let teamPrefix = "rookery-agent-team:"
    private static let teamSeparator: Character = "|"

    init?(_ text: String) {
        if text.hasPrefix(Self.agentPrefix) {
            let listParts = text.dropFirst(Self.agentPrefix.count).split(separator: Self.teamSeparator, maxSplits: 1).map(String.init)
            guard let agentId = listParts.first else {
                return nil
            }
            self = .agent(agentId, fromTeam: listParts.count > 1 ? listParts[1] : nil)
        } else if text.hasPrefix(Self.teamPrefix) {
            self = .team(String(text.dropFirst(Self.teamPrefix.count)))
        } else {
            return nil
        }
    }

    var text: String {
        switch self {
        case .agent(let agentId, let teamId): Self.agentPrefix + agentId + (teamId.map { "\(Self.teamSeparator)\($0)" } ?? "")
        case .team(let teamId): Self.teamPrefix + teamId
        }
    }
}

/// The sidebar's Agents mode: every agent roost knows of as a crow playing its state, in the teams the
/// user dragged them into, then the rest, then those that ended. A session's subagents fold under it.
struct AgentsSidebarView: View {
    private static let rowAnimation = Animation.spring(response: 0.3, dampingFraction: 0.85)
    private static let endedShownLimit = 30

    let fleetModel: FleetModel
    let isCollapsed: Bool
    /// The agent whose page the content area shows, if any.
    let selectedAgentId: String?
    let onSelect: (String) -> Void
    let onOpenSettings: () -> Void
    /// Whether the content area shows the Rookmaster console.
    let isRookmasterShown: Bool
    let onOpenRookmaster: () -> Void
    /// Make the stage take typing, while a team's name is edited.
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void

    @State private var hoveredRowId: String?
    @State private var setExpandedAgentIds: Set<String> = []
    @State private var isEndedExpanded = false
    @State private var editingTeamId: String?
    @State private var dropTargetId: String?

    var body: some View {
        VStack(spacing: 6) {
            if fleetModel.connection != .online {
                connectionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            rookmasterButton
            if let teamError = fleetModel.teamError, !isCollapsed {
                HStack(alignment: .top, spacing: 6) {
                    RookeryIconView(.warning)
                        .foregroundStyle(.orange)
                    Text(teamError)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button {
                        fleetModel.teamError = nil
                    } label: {
                        RookeryIconView(.close)
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
                .padding(8)
                .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if isCollapsed {
                collapsedList
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        teamedSections
                        unassignedSection
                        endedSection
                        newTeamRow
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .animation(Self.rowAnimation, value: fleetModel.teams)
                    .animation(Self.rowAnimation, value: listLiveIds)
                }
            }
        }
        .animation(Self.rowAnimation, value: fleetModel.connection)
        .animation(Self.rowAnimation, value: fleetModel.teamError)
    }

    // MARK: - Sections

    private var rookmasterButton: some View {
        Button(action: onOpenRookmaster) {
            HStack(spacing: 8) {
                RookeryIconView(.crown)
                    .frame(width: 22, height: 22)
                if !isCollapsed {
                    Text("Rookmaster")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StageColors.primaryText)
                    Spacer(minLength: 0)
                    RookeryIconView(.chevronRight)
                        .foregroundStyle(StageColors.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isRookmasterShown ? AnyShapeStyle(StageColors.selectedRow) : AnyShapeStyle(StageColors.tile))
                    .strokeBorder(isRookmasterShown ? StageColors.contrastActiveBorder : .clear)
                    .shadow(color: isRookmasterShown ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("The board of every agent, skill, playbook and memory, and the log of what they do")
    }

    private var fleet: AgentFleet {
        fleetModel.fleet
    }

    /// The sessions not in any team, live first, then those that ended.
    private var listUnassigned: [FleetAgent] {
        fleet.listSessions.filter { fleetModel.teams.teamId(of: $0.id) == nil }
    }

    private var listLiveIds: [String] {
        listUnassigned.filter { $0.state != .ended }.map(\.id)
    }

    @ViewBuilder
    private var teamedSections: some View {
        ForEach(fleetModel.teams.listTeams) { team in
            let listAgents = team.listAgentIds.compactMap { fleet.mapAgents[$0] }.filter { !$0.isRookeryOwn }
            teamHeader(team, count: listAgents.count)
            if !team.isCollapsed {
                ForEach(listAgents) { agent in
                    agentRows(agent, teamId: team.id)
                }
            }
        }
    }

    @ViewBuilder
    private var unassignedSection: some View {
        let listLive = listUnassigned.filter { $0.state != .ended }
        if !fleetModel.teams.listTeams.isEmpty && !listLive.isEmpty {
            sectionHeader("Unassigned", count: listLive.count, dropId: "unassigned") { agentId, sourceTeamId in
                dropAgent(agentId, from: sourceTeamId, into: nil, before: nil)
            }
        }
        ForEach(listLive) { agent in
            agentRows(agent, teamId: nil)
        }
        if listLive.isEmpty && fleetModel.teams.listTeams.isEmpty && fleetModel.connection == .online {
            Text("No agents running. Start one in a tmux pane with rook set up, and its crow lands here.")
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .padding(10)
        }
    }

    @ViewBuilder
    private var endedSection: some View {
        let listEnded = listUnassigned.filter { $0.state == .ended }
        if !listEnded.isEmpty {
            Button {
                withAnimation(Self.rowAnimation) {
                    isEndedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    RookeryIconView(.chevronRight)
                        .rotationEffect(.degrees(isEndedExpanded ? 90 : 0))
                    Text("Ended")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(listEnded.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.tertiaryText)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StageColors.secondaryText)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isEndedExpanded {
                ForEach(listEnded.prefix(Self.endedShownLimit)) { agent in
                    agentRows(agent, teamId: nil)
                }
            }
        }
    }

    private var newTeamRow: some View {
        let isTargeted = dropTargetId == "new-team"
        return Button {
            fleetModel.addTeam(title: "New Team")
            startRenamingNewestTeam()
        } label: {
            RookeryLabel("New Team", icon: .plus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.separator),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Make a team, or drop an agent here to start one with it")
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .agent(let agentId, _) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            fleetModel.addTeam(title: "New Team", with: agentId)
            startRenamingNewestTeam()
            return true
        } isTargeted: { isTargeted in
            updateDropTarget("new-team", isTargeted: isTargeted)
        }
    }

    // MARK: - Rows

    private func teamHeader(_ team: AgentTeam, count: Int) -> some View {
        let isTargeted = dropTargetId == team.id
        let isHovered = hoveredRowId == team.id
        return HStack(spacing: 6) {
            RookeryIconView(.chevronRight)
                .rotationEffect(.degrees(team.isCollapsed ? 0 : 90))
                .foregroundStyle(StageColors.secondaryText)
            if editingTeamId == team.id {
                InlineRenameField(initialText: team.title, placeholder: "Team name") { title in
                    fleetModel.renameTeam(team.id, to: title)
                    finishRenaming()
                } onCancel: {
                    finishRenaming()
                }
                .font(.system(size: 12, weight: .semibold))
            } else {
                Text(team.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(StageColors.tertiaryText)
            Spacer(minLength: 0)
            if isHovered && editingTeamId != team.id {
                Menu {
                    Button("Rename Team…") {
                        startRenaming(team.id)
                    }
                    Button("Remove Team", role: .destructive) {
                        fleetModel.removeTeam(team.id)
                    }
                } label: {
                    RookeryIconView(.ellipsis)
                        .foregroundStyle(StageColors.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.16) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            startRenaming(team.id)
        }
        .onTapGesture {
            withAnimation(Self.rowAnimation) {
                fleetModel.toggleTeam(team.id)
            }
        }
        .onHover { isInside in
            hover(team.id, isInside: isInside)
        }
        .contextMenu {
            Button("Rename Team…") {
                startRenaming(team.id)
            }
            Button("Remove Team", role: .destructive) {
                fleetModel.removeTeam(team.id)
            }
        }
        .onDrag {
            NSItemProvider(object: AgentPayload.team(team.id).text as NSString)
        }
        .dropDestination(for: String.self) { listTexts, _ in
            switch listTexts.first.flatMap(AgentPayload.init) {
            case .agent(let agentId, let sourceTeamId):
                return dropAgent(agentId, from: sourceTeamId, into: team.id, before: nil)
            case .team(let teamId):
                fleetModel.moveTeam(teamId, before: team.id)
                return true
            case nil:
                return false
            }
        } isTargeted: { isTargeted in
            updateDropTarget(team.id, isTargeted: isTargeted)
        }
    }

    private func sectionHeader(_ title: String, count: Int, dropId: String, onDrop: @escaping (String, String?) -> Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(StageColors.tertiaryText)
            Spacer(minLength: 0)
        }
        .foregroundStyle(StageColors.secondaryText)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dropTargetId == dropId ? Color.accentColor.opacity(0.16) : .clear)
        }
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .agent(let agentId, let sourceTeamId) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            return onDrop(agentId, sourceTeamId)
        } isTargeted: { isTargeted in
            updateDropTarget(dropId, isTargeted: isTargeted)
        }
    }

    @ViewBuilder
    private func agentRows(_ agent: FleetAgent, teamId: String?) -> some View {
        let listSubagents = fleet.listSubagents(of: agent.id)
        agentRow(agent, teamId: teamId, subagentCount: listSubagents.count)
        if setExpandedAgentIds.contains(agent.id) {
            ForEach(listSubagents) { subagent in
                agentRow(subagent, teamId: nil, subagentCount: 0)
                    .padding(.leading, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func agentRow(_ agent: FleetAgent, teamId: String?, subagentCount: Int) -> some View {
        let isSubagent = agent.parentId != nil
        let isSelected = selectedAgentId == agent.id
        let isHovered = hoveredRowId == agent.id
        let isTargeted = dropTargetId == agent.id
        let isReachable = fleet.isOnline(agent) || agent.state == .ended || agent.rookName.isEmpty
        return Button {
            onSelect(agent.id)
        } label: {
            HStack(spacing: 8) {
                CrowView(state: agent.state)
                VStack(alignment: .leading, spacing: 1) {
                    FittingText(agent.displayName, size: isSubagent ? 12 : 13, weight: .semibold)
                        .foregroundStyle(StageColors.primaryText)
                    tags(of: agent, isReachable: isReachable)
                    if !isSubagent {
                        identity(of: agent, shownIn: teamId)
                    }
                    if subagentCount > 0 {
                        subagentToggle(agent.id, count: subagentCount)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .opacity(agent.state == .ended || !isReachable ? 0.55 : 1)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill(isSelected: isSelected, isHovered: isHovered, isTargeted: isTargeted))
                    .strokeBorder(isSelected ? StageColors.contrastActiveBorder : .clear)
                    .shadow(color: isSelected && !isTargeted ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(StageColors.primaryText)
                        .frame(width: 3, height: 20)
                        .offset(x: -6)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rowHelp(of: agent))
        .onHover { isInside in
            hover(agent.id, isInside: isInside)
        }
        .animation(.easeOut(duration: 0.2), value: agent.state)
        .contextMenu {
            if !isSubagent {
                let setMemberOf = Set(fleetModel.teams.teamIds(of: agent.id))
                Menu("Add to Team") {
                    ForEach(fleetModel.teams.listTeams.filter { !setMemberOf.contains($0.id) }) { team in
                        Button(team.title) {
                            fleetModel.join(agent.id, to: team.id)
                        }
                    }
                    Divider()
                    Button("New Team") {
                        fleetModel.addTeam(title: "New Team", with: agent.id)
                        startRenamingNewestTeam()
                    }
                }
                if let teamId, let team = fleetModel.teams.listTeams.first(where: { $0.id == teamId }) {
                    Button("Remove from \(team.title)") {
                        fleetModel.leave(agent.id, from: teamId)
                    }
                }
            }
            Button("Copy Agent ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.id, forType: .string)
            }
        }
        .onDrag {
            NSItemProvider(object: AgentPayload.agent(isSubagent ? (agent.parentId ?? agent.id) : agent.id, fromTeam: isSubagent ? nil : teamId).text as NSString)
        } preview: {
            HStack(spacing: 8) {
                CrowView(state: agent.state)
                Text(agent.displayName)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
        }
        .dropDestination(for: String.self) { listTexts, _ in
            guard !isSubagent, case .agent(let draggedId, let sourceTeamId) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            return dropAgent(draggedId, from: sourceTeamId, into: teamId, before: teamId == nil ? nil : agent.id)
        } isTargeted: { isTargeted in
            updateDropTarget(agent.id, isTargeted: isTargeted && !isSubagent)
        }
        .overlay(alignment: .top) {
            if isTargeted && teamId != nil {
                InsertionMark(isVertical: false)
                    .offset(y: -2)
            }
        }
    }

    /// What the agent does now, or who it is, and the other teams it is in.
    @ViewBuilder
    private func identity(of agent: FleetAgent, shownIn teamId: String?) -> some View {
        let line = agent.focus.isEmpty ? agent.role : agent.focus
        let listOtherTeams = fleetModel.teams.listTeams.filter { team in
            team.id != teamId && team.listAgentIds.contains(agent.id)
        }
        if !line.isEmpty || (teamId != nil && !listOtherTeams.isEmpty) {
            HStack(spacing: 5) {
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(agent.focus.isEmpty ? "Role: \(agent.role)" : "Now: \(agent.focus)\(agent.role.isEmpty ? "" : "\nRole: \(agent.role)")")
                }
                if teamId != nil, !listOtherTeams.isEmpty {
                    InfoTag(listOtherTeams.count == 1 ? "also \(listOtherTeams[0].title)" : "+\(listOtherTeams.count) teams", tint: .teal)
                        .help("Also in " + listOtherTeams.map(\.title).joined(separator: ", "))
                        .layoutPriority(1)
                }
            }
            .padding(.top, 2)
        }
    }

    private func subagentToggle(_ agentId: String, count: Int) -> some View {
        let isExpanded = setExpandedAgentIds.contains(agentId)
        return Button {
            withAnimation(Self.rowAnimation) {
                if isExpanded {
                    setExpandedAgentIds.remove(agentId)
                } else {
                    setExpandedAgentIds.insert(agentId)
                }
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(.chevronRight)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(count == 1 ? "1 subagent" : "\(count) subagents")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(StageColors.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Fold the subagents away" : "Show \(count) subagents")
    }

    /// The agent's state, repository and branch, each in a tag of its own under a small caption.
    private func tags(of agent: FleetAgent, isReachable: Bool) -> some View {
        let hasRook = !agent.hostname.isEmpty || !agent.rookName.isEmpty
        let hasRepo = !agent.projectName.isEmpty && agent.projectName != "/"
        let hasBranch = !agent.gitBranch.isEmpty
        return ViewThatFits(in: .horizontal) {
            tagRow(of: agent, isReachable: isReachable, showsRook: hasRook, showsRepo: hasRepo, showsBranch: hasBranch)
            tagRow(of: agent, isReachable: isReachable, showsRook: hasRook, showsRepo: hasRepo, showsBranch: false)
            tagRow(of: agent, isReachable: isReachable, showsRook: hasRook, showsRepo: false, showsBranch: false)
            tagRow(of: agent, isReachable: isReachable, showsRook: false, showsRepo: false, showsBranch: false)
        }
        .animation(.easeOut(duration: 0.2), value: agent.state)
    }

    /// The tags on one line, each whole; the row drops the branch, then the repository, then the host, where
    /// it runs out of width.
    private func tagRow(
        of agent: FleetAgent,
        isReachable: Bool,
        showsRook: Bool,
        showsRepo: Bool,
        showsBranch: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            captioned("status") {
                if isReachable {
                    InfoTag(agent.state.title, tint: agent.state.needsAttention ? .orange : nil)
                } else {
                    InfoTag("offline", tint: .orange)
                }
            }
            if showsRook {
                captioned("host") {
                    InfoTag(agent.hostname.isEmpty ? agent.rookName : agent.hostname)
                }
            }
            if showsRepo {
                captioned("repo") {
                    InfoTag(agent.projectName)
                }
            }
            if showsBranch {
                captioned("branch") {
                    InfoTag(agent.gitBranch)
                }
            }
        }
        .fixedSize()
    }

    /// The row's tooltip: the agent's names, and where it works.
    private func rowHelp(of agent: FleetAgent) -> String {
        let listLines = [
            agent.title,
            agent.name,
            agent.cwd,
            agent.gitBranch.isEmpty ? "" : "branch \(agent.gitBranch)",
        ]
        return listLines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func captioned<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
                .padding(.leading, 2)
            content()
        }
    }

    private func rowFill(isSelected: Bool, isHovered: Bool, isTargeted: Bool) -> AnyShapeStyle {
        if isTargeted {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if isSelected {
            return AnyShapeStyle(isHovered ? StageColors.selectedRowHovered : StageColors.selectedRow)
        }
        return isHovered ? AnyShapeStyle(StageColors.hoveredRow) : AnyShapeStyle(StageColor.clear)
    }

    // MARK: - Collapsed sidebar and status

    private var collapsedList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(fleet.listSessions.filter { $0.state != .ended }) { agent in
                    collapsedCrow(agent)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func collapsedCrow(_ agent: FleetAgent) -> some View {
        let isSelected = selectedAgentId == agent.id
        let fill = isSelected ? AnyShapeStyle(StageColors.selectedRow) : AnyShapeStyle(StageColor.clear)
        return Button {
            onSelect(agent.id)
        } label: {
            CrowView(state: agent.state)
                .padding(3)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if agent.state.needsAttention {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("\(agent.displayName): \(agent.state.title)")
    }

    @ViewBuilder
    private var connectionBanner: some View {
        let isCollapsedBanner = isCollapsed
        HStack(spacing: 8) {
            switch fleetModel.connection {
            case .notConfigured:
                RookeryIconView(.offline)
                if !isCollapsedBanner {
                    Text("Connect Rookery to roost to see your agents.")
                    Spacer(minLength: 0)
                    Button("Set Up…", action: onOpenSettings)
                        .controlSize(.small)
                }
            case .connecting:
                ProgressView()
                    .controlSize(.mini)
                if !isCollapsedBanner {
                    Text("Connecting to roost…")
                    Spacer(minLength: 0)
                }
            case .offline(let reason):
                RookeryIconView(.warning)
                    .foregroundStyle(.orange)
                if !isCollapsedBanner {
                    Text(reason)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            case .online:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(StageColors.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 8)
        .help(bannerHelp)
    }

    private var bannerHelp: String {
        if case .offline(let reason) = fleetModel.connection {
            return reason
        }
        return ""
    }

    // MARK: - Editing and dropping

    /// Drop an agent: into a team, which it joins, or with Option held moves into from the team it was
    /// dragged out of; or out of the team it was dragged from, into the unassigned.
    private func dropAgent(_ agentId: String, from sourceTeamId: String?, into teamId: String?, before beforeAgentId: String?) -> Bool {
        let isMoving = NSEvent.modifierFlags.contains(.option)
        withAnimation(Self.rowAnimation) {
            if let teamId {
                if let sourceTeamId, isMoving {
                    fleetModel.move(agentId, from: sourceTeamId, to: teamId, before: beforeAgentId)
                } else {
                    fleetModel.join(agentId, to: teamId, before: beforeAgentId)
                }
            } else if let sourceTeamId {
                fleetModel.leave(agentId, from: sourceTeamId)
            }
        }
        dropTargetId = nil
        return true
    }

    private func updateDropTarget(_ targetId: String, isTargeted: Bool) {
        if isTargeted {
            dropTargetId = targetId
        } else if dropTargetId == targetId {
            dropTargetId = nil
        }
    }

    private func hover(_ rowId: String, isInside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if isInside {
                hoveredRowId = rowId
            } else if hoveredRowId == rowId {
                hoveredRowId = nil
            }
        }
    }

    private func startRenaming(_ teamId: String) {
        onBeginEditing()
        editingTeamId = teamId
    }

    private func startRenamingNewestTeam() {
        if let teamId = fleetModel.teams.listTeams.last?.id {
            startRenaming(teamId)
        }
    }

    private func finishRenaming() {
        editingTeamId = nil
        onEndEditing()
    }
}
