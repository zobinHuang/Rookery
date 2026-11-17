import RookeryCore
import SwiftUI

/// One conversation with Raven as it reads anywhere it is shown, in the Rookmaster console and in the
/// launcher: the conversation in message bubbles, how its latest request ended if it did not answer, and
/// what Raven proposed, those waiting on the user with buttons to carry them out or not. While shown it
/// follows what became of the proposals already sent.
struct RavenThreadView: View {
    private static let deliveryPollInterval: Duration = .seconds(3)
    /// The most decided proposals shown above the box, the latest.
    private static let shownDecidedLimit = 3

    let fleetModel: FleetModel
    let conversationId: String
    /// Changes with every request sent, to bring the conversation's end into view.
    var sendToken = 0

    @State private var setSendingIds: Set<String> = []

    private var raven: RavenAgent {
        fleetModel.raven
    }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(
                reader: raven.reader(of: conversationId),
                agentId: conversationId,
                memory: fleetModel.pageMemory,
                hasTranscript: true,
                sendToken: sendToken,
                isWorking: raven.isRunning(conversationId)
            ) {}
            status(of: conversationId)
            proposals(in: conversationId)
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

    // MARK: - Proposals

    /// What Raven proposed to do to agents in a conversation: those waiting on the user in full, with
    /// buttons to carry them out or not, and the latest decided ones in a line each.
    @ViewBuilder
    private func proposals(in conversationId: String) -> some View {
        let listProposals = raven.mapProposals[conversationId] ?? []
        let mapDecisions = raven.conversations.conversation(conversationId)?.mapDecisions ?? [:]
        let listPending = listProposals.filter { mapDecisions[$0.id] == nil }
        let listDecided = listProposals.filter { mapDecisions[$0.id] != nil }.suffix(Self.shownDecidedLimit)
        if !listPending.isEmpty || !listDecided.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(listDecided)) { proposal in
                    decidedLine(proposal, decision: mapDecisions[proposal.id])
                }
                ForEach(listPending) { proposal in
                    proposalCard(proposal, in: conversationId)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: listPending.map(\.id))
        }
    }

    private func proposalCard(_ proposal: RavenProposal, in conversationId: String) -> some View {
        let isSending = setSendingIds.contains(proposal.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RookeryIconView(Self.icon(of: proposal))
                    .foregroundStyle(proposal.action == .interrupt ? Color.orange : Color.accentColor)
                Text(Self.lead(of: proposal))
                    .foregroundStyle(StageColors.secondaryText)
                FittingText(proposal.agentTitle, size: 12, weight: .semibold)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            if proposal.action == .spawn, let cwd = proposal.cwd {
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
        if let playbookId = proposal.playbookId {
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
        for (key, label) in [("replying_to", "replying to"), ("was", "was"), ("subject", "subject"), ("start", "from"), ("end", "until"), ("location", "at")] {
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
        case .draftMail, .addEvent, .changeEvent, .removeEvent, .openEvent:
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
