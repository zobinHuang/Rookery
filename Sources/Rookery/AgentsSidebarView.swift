import AppKit
import RookeryCore
import SwiftUI

/// What an agent drag carries, as text: an agent, or one of the user's groups of agents.
enum AgentPayload {
    case agent(String)
    case group(String)

    private static let agentPrefix = "rookery-agent:"
    private static let groupPrefix = "rookery-agent-group:"

    init?(_ text: String) {
        if text.hasPrefix(Self.agentPrefix) {
            self = .agent(String(text.dropFirst(Self.agentPrefix.count)))
        } else if text.hasPrefix(Self.groupPrefix) {
            self = .group(String(text.dropFirst(Self.groupPrefix.count)))
        } else {
            return nil
        }
    }

    var text: String {
        switch self {
        case .agent(let agentId): Self.agentPrefix + agentId
        case .group(let groupId): Self.groupPrefix + groupId
        }
    }
}

/// The sidebar's Agents mode: every agent roost knows of as a crow playing its state, in the groups the
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
    /// Make the stage take typing, while a group's name is edited.
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void

    @State private var hoveredRowId: String?
    @State private var setExpandedAgentIds: Set<String> = []
    @State private var isEndedExpanded = false
    @State private var editingGroupId: String?
    @State private var dropTargetId: String?

    var body: some View {
        VStack(spacing: 6) {
            if fleetModel.connection != .online {
                connectionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            rookmasterButton
            if isCollapsed {
                collapsedList
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        groupedSections
                        ungroupedSection
                        endedSection
                        newGroupRow
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .animation(Self.rowAnimation, value: fleetModel.groups)
                    .animation(Self.rowAnimation, value: listLiveIds)
                }
            }
        }
        .animation(Self.rowAnimation, value: fleetModel.connection)
    }

    // MARK: - Sections

    private var rookmasterButton: some View {
        Button(action: onOpenRookmaster) {
            HStack(spacing: 8) {
                PixelIconView(.crown)
                    .frame(width: 22, height: 22)
                if !isCollapsed {
                    Text("Rookmaster")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isRookmasterShown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.primaryText))
                    Spacer(minLength: 0)
                    PixelIconView(.chevronRight)
                        .foregroundStyle(StageColors.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isRookmasterShown ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(StageColors.tile))
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

    /// The sessions not in any group, live first, then those that ended.
    private var listUngrouped: [FleetAgent] {
        fleet.listSessions.filter { fleetModel.groups.groupId(of: $0.id) == nil }
    }

    private var listLiveIds: [String] {
        listUngrouped.filter { $0.state != .ended }.map(\.id)
    }

    @ViewBuilder
    private var groupedSections: some View {
        ForEach(fleetModel.groups.listGroups) { group in
            let listAgents = group.listAgentIds.compactMap { fleet.mapAgents[$0] }
            groupHeader(group, count: listAgents.count)
            if !group.isCollapsed {
                ForEach(listAgents) { agent in
                    agentRows(agent, groupId: group.id)
                }
            }
        }
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        let listLive = listUngrouped.filter { $0.state != .ended }
        if !fleetModel.groups.listGroups.isEmpty && !listLive.isEmpty {
            sectionHeader("Ungrouped", count: listLive.count, dropId: "ungrouped") {
                dropAgent($0, into: nil, before: nil)
            }
        }
        ForEach(listLive) { agent in
            agentRows(agent, groupId: nil)
        }
        if listLive.isEmpty && fleetModel.groups.listGroups.isEmpty && fleetModel.connection == .online {
            Text("No agents running. Start one in a tmux pane with rook set up, and its crow lands here.")
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .padding(10)
        }
    }

    @ViewBuilder
    private var endedSection: some View {
        let listEnded = listUngrouped.filter { $0.state == .ended }
        if !listEnded.isEmpty {
            Button {
                withAnimation(Self.rowAnimation) {
                    isEndedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    PixelIconView(.chevronRight)
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
                    agentRows(agent, groupId: nil)
                }
            }
        }
    }

    private var newGroupRow: some View {
        let isTargeted = dropTargetId == "new-group"
        return Button {
            fleetModel.addGroup(title: "New Group")
            startRenamingNewestGroup()
        } label: {
            PixelLabel("New Group", icon: .plus)
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
        .help("Make a group, or drop an agent here to start one with it")
        .dropDestination(for: String.self) { listTexts, _ in
            guard case .agent(let agentId) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            fleetModel.addGroup(title: "New Group", with: agentId)
            startRenamingNewestGroup()
            return true
        } isTargeted: { isTargeted in
            updateDropTarget("new-group", isTargeted: isTargeted)
        }
    }

    // MARK: - Rows

    private func groupHeader(_ group: AgentGroup, count: Int) -> some View {
        let isTargeted = dropTargetId == group.id
        let isHovered = hoveredRowId == group.id
        return HStack(spacing: 6) {
            PixelIconView(.chevronRight)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(StageColors.secondaryText)
            if editingGroupId == group.id {
                InlineRenameField(initialText: group.title, placeholder: "Group name") { title in
                    fleetModel.renameGroup(group.id, to: title)
                    finishRenaming()
                } onCancel: {
                    finishRenaming()
                }
                .font(.system(size: 12, weight: .semibold))
            } else {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(StageColors.tertiaryText)
            Spacer(minLength: 0)
            if isHovered && editingGroupId != group.id {
                Menu {
                    Button("Rename Group…") {
                        startRenaming(group.id)
                    }
                    Button("Remove Group", role: .destructive) {
                        fleetModel.removeGroup(group.id)
                    }
                } label: {
                    PixelIconView(.ellipsis)
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
            startRenaming(group.id)
        }
        .onTapGesture {
            withAnimation(Self.rowAnimation) {
                fleetModel.toggleGroup(group.id)
            }
        }
        .onHover { isInside in
            hover(group.id, isInside: isInside)
        }
        .contextMenu {
            Button("Rename Group…") {
                startRenaming(group.id)
            }
            Button("Remove Group", role: .destructive) {
                fleetModel.removeGroup(group.id)
            }
        }
        .onDrag {
            NSItemProvider(object: AgentPayload.group(group.id).text as NSString)
        }
        .dropDestination(for: String.self) { listTexts, _ in
            switch listTexts.first.flatMap(AgentPayload.init) {
            case .agent(let agentId):
                return dropAgent(agentId, into: group.id, before: nil)
            case .group(let groupId):
                fleetModel.moveGroup(groupId, before: group.id)
                return true
            case nil:
                return false
            }
        } isTargeted: { isTargeted in
            updateDropTarget(group.id, isTargeted: isTargeted)
        }
    }

    private func sectionHeader(_ title: String, count: Int, dropId: String, onDrop: @escaping (String) -> Bool) -> some View {
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
            guard case .agent(let agentId) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            return onDrop(agentId)
        } isTargeted: { isTargeted in
            updateDropTarget(dropId, isTargeted: isTargeted)
        }
    }

    @ViewBuilder
    private func agentRows(_ agent: FleetAgent, groupId: String?) -> some View {
        let listSubagents = fleet.listSubagents(of: agent.id)
        agentRow(agent, groupId: groupId, subagentCount: listSubagents.count)
        if setExpandedAgentIds.contains(agent.id) {
            ForEach(listSubagents) { subagent in
                agentRow(subagent, groupId: nil, subagentCount: 0)
                    .padding(.leading, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func agentRow(_ agent: FleetAgent, groupId: String?, subagentCount: Int) -> some View {
        let isSubagent = agent.parentId != nil
        let isSelected = selectedAgentId == agent.id
        let isHovered = hoveredRowId == agent.id
        let isTargeted = dropTargetId == agent.id
        let isReachable = fleet.isOnline(agent) || agent.state == .ended
        return Button {
            onSelect(agent.id)
        } label: {
            HStack(spacing: 8) {
                CrowView(state: agent.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName)
                        .font(.system(size: isSubagent ? 12 : 13, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.primaryText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(of: agent, isReachable: isReachable))
                        .font(.system(size: 11))
                        .foregroundStyle(agent.state.needsAttention ? AnyShapeStyle(Color.orange) : AnyShapeStyle(StageColors.secondaryText))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                if subagentCount > 0 {
                    subagentToggle(agent.id, count: subagentCount)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .opacity(agent.state == .ended || !isReachable ? 0.55 : 1)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill(isSelected: isSelected, isHovered: isHovered, isTargeted: isTargeted))
                    .strokeBorder(isSelected ? StageColors.contrastActiveBorder : .clear)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 20)
                        .offset(x: -6)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agent.title.isEmpty ? agent.name : "\(agent.title)\n\(agent.name)")
        .onHover { isInside in
            hover(agent.id, isInside: isInside)
        }
        .animation(.easeOut(duration: 0.2), value: agent.state)
        .contextMenu {
            if !isSubagent {
                Menu("Move to Group") {
                    ForEach(fleetModel.groups.listGroups) { group in
                        Button(group.title) {
                            fleetModel.move(agent.id, to: group.id)
                        }
                    }
                    Divider()
                    Button("New Group") {
                        fleetModel.addGroup(title: "New Group", with: agent.id)
                        startRenamingNewestGroup()
                    }
                }
                if groupId != nil {
                    Button("Remove from Group") {
                        fleetModel.move(agent.id, to: nil)
                    }
                }
            }
            Button("Copy Agent ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.id, forType: .string)
            }
        }
        .onDrag {
            NSItemProvider(object: AgentPayload.agent(isSubagent ? (agent.parentId ?? agent.id) : agent.id).text as NSString)
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
            guard !isSubagent, case .agent(let draggedId) = listTexts.first.flatMap(AgentPayload.init) else {
                return false
            }
            return dropAgent(draggedId, into: groupId, before: groupId == nil ? nil : agent.id)
        } isTargeted: { isTargeted in
            updateDropTarget(agent.id, isTargeted: isTargeted && !isSubagent)
        }
        .overlay(alignment: .top) {
            if isTargeted && groupId != nil {
                InsertionMark(isVertical: false)
                    .offset(y: -2)
            }
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
            HStack(spacing: 3) {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                PixelIconView(.chevronDown)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(StageColors.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(StageColors.groove, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Fold the subagents away" : "Show \(count) subagents")
    }

    private func subtitle(of agent: FleetAgent, isReachable: Bool) -> String {
        var listParts = [agent.state.title]
        if !isReachable {
            listParts = ["\(agent.rookName.isEmpty ? "Machine" : agent.rookName) offline"]
        }
        if !agent.projectName.isEmpty && agent.projectName != "/" {
            listParts.append(agent.projectName)
        }
        if !agent.gitBranch.isEmpty {
            listParts.append(agent.gitBranch)
        }
        return listParts.joined(separator: " · ")
    }

    private func rowFill(isSelected: Bool, isHovered: Bool, isTargeted: Bool) -> AnyShapeStyle {
        if isTargeted {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.2 : 0.15))
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
        let fill = isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(StageColor.clear)
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
                PixelIconView(.offline)
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
                PixelIconView(.warning)
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

    private func dropAgent(_ agentId: String, into groupId: String?, before beforeAgentId: String?) -> Bool {
        withAnimation(Self.rowAnimation) {
            fleetModel.move(agentId, to: groupId, before: beforeAgentId)
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

    private func startRenaming(_ groupId: String) {
        onBeginEditing()
        editingGroupId = groupId
    }

    private func startRenamingNewestGroup() {
        if let groupId = fleetModel.groups.listGroups.last?.id {
            startRenaming(groupId)
        }
    }

    private func finishRenaming() {
        editingGroupId = nil
        onEndEditing()
    }
}
