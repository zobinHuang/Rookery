import RookeryCore
import SwiftUI

/// A conversation with Raven, laid out apart from the window: it grows a line at a time as Raven answers,
/// and only it is laid out again each time.
struct RavenThreadView: View {
    let fleetModel: FleetModel
    let conversationId: String
    /// Changes when the user sends, to bring the end into view.
    var sendToken = 0
    /// Opens one of the conversation's mail drafts, by its id; nil to show them in the Mail page's Drafts.
    var onOpenDraft: ((String) -> Void)?

    var body: some View {
        LayoutIsland {
            RavenThreadContent(fleetModel: fleetModel, conversationId: conversationId, sendToken: sendToken, onOpenDraft: onOpenDraft)
        }
    }
}

/// One conversation with Raven as it reads anywhere it is shown, in the Rookmaster console and in the
/// launcher: the conversation in message bubbles, how its latest request ended if it did not answer, and
/// what Raven proposed, those waiting on the user with buttons to carry them out or not. While shown it
/// follows what became of the proposals already sent.
private struct RavenThreadContent: View {
    private static let deliveryPollInterval: Duration = .seconds(3)
    /// The most decided proposals shown above the box, the latest.
    private static let shownDecidedLimit = 3
    /// How long a proposal carried out or turned down stays in its line, to show it went.
    private static let decidedShownSeconds: TimeInterval = 20
    /// How long a proposal that failed to reach its agent stays in its line, with why.
    private static let failedShownSeconds: TimeInterval = 600
    /// The share of the conversation's height the proposals may take, scrolling past it.
    private static let proposalsHeightShare: CGFloat = 0.42
    /// The least height the proposals may take, however short the conversation.
    private static let proposalsMinHeight: CGFloat = 120

    let fleetModel: FleetModel
    let conversationId: String
    /// Changes with every request sent, to bring the conversation's end into view.
    var sendToken = 0
    var onOpenDraft: ((String) -> Void)?

    @State private var setSendingIds: Set<String> = []
    /// The moment the decided lines were last weighed, moved on as each is due to go.
    @State private var now = Date.now
    @State private var threadHeight: CGFloat = 0
    @State private var proposalsHeight: CGFloat = 0
    /// The proposal shown whole among several waiting, the rest in a line each.
    @State private var expandedProposalId: String?
    /// Whether the conversation, read, has had a moment to lay out under its stand-in, which it then
    /// replaces.
    @State private var isSettled = false
    /// How long the stand-in stays over the conversation once it is read.
    private static let settleDelay: Duration = .milliseconds(350)

    private var raven: RavenAgent {
        fleetModel.raven
    }

    /// The conversation's title, written from it once Raven first answers, and how much was asked and when.
    private func header(_ conversation: RavenConversation) -> some View {
        let listJoined = raven.teams(of: conversation.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                if conversation.turnCount > 0 {
                    joinMenu(conversation, listJoined: listJoined)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text("\(conversation.turnCount == 1 ? "1 request" : "\(conversation.turnCount) requests"), last \(conversation.lastAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                RavenFolderMenu(raven: raven, conversation: conversation, isUnrestricted: fleetModel.isRavenLocalUnrestricted)
            }
            if !listJoined.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(listJoined, id: \.id) { team in
                        teamChip(team, in: conversation)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            if let problem = raven.mapTeamErrors[conversation.id] {
                RookeryLabel(problem, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
        }
        .animation(.easeOut(duration: 0.25), value: conversation.title)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: listJoined.map(\.id))
    }

    /// The teams the conversation may join, to direct them for the user.
    private func joinMenu(_ conversation: RavenConversation, listJoined: [FleetResource]) -> some View {
        let listOthers = fleetModel.listTeamResources.filter { team in
            !listJoined.contains { $0.id == team.id }
        }
        return Menu {
            if listOthers.isEmpty {
                Text("No other team")
            }
            ForEach(listOthers, id: \.id) { team in
                Button(team.displayName) {
                    Task {
                        await raven.join(conversation.id, team: team.id)
                    }
                }
            }
        } label: {
            RookeryLabel("Join a Team", icon: .plus, spacing: 4)
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(StageButtonStyle())
        .controlSize(.small)
        .fixedSize()
        .help("Put this conversation in a team, to direct it and ask its agents for you")
    }

    /// A team the conversation directs: its name, and a way out of it.
    private func teamChip(_ team: FleetResource, in conversation: RavenConversation) -> some View {
        HStack(spacing: 5) {
            RookeryIconView(RookeryIcon.kind(AgentFleet.teamKind))
            Text(team.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Button {
                Task {
                    await raven.leave(conversation.id, team: team.id)
                }
            } label: {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Take this conversation out of \(team.displayName)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(StageColors.segmentGroove, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(StageColors.segmentGrooveBorder)
        }
        .help("Raven directs \(team.displayName) here: it messages its agents, and their answers come back to this conversation")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = raven.conversations.conversation(conversationId) {
                header(conversation)
            }
            if raven.isHistoryLoaded(conversationId) {
                TranscriptView(
                    reader: raven.shownReader(of: conversationId),
                    agentId: conversationId,
                    memory: fleetModel.pageMemory,
                    hasTranscript: true,
                    sendToken: sendToken,
                    isWorking: raven.isRunning(conversationId),
                    replierName: "Raven"
                ) {
                    Task {
                        await raven.loadEarlier(of: conversationId)
                    }
                }
                .opacity(isSettled ? 1 : 0)
                .overlay {
                    if !isSettled {
                        loadingTranscript
                            .transition(.opacity)
                    }
                }
            } else {
                loadingTranscript
                    .transition(.opacity)
            }
            status(of: conversationId)
            approvals(in: conversationId)
            proposals(in: conversationId)
            queued(in: conversationId)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            threadHeight = height
        }
        .animation(.easeOut(duration: 0.2), value: raven.isHistoryLoaded(conversationId))
        .task(id: conversationId) {
            await raven.loadHistory(of: conversationId)
        }
        .task(id: "\(conversationId) \(raven.isHistoryLoaded(conversationId))") {
            guard raven.isHistoryLoaded(conversationId) else {
                isSettled = false
                return
            }
            guard !isSettled else {
                return
            }
            do {
                try await Task.sleep(for: Self.settleDelay)
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.25)) {
                isSettled = true
            }
        }
        .task(id: conversationId) {
            while !Task.isCancelled {
                await raven.refreshDeliveries(in: conversationId)
                do {
                    try await Task.sleep(for: Self.deliveryPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// The conversation's shape while its history is read: a few bubbles, the user's on the right and
    /// Raven's on the left.
    private var loadingTranscript: some View {
        VStack(spacing: 14) {
            ForEach(Self.listLoadingWidths.indices, id: \.self) { index in
                let isTrailing = index.isMultiple(of: 2)
                HStack {
                    if isTrailing {
                        Spacer(minLength: 0)
                    }
                    SkeletonBlock(width: Self.listLoadingWidths[index], height: Self.listLoadingHeights[index], cornerRadius: 14)
                    if !isTrailing {
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The stand-in bubbles' sizes, the user's and Raven's in turn.
    private static let listLoadingWidths: [CGFloat] = [220, 320, 160, 280]
    private static let listLoadingHeights: [CGFloat] = [34, 64, 34, 48]

    // MARK: - Approvals

    /// The actions on this Mac Raven waits on the user to allow, oldest first, each a card to answer.
    @ViewBuilder
    private func approvals(in conversationId: String) -> some View {
        let listRequests = raven.mapApprovals[conversationId] ?? []
        if !listRequests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(listRequests) { request in
                    RavenApprovalCard(request: request) { choice in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            raven.decide(request, choice)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: listRequests.map(\.id))
        }
    }

    // MARK: - Queued requests

    /// What the user sent while Raven was answering, each waiting its turn in order, to take back before
    /// it goes.
    @ViewBuilder
    private func queued(in conversationId: String) -> some View {
        let listQueued = raven.mapQueuedRequests[conversationId] ?? []
        if !listQueued.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(listQueued) { queued in
                    RavenQueuedBubble(text: queued.request.text) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            raven.withdraw(queued.id, in: conversationId)
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.9, anchor: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: listQueued.map(\.id))
        }
    }

    // MARK: - Proposals

    /// What Raven proposed to do to agents in a conversation: those waiting on the user in full, with
    /// buttons to carry them out or not, and the latest decided ones in a line each while they are news:
    /// one on its way until it arrives, one that failed for a while with why, the rest for a moment.
    @ViewBuilder
    private func proposals(in conversationId: String) -> some View {
        let listProposals = (raven.mapProposals[conversationId] ?? []).filter { $0.action != .draftMail }
        let mapDecisions = raven.conversations.conversation(conversationId)?.mapDecisions ?? [:]
        let listWaiting = listProposals.filter { mapDecisions[$0.id] == nil }
        let listPending = listWaiting.enumerated().filter { index, proposal in
            !listWaiting[(index + 1)...].contains { RavenAgent.isTwinSpawn($0, of: proposal) }
        }.map(\.element)
        let listDecided = listProposals.filter { proposal in
            mapDecisions[proposal.id].map { shownUntil(of: $0) > now } ?? false
        }.suffix(Self.shownDecidedLimit)
        let nextGoneAt = listDecided.compactMap { mapDecisions[$0.id].map(shownUntil(of:)) }.min()
        let listDrafts = raven.drafts(of: conversationId)
        if !listPending.isEmpty || !listDecided.isEmpty || !listDrafts.isEmpty {
            let maxHeight = max(threadHeight * Self.proposalsHeightShare, Self.proposalsMinHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if listPending.count > 1 {
                        Text("\(listPending.count) proposals waiting")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                            .padding(.horizontal, 4)
                    }
                    ForEach(listPending) { proposal in
                        if listPending.count == 1 || expandedProposalId == proposal.id {
                            proposalCard(proposal, in: conversationId)
                        } else {
                            proposalLine(proposal, in: conversationId)
                        }
                    }
                    if !listDrafts.isEmpty {
                        draftsLine(listDrafts)
                    }
                    ForEach(Array(listDecided.reversed())) { proposal in
                        decidedLine(proposal, decision: mapDecisions[proposal.id])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    proposalsHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(proposalsHeight, maxHeight))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: listPending.map(\.id))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expandedProposalId)
            .animation(.easeOut(duration: 0.3), value: listDecided.map(\.id))
            .task(id: nextGoneAt) {
                guard let nextGoneAt, nextGoneAt < .distantFuture else {
                    return
                }
                try? await Task.sleep(for: .seconds(max(nextGoneAt.timeIntervalSinceNow, 0) + 0.1))
                guard !Task.isCancelled else {
                    return
                }
                now = .now
            }
        }
    }

    /// Until when a decided proposal keeps its line: for good while it is on its way, a while once it
    /// failed, a moment otherwise.
    private func shownUntil(of decision: RavenDecision) -> Date {
        guard case .sent(let deliveryId) = decision.outcome, let delivery = raven.mapDeliveries[deliveryId] else {
            return decision.decidedAt + Self.decidedShownSeconds
        }
        if !delivery.isSettled {
            return .distantFuture
        }
        return decision.decidedAt + (delivery.isFailed ? Self.failedShownSeconds : Self.decidedShownSeconds)
    }

    /// A proposal among several waiting, in a line: what Raven would do and to whom, its text's opening,
    /// and its buttons; a click on it shows it whole.
    private func proposalLine(_ proposal: RavenProposal, in conversationId: String) -> some View {
        let isSending = setSendingIds.contains(proposal.id)
        return HStack(spacing: 8) {
            Button {
                expandedProposalId = proposal.id
            } label: {
                HStack(spacing: 6) {
                    RookeryIconView(Self.icon(of: proposal))
                        .foregroundStyle(proposal.action == .interrupt ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(Self.lead(of: proposal))
                                .foregroundStyle(StageColors.secondaryText)
                                .lineLimit(1)
                            Text(proposal.agentTitle)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        if let error = raven.mapProposalErrors[proposal.id] {
                            RookeryLabel(error, icon: .warning)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        } else if !proposal.text.isEmpty {
                            Text(proposal.text)
                                .foregroundStyle(StageColors.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the whole proposal")
            Button("Not Now") {
                withAnimation(.easeOut(duration: 0.2)) {
                    raven.reject(proposal, in: conversationId)
                }
            }
            .disabled(isSending)
            Button {
                send(proposal, in: conversationId)
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(Self.verb(of: proposal))
                }
            }
            .buttonStyle(StageButtonStyle(kind: .prominent))
            .disabled(isSending)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3))
        }
    }

    /// The mail drafts the conversation put in Rookery's drafts, in a line, with a way to them.
    private func draftsLine(_ listDrafts: [MailReplyDraft]) -> some View {
        HStack(spacing: 8) {
            RookeryIconView(.mail)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(listDrafts.count == 1 ? "1 draft in Drafts" : "\(listDrafts.count) drafts in Drafts")
                    .font(.system(size: 12, weight: .semibold))
                Text(listDrafts.prefix(2).map { $0.subject.isEmpty ? "No subject" : $0.subject }.joined(separator: ", ") + (listDrafts.count > 2 ? ", …" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Open") {
                if let onOpenDraft, let latest = listDrafts.first {
                    onOpenDraft(latest.id)
                } else {
                    let memory = fleetModel.pageMemory
                    memory.mailPlace = .drafts
                    memory.openDraftId = listDrafts.first?.id
                    memory.requestedPage = .mail
                }
            }
            .buttonStyle(StageButtonStyle(kind: .prominent))
            .controlSize(.small)
        }
        .padding(10)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func proposalCard(_ proposal: RavenProposal, in conversationId: String) -> some View {
        let isSending = setSendingIds.contains(proposal.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RookeryIconView(Self.icon(of: proposal))
                    .foregroundStyle(proposal.action == .interrupt ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.lead(of: proposal))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(2)
                    Text(proposal.agentTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            if proposal.action == .spawn || proposal.action == .addWorkdir, let cwd = proposal.cwd {
                RookeryLabel(cwd, icon: .folder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StageColors.secondaryText)
                    .textSelection(.enabled)
            }
            if !Self.facts(of: proposal).isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(Self.facts(of: proposal), id: \.self) { fact in
                        InfoTag(fact)
                    }
                }
            }
            if !proposal.text.isEmpty {
                Text(proposal.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(StageColors.groove.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let error = raven.mapProposalErrors[proposal.id] {
                RookeryLabel(error, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not Now") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        raven.reject(proposal, in: conversationId)
                    }
                }
                .disabled(isSending)
                Button {
                    send(proposal, in: conversationId)
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(Self.verb(of: proposal))
                    }
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .disabled(isSending)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func decidedLine(_ proposal: RavenProposal, decision: RavenDecision?) -> some View {
        HStack(spacing: 6) {
            switch decision?.outcome {
            case .sent(let deliveryId):
                let delivery = raven.mapDeliveries[deliveryId]
                RookeryIconView(delivery?.isFailed == true ? .failed : .check)
                    .foregroundStyle(delivery?.isFailed == true ? Color.red : Color.green)
                Text(Self.done(of: proposal))
                if let delivery {
                    InfoTag(delivery.status.capitalized, tint: delivery.isFailed ? .red : nil)
                    if delivery.isFailed {
                        Text(delivery.reason)
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(1)
                    }
                }
            case .done:
                RookeryIconView(.check)
                    .foregroundStyle(Color.green)
                Text(raven.mapProposalOutcomes[proposal.id] ?? Self.done(of: proposal))
            case .rejected, nil:
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.tertiaryText)
                Text("Left alone: \(Self.lead(of: proposal).lowercased()) \(proposal.agentTitle)")
                    .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
    }

    /// What else the proposal carries, one short fact each: a new session's playbook, skills, role and
    /// teams; a member's duty; a team's goal.
    private static func facts(of proposal: RavenProposal) -> [String] {
        var listFacts: [String] = []
        if proposal.action == .addWorkdir, proposal.isParent {
            listFacts.append("each agent gets <MMDD-name> inside")
        }
        if let playbookId = proposal.playbookId, proposal.action != .loadPlaybook {
            listFacts.append("playbook \(playbookId)")
        }
        listFacts += proposal.listSkillIds.map { "skill \($0)" }
        if !proposal.role.isEmpty {
            listFacts.append("role: \(proposal.role)")
        }
        listFacts += proposal.listTeams.map { $0.duty.isEmpty ? "team \($0.teamId)" : "team \($0.teamId): \($0.duty)" }
        if !proposal.duty.isEmpty {
            listFacts.append("duty: \(proposal.duty)")
        }
        if !proposal.goal.isEmpty {
            listFacts.append("goal: \(proposal.goal)")
        }
        let mapPayload = proposal.mapPayload
        for (key, label) in [("drafts", "drafts"), ("replying_to", "replying to"), ("was", "was"), ("subject", "subject"), ("start", "from"), ("end", "until"), ("location", "at")] {
            if let value = mapPayload[key]?.stringValue, !value.isEmpty {
                listFacts.append("\(label): \(value)")
            }
        }
        for (key, label) in [("to", "to"), ("cc", "cc")] {
            if case .array(let listValues) = mapPayload[key], !listValues.isEmpty {
                listFacts.append("\(label): " + listValues.compactMap(\.stringValue).joined(separator: ", "))
            }
        }
        if proposal.action == .changeEvent, let title = mapPayload["title"]?.stringValue {
            listFacts.append("new title: \(title)")
        }
        return listFacts
    }

    private static func icon(of proposal: RavenProposal) -> RookeryIcon {
        switch proposal.action {
        case .message: .send
        case .interrupt: .stop
        case .approve: proposal.choice == RavenProposal.approveOnce ? .check : .close
        case .spawn: .terminal
        case .join: .plus
        case .leave: .minus
        case .createTeam: .board
        case .draftMail: .send
        case .addEvent, .changeEvent, .openEvent: .clock
        case .removeEvent: .minus
        case .removeDrafts: .draft
        case .loadPlaybook: .playbook
        case .addWorkdir: .folder
        }
    }

    /// What Raven would do, leading up to the name of what it would do it to.
    private static func lead(of proposal: RavenProposal) -> String {
        switch proposal.action {
        case .message: "Raven would send this to"
        case .interrupt: "Raven would stop what this agent is doing:"
        case .approve:
            proposal.choice == RavenProposal.approveOnce
                ? "Raven would allow, once, the call waiting in"
                : "Raven would decline the call waiting in"
        case .spawn: "Raven would start"
        case .join: "Raven would put in team \(proposal.teamTitle ?? proposal.team ?? "")"
        case .leave: "Raven would take out of team \(proposal.teamTitle ?? proposal.team ?? "")"
        case .createTeam: "Raven would make the team"
        case .draftMail: "Raven would draft, from \(proposal.mapPayload["account"]?.stringValue ?? "your account"),"
        case .addEvent: "Raven would add to \(proposal.mapPayload["calendar"]?.stringValue ?? "a calendar")"
        case .changeEvent: "Raven would change"
        case .removeEvent: "Raven would remove"
        case .openEvent: "Raven would open in Calendar"
        case .removeDrafts: "Raven would throw away"
        case .loadPlaybook: "Raven would load playbook \(proposal.playbookId ?? "") into"
        case .addWorkdir: proposal.isParent ? "Raven would add a parent workdir" : "Raven would add a workdir"
        }
    }

    /// The button that carries the proposal out.
    private static func verb(of proposal: RavenProposal) -> String {
        switch proposal.action {
        case .message: "Send"
        case .interrupt: "Interrupt"
        case .approve: proposal.choice == RavenProposal.approveOnce ? "Allow Once" : "Decline"
        case .spawn: "Start"
        case .join: "Add"
        case .leave: "Take Out"
        case .createTeam: "Make Team"
        case .draftMail: "Open Draft"
        case .addEvent: "Add Event"
        case .changeEvent: "Change Event"
        case .removeEvent: "Remove Event"
        case .openEvent: "Open"
        case .removeDrafts: "Throw Away"
        case .loadPlaybook: "Load Playbook"
        case .addWorkdir: "Add Workdir"
        }
    }

    /// What was done, once the user carried the proposal out.
    private static func done(of proposal: RavenProposal) -> String {
        switch proposal.action {
        case .message: "Sent to \(proposal.agentTitle)"
        case .interrupt: "Interrupted \(proposal.agentTitle)"
        case .approve:
            proposal.choice == RavenProposal.approveOnce
                ? "Allowed \(proposal.agentTitle)'s call once"
                : "Declined \(proposal.agentTitle)'s call"
        case .spawn: "Started \(proposal.agentTitle)"
        case .join: "Put \(proposal.agentTitle) in \(proposal.teamTitle ?? proposal.team ?? "")"
        case .leave: "Took \(proposal.agentTitle) out of \(proposal.teamTitle ?? proposal.team ?? "")"
        case .createTeam: "Made the team \(proposal.agentTitle)"
        case .loadPlaybook: "Loading playbook \(proposal.playbookId ?? "") into \(proposal.agentTitle)"
        case .draftMail, .addEvent, .changeEvent, .removeEvent, .openEvent, .removeDrafts, .addWorkdir:
            "\(proposal.agentTitle)"
        }
    }

    private func send(_ proposal: RavenProposal, in conversationId: String) {
        setSendingIds.insert(proposal.id)
        Task {
            await raven.approve(proposal, in: conversationId)
            withAnimation(.easeOut(duration: 0.2)) {
                _ = setSendingIds.remove(proposal.id)
            }
        }
    }

    @ViewBuilder
    private func status(of conversationId: String) -> some View {
        switch raven.mapStatuses[conversationId] {
        case .failed(let reason):
            RookeryLabel(reason, icon: .failed)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
        case .cancelled:
            RookeryLabel("Stopped", icon: .stop)
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
        default:
            EmptyView()
        }
    }
}

/// A request waiting for Raven to finish its answer: the user's bubble, faded and outlined, a clock
/// before it, and a button to take it back on hover.
struct RavenQueuedBubble: View {
    private static let lineLimit = 3
    private static let leadingRoom: CGFloat = 48
    /// The widest a row grows, its bubble with the mark before it and the room left of them.
    private static let maxRowWidth: CGFloat = 640
    private static let markSide: CGFloat = 20

    let text: String
    let onWithdraw: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer(minLength: Self.leadingRoom)
            ZStack {
                if isHovered {
                    Button(action: onWithdraw) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(StageColors.secondaryText)
                            .frame(width: Self.markSide, height: Self.markSide)
                            .background(StageColors.segmentGroove, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(StageColors.segmentGrooveBorder)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Take back")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StageColors.tertiaryText)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.markSide, height: Self.markSide)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(Self.lineLimit)
                .truncationMode(.tail)
                .foregroundStyle(StageColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background {
                    MessageBubbleShape(isTrailing: true, hasTail: false)
                        .fill(StageColors.segmentGroove)
                }
                .overlay {
                    MessageBubbleShape(isTrailing: true, hasTail: false)
                        .stroke(StageColors.tertiaryText.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
        }
        .frame(maxWidth: Self.maxRowWidth, alignment: .trailing)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = isHovering
            }
        }
        .help("Goes to Raven once it finishes the answer under way, in order")
    }
}
