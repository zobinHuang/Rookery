import RookeryCore
import SwiftUI

/// The teams roost holds, in the Rookmaster console: a list of them, and beside it the chosen one: its
/// goal, each member's card with its duty, the messages its agents sent one another, those roost held for
/// the user to release or cancel, a box to speak to the whole team, and the limits that hold messages.
struct RookmasterTeamsView: View {
    private static let listWidth: CGFloat = 280

    let fleetModel: FleetModel
    @Binding var selectedRef: FleetRef?

    @State private var isCreating = false

    private var listTeams: [FleetResource] {
        fleetModel.listTeamResources
    }

    private var selectedTeam: FleetResource? {
        guard let selectedRef, selectedRef.kind == AgentFleet.teamKind else {
            return nil
        }
        return fleetModel.graph.resource(selectedRef)
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
            Group {
                if let team = selectedTeam {
                    TeamDetail(fleetModel: fleetModel, team: team) {
                        selectedRef = nil
                    }
                    .id(team.id)
                } else {
                    VStack(spacing: 8) {
                        RookeryIconView(.board, scale: 3)
                            .foregroundStyle(StageColors.tertiaryText)
                        Text(listTeams.isEmpty ? "No teams yet" : "Choose a team to see it")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: selectFirstIfNone)
        .onChange(of: listTeams.map(\.id)) {
            selectFirstIfNone()
        }
    }

    private func selectFirstIfNone() {
        if selectedTeam == nil, let first = listTeams.first {
            selectedRef = FleetRef(kind: AgentFleet.teamKind, id: first.id)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Button {
                let title = uniqueTitle()
                fleetModel.addTeam(title: title)
                if let teamId = fleetModel.teams.listTeams.last?.id {
                    selectedRef = FleetRef(kind: AgentFleet.teamKind, id: teamId)
                }
            } label: {
                HStack(spacing: 6) {
                    RookeryIconView(.plus)
                    Text("New Team")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(listTeams, id: \.id) { team in
                        row(team)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .modifier(RememberedScroll(key: "rookmaster.teams", memory: fleetModel.pageMemory))
        }
    }

    private func row(_ team: FleetResource) -> some View {
        let ref = FleetRef(kind: AgentFleet.teamKind, id: team.id)
        let isSelected = selectedRef == ref
        let listMembers = AgentTeams.memberIds(of: team).compactMap { fleetModel.fleet.mapAgents[$0] }.filter { !$0.isRookeryOwn }
        let heldCount = fleetModel.heldCount(in: team.id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedRef = ref
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: -18) {
                    ForEach(listMembers.prefix(3)) { agent in
                        CrowView(state: agent.state)
                    }
                }
                .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    FittingText(team.displayName, size: 12, weight: .semibold)
                    Text(listMembers.count == 1 ? "1 agent" : "\(listMembers.count) agents")
                        .font(.system(size: 10))
                        .foregroundStyle(StageColors.tertiaryText)
                }
                Spacer(minLength: 4)
                if heldCount > 0 {
                    InfoTag("\(heldCount) held", tint: .orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(StageColor.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func uniqueTitle() -> String {
        let setTitles = Set(listTeams.map(\.name))
        var title = "New Team"
        var count = 2
        while setTitles.contains(title) {
            title = "New Team \(count)"
            count += 1
        }
        return title
    }
}

/// One team: its name and goal, its members, its messages and its limits.
private struct TeamDetail: View {
    private static let refreshDelay: Duration = .milliseconds(400)
    private static let messageLimit = 500

    let fleetModel: FleetModel
    let team: FleetResource
    let onDeleted: () -> Void

    @State private var nameDraft = ""
    @State private var goalDraft = ""
    @State private var mapDutyDrafts: [String: String] = [:]
    @State private var listMessages: [FleetDelivery] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var isConfirmingDelete = false
    @FocusState private var isComposerFocused: Bool

    private var ref: FleetRef {
        FleetRef(kind: AgentFleet.teamKind, id: team.id)
    }

    private var listMemberIds: [String] {
        AgentTeams.memberIds(of: team)
    }

    private var limits: [String: JSONValue] {
        if case .object(let mapLimits) = team.mapAttributes["limits"] {
            return mapLimits
        }
        return [:]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                EditorSection(title: "Goal", hint: "what the team works toward; its agents are told") {
                    EditorField(text: $goalDraft, placeholder: "What the team works toward; press return to save")
                        .onSubmit(saveGoal)
                }
                members
                messages
                limitsSection
                if let error {
                    RookeryLabel(error, icon: .warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        .task(id: fleetModel.graph.lastSeq) {
            try? await Task.sleep(for: Self.refreshDelay)
            await refreshMessages()
        }
        .confirmationDialog("Remove the team \(team.displayName)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                fleetModel.removeTeam(team.id)
                onDeleted()
            }
        } message: {
            Text("Its agents keep running, and are no longer told of one another.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RookeryIconView(.board, scale: 1.5)
            TextField("Team name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .bold))
                .onSubmit {
                    fleetModel.renameTeam(team.id, to: nameDraft)
                }
            Spacer()
            Menu {
                Button("Remove Team…", role: .destructive) {
                    isConfirmingDelete = true
                }
            } label: {
                RookeryIconView(.ellipsis)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Members

    private var members: some View {
        EditorSection(title: "Members", hint: "each with its duty here; press return to save a duty") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(listMemberIds, id: \.self) { agentId in
                    if let agent = fleetModel.fleet.mapAgents[agentId] {
                        if agent.isRookeryOwn {
                            ravenCard(agent)
                        } else {
                            memberCard(agent)
                        }
                    }
                }
                let listOpen = fleetModel.fleet.listSessions.filter { agent in
                    agent.state != .ended && !listMemberIds.contains(agent.id)
                }
                Menu {
                    ForEach(listOpen) { agent in
                        Button(agent.displayName) {
                            fleetModel.join(agent.id, to: team.id)
                        }
                    }
                } label: {
                    RookeryLabel("Add Agent", icon: .plus, spacing: 4)
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(listOpen.isEmpty)
            }
        }
    }

    /// A conversation with Raven the user put in the team: what it is, and the ways to it and out.
    private func ravenCard(_ agent: FleetAgent) -> some View {
        let title = fleetModel.raven.conversations.conversation(agent.id)?.title ?? agent.displayName
        return HStack(alignment: .top, spacing: 10) {
            RavenView(isWorking: fleetModel.raven.isRunning(agent.id))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    FittingText("Raven [\(title)]", size: 13, weight: .semibold)
                    InfoTag("Raven")
                }
                fact("Duty", "Directs the team for you; its agents' answers go to this conversation")
                HStack(spacing: 8) {
                    Button("Open Conversation") {
                        fleetModel.raven.openConversationId = agent.id
                        fleetModel.pageMemory.panelTab = .raven
                        fleetModel.pageMemory.isPanelExpanded = true
                    }
                    Button("Remove from Team") {
                        Task {
                            await fleetModel.raven.leave(agent.id, team: team.id)
                        }
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
    }

    private func memberCard(_ agent: FleetAgent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CrowView(state: agent.state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    FittingText(agent.displayName, size: 13, weight: .semibold)
                    InfoTag(agent.state.title, tint: agent.state.needsAttention ? .orange : nil)
                    if !agent.hostname.isEmpty || !agent.rookName.isEmpty {
                        InfoTag(agent.hostname.isEmpty ? agent.rookName : agent.hostname)
                    }
                }
                if !agent.role.isEmpty {
                    fact("Role", agent.role)
                }
                if !agent.focus.isEmpty {
                    fact("Now", agent.focus)
                }
                HStack(spacing: 8) {
                    Text("Duty")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StageColors.tertiaryText)
                        .frame(width: 34, alignment: .leading)
                    EditorField(
                        text: Binding(
                            get: { mapDutyDrafts[agent.id] ?? AgentTeams.duty(of: agent.id, in: team) },
                            set: { mapDutyDrafts[agent.id] = $0 }
                        ),
                        placeholder: "What it does in this team"
                    )
                    .onSubmit {
                        if let duty = mapDutyDrafts[agent.id] {
                            fleetModel.assignDuty(duty, to: agent.id, in: team.id)
                        }
                    }
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    fleetModel.leave(agent.id, from: team.id)
                }
            } label: {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Take it out of the team")
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Messages

    private var messages: some View {
        EditorSection(title: "Messages", hint: "what its agents told one another, oldest first") {
            VStack(alignment: .leading, spacing: 6) {
                if listMessages.isEmpty {
                    Text("No messages yet")
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.tertiaryText)
                }
                ForEach(listMessages) { delivery in
                    messageRow(delivery)
                }
                RavenComposer(
                    fleetModel: fleetModel,
                    text: $draft,
                    placeholder: "Message the whole team",
                    isEnabled: !listMemberIds.isEmpty,
                    isBusy: isSending,
                    fontSize: 13,
                    onSend: send,
                    isFocused: $isComposerFocused
                )
                .padding(.top, 4)
            }
        }
    }

    private func messageRow(_ delivery: FleetDelivery) -> some View {
        let isHeld = delivery.isHeld
        let senderName = delivery.sender.kind == "person"
            ? "You"
            : delivery.mapOptions["sender_title"]?.stringValue ?? fleetModel.graph.name(of: delivery.sender)
        let recipient = delivery.mapOptions["team"]?.stringValue != nil
            ? "the team"
            : fleetModel.fleet.mapAgents[delivery.agentId]?.displayName ?? delivery.agentId
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold))
                RookeryIconView(.arrowRight)
                    .foregroundStyle(StageColors.tertiaryText)
                Text(recipient)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StageColors.secondaryText)
                if delivery.mapOptions["no_reply"]?.boolValue == true {
                    InfoTag("no reply wanted")
                }
                if let hop = delivery.mapOptions["hop"]?.numberValue, hop > 1 {
                    InfoTag("reply \(Int(hop) - 1)")
                }
                Spacer(minLength: 0)
                InfoTag(statusTitle(of: delivery), tint: isHeld ? .orange : (delivery.status == "failed" ? .red : nil))
                Text(RookmasterStyle.age(of: delivery.createdAt, now: .now))
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            Text(delivery.text)
                .font(.system(size: 12))
                .foregroundStyle(StageColors.primaryText)
                .textSelection(.enabled)
                .lineLimit(8)
            if isHeld {
                HStack(spacing: 8) {
                    Text("Held: \(delivery.reason)")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Cancel") {
                        decide(delivery, isReleased: false)
                    }
                    Button("Let It Go") {
                        decide(delivery, isReleased: true)
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isHeld ? AnyShapeStyle(Color.orange.opacity(0.5)) : AnyShapeStyle(StageColors.separator))
        }
    }

    private func statusTitle(of delivery: FleetDelivery) -> String {
        switch delivery.status {
        case "held": "held"
        case "waiting": "waiting for it to stop"
        case "pending", "sent": "on its way"
        default: delivery.status
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        EditorSection(title: "Limits", hint: "roost holds a message for you past these; the team skill keeps agents well inside them") {
            VStack(alignment: .leading, spacing: 10) {
                limitRow("A thread runs past", key: "thread_hops", defaultValue: 20, unit: "messages")
                limitRow("An agent sends more than", key: "sends_per_window", defaultValue: 30, unit: "messages")
                limitRow("Within", key: "window_minutes", defaultValue: 10, unit: "minutes")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
        }
    }

    private func limitRow(_ title: String, key: String, defaultValue: Int, unit: String) -> some View {
        let value: Int = {
            if case .number(let number) = limits[key] {
                return Int(number)
            }
            return defaultValue
        }()
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 170, alignment: .leading)
            Stepper(value: Binding(get: { value }, set: { saveLimit(key, $0) }), in: 1...500) {
                Text("\(value) \(unit)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .fixedSize()
        }
    }

    // MARK: - Work

    private func load() {
        nameDraft = team.name
        goalDraft = team.mapAttributes["goal"]?.stringValue ?? ""
    }

    private func saveGoal() {
        EditorWork(fleetModel: fleetModel, ref: ref).save(
            ["attributes": .object(["goal": .string(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines))])],
            isSaving: .constant(false),
            error: $error
        )
    }

    private func saveLimit(_ key: String, _ value: Int) {
        var mapLimits = limits
        mapLimits[key] = .number(Double(value))
        EditorWork(fleetModel: fleetModel, ref: ref).save(
            ["attributes": .object(["limits": .object(mapLimits)])],
            isSaving: .constant(false),
            error: $error
        )
    }

    private func refreshMessages() async {
        guard let client = fleetModel.client() else {
            return
        }
        do {
            let setMembers = Set(listMemberIds)
            let listRecent = try await client.recentDeliveries(limit: Self.messageLimit)
            var setBatches: Set<String> = []
            let listOldestFirst = listRecent.sorted { first, second in
                if first.createdAt != second.createdAt {
                    return first.createdAt < second.createdAt
                }
                return (first.mapOptions["hop"]?.numberValue ?? 0) < (second.mapOptions["hop"]?.numberValue ?? 0)
            }
            listMessages = listOldestFirst.filter { delivery in
                guard delivery.kind == "prompt" else {
                    return false
                }
                if delivery.mapOptions["team"]?.stringValue == team.id {
                    guard let batch = delivery.mapOptions["batch"]?.stringValue else {
                        return true
                    }
                    return setBatches.insert(batch).inserted
                }
                return delivery.mapOptions["team"] == nil
                    && delivery.sender.kind == AgentFleet.agentKind
                    && setMembers.contains(delivery.sender.id)
                    && setMembers.contains(delivery.agentId)
            }
        } catch {
            self.error = FleetModel.describe(error)
        }
    }

    /// Send every member the user's words, with what they name written out under them.
    private func send(_ request: RavenRequest) {
        let text = request.text
        guard !text.isEmpty, let client = fleetModel.client() else {
            return
        }
        let listNotes = RavenRequest.mentionLines(
            listMentions: request.listMentions,
            listPeople: fleetModel.people.book.people(mentionedIn: text),
            mapAddresses: request.mapAddresses,
            graph: fleetModel.graph
        )
        let message = ([text] + listNotes).joined(separator: "\n")
        isSending = true
        Task {
            do {
                try await client.send(message, toTeam: team.id)
                draft = ""
                error = nil
                await refreshMessages()
            } catch {
                self.error = FleetModel.describe(error)
            }
            isSending = false
        }
    }

    private func decide(_ delivery: FleetDelivery, isReleased: Bool) {
        guard let client = fleetModel.client() else {
            return
        }
        Task {
            do {
                _ = try await client.decideHeld(delivery.id, isReleased: isReleased)
                await refreshMessages()
            } catch {
                self.error = FleetModel.describe(error)
            }
        }
    }
}
