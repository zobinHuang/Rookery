import AppKit
import os
import RookeryCore
import RookeryPlatform
import SwiftUI

/// The content area's page for one agent: its crow and where it runs, its conversation as roost stored
/// it, and a box to prompt it, with what became of each prompt. Reads the transcript's new bytes and the
/// prompts' outcomes every couple of seconds while it shows.
struct AgentDetailView: View {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    private static let pollInterval: Duration = .seconds(2)
    /// How much of a transcript's end is read when the page opens; the rest is a click away.
    private static let openingTailBytes = 3 * 1024 * 1024
    private static let shownDeliveryLimit = 3
    private static let setInterruptibleStates: Set<AgentState> = [.thinking, .working, .compacting]
    /// The harness whose approval prompt its rook knows how to answer.
    private static let approvableHarness = "claude"
    /// How long a prompt's outcome stays above the box once it is known.
    private static let deliveredLinger: TimeInterval = 4
    private static let failedLinger: TimeInterval = 10
    private static let bottomId = "bottom"

    let fleetModel: FleetModel
    let agentId: String
    /// The page it was opened from, which the back button names; nil for no back button.
    var backTitle: String?
    var onBack: () -> Void = {}
    let onClose: () -> Void

    @State private var reader = TranscriptReader()
    @State private var hasTranscript = true
    @State private var listDeliveries: [FleetDelivery] = []
    /// When each prompt was first seen settled; those settled before the page opened count as long ago.
    @State private var mapSettledAt: [String: Date] = [:]
    @State private var setDismissedDeliveries: Set<String> = []
    /// The prompts sent from here that the transcript does not record yet.
    @State private var listOutgoing: [OutgoingPrompt] = []
    @State private var sendToken = 0
    @State private var isActing = false
    @State private var now = Date()
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var roleDraft: String?
    private static let identityLabelWidth: CGFloat = 38
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isRoleFocused: Bool

    /// The session the transcript is read from.
    private var transcriptSessionId: String {
        FleetAgent.transcriptSessionId(of: agentId)
    }

    private var agent: FleetAgent? {
        fleetModel.fleet.mapAgents[agentId]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let agent {
                header(agent)
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                conversation
                composer(agent)
            } else {
                missing
            }
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .task(id: agentId) {
            await follow()
        }
    }

    // MARK: - Header

    private func header(_ agent: FleetAgent) -> some View {
        HStack(alignment: .center, spacing: 16) {
            CrowView(state: agent.state, size: .large)
            VStack(alignment: .leading, spacing: 6) {
                if let backTitle {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            RookeryIconView(.chevronLeft)
                            Text("Back to \(backTitle)")
                        }
                    }
                    .buttonStyle(StageButtonStyle())
                    .controlSize(.small)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to \(backTitle) (⌘[)")
                    .padding(.bottom, 2)
                }
                HStack(spacing: 10) {
                    Text(reader.title ?? agent.displayName)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statePill(agent.state)
                }
                if reader.title != nil || !agent.title.isEmpty {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StageColors.secondaryText)
                }
                metadata(agent)
                if agent.parentId == nil {
                    identity(agent)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            controls(agent)
                .fixedSize()
            Button(action: onClose) {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(StageColors.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// Who the agent is to its teammates, which the user may change, what it works on now, and its teams,
    /// each on a line of its own and wrapping when long.
    private func identity(_ agent: FleetAgent) -> some View {
        let listTeams = fleetModel.teams.listTeams.filter { $0.listAgentIds.contains(agent.id) }
        return VStack(alignment: .leading, spacing: 5) {
            identityLine(label: "Role") {
                if let roleDraft {
                    TextField(
                        "Who it is to its teammates; empty lets Rookery write it",
                        text: Binding(get: { roleDraft }, set: { self.roleDraft = $0 }),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.6))
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .focused($isRoleFocused)
                    .onSubmit { saveRole(agent) }
                    .onExitCommand { self.roleDraft = nil }
                    .onChange(of: isRoleFocused) { _, isFocused in
                        if !isFocused, self.roleDraft != nil {
                            saveRole(agent)
                        }
                    }
                } else {
                    Button {
                        roleDraft = agent.role
                        isRoleFocused = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(agent.role.isEmpty ? "Rookery writes its role after its first prompt" : agent.role)
                                .foregroundStyle(agent.role.isEmpty ? AnyShapeStyle(StageColors.tertiaryText) : AnyShapeStyle(StageColors.primaryText))
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            if agent.roleSource == AgentIdentity.sourceAuto && !agent.role.isEmpty {
                                Text("auto")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(StageColors.tertiaryText)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(StageColors.separator)
                                    }
                                    .help("Rookery writes this role from the agent's work and keeps it up to date")
                            }
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Who it is to its teammates; click to change it")
                }
            }
            if !agent.focus.isEmpty {
                identityLine(label: "Now") {
                    Text(agent.focus)
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !listTeams.isEmpty {
                identityLine(label: "Teams") {
                    FlowRow(spacing: 5) {
                        ForEach(listTeams) { team in
                            InfoTag(team.title, tint: .teal)
                        }
                    }
                }
            }
        }
    }

    /// One line of the agent's identity: a fixed-width label and what it says, wrapping beside the label.
    private func identityLine(label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: Self.identityLabelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveRole(_ agent: FleetAgent) {
        let role = (roleDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        roleDraft = nil
        guard role != agent.role else {
            return
        }
        let source = role.isEmpty ? AgentIdentity.sourceAuto : AgentIdentity.sourceUser
        Task {
            do {
                try await fleetModel.update(
                    FleetRef(kind: AgentFleet.agentKind, id: agent.id),
                    body: ["attributes": .object(role.isEmpty
                        ? ["role": .string(role), AgentIdentity.roleSourceKey: .string(source), AgentIdentity.checkedOffsetKey: .null]
                        : ["role": .string(role), AgentIdentity.roleSourceKey: .string(source)]
                    )]
                )
            } catch {
                sendError = FleetModel.describe(error)
            }
        }
    }

    /// What the user can do to the agent from here: stop it while it works, or answer the approval it waits
    /// on, which its rook does in its pane.
    @ViewBuilder
    private func controls(_ agent: FleetAgent) -> some View {
        let isReachable = agent.state != .ended && fleetModel.fleet.isOnline(agent)
        HStack(spacing: 8) {
            if isReachable && Self.setInterruptibleStates.contains(agent.state) {
                Button {
                    act { try await $0.interrupt(agent.id) }
                } label: {
                    Text("Interrupt")
                }
                .help("Stop what the agent is doing, as Escape in its pane does")
            }
            if isReachable && agent.state == .needsApproval && agent.harness == Self.approvableHarness {
                Button {
                    act { try await $0.approve(agent.id, choice: RavenProposal.approveDeny) }
                } label: {
                    Text("Decline")
                }
                .help("Decline the call it waits to run")
                Button {
                    act { try await $0.approve(agent.id, choice: RavenProposal.approveOnce) }
                } label: {
                    Text("Allow Once")
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .help("Allow the call it waits to run, this once")
            }
        }
        .controlSize(.regular)
        .disabled(isActing)
        .animation(.easeOut(duration: 0.2), value: agent.state)
    }

    /// Carry out an action on the agent through roost, showing its delivery with the prompts'.
    private func act(_ action: @escaping (RoostClient) async throws -> FleetDelivery) {
        isActing = true
        sendError = nil
        Task {
            do {
                let delivery = try await action(fleetModel.requireClient())
                listDeliveries.insert(delivery, at: 0)
                noteOutcomes(isOpening: false)
            } catch {
                sendError = FleetModel.describe(error)
            }
            isActing = false
        }
    }

    /// A delivery in a few words: a prompt's text, or what was done.
    private static func summary(of delivery: FleetDelivery) -> String {
        switch delivery.kind {
        case "interrupt": "Interrupt"
        case "approve": "Answer to its approval"
        case "spawn": "New session"
        default: delivery.text
        }
    }

    private func statePill(_ state: AgentState) -> some View {
        Text(state.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(stateTint(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateTint(state).opacity(0.14), in: Capsule())
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: state)
    }

    private func stateTint(_ state: AgentState) -> Color {
        if state.needsAttention {
            return .orange
        }
        switch state {
        case .thinking, .working, .compacting: return .accentColor
        case .done: return .green
        default: return .secondary
        }
    }

    private func metadata(_ agent: FleetAgent) -> some View {
        let isOnline = fleetModel.fleet.isOnline(agent)
        return HStack(spacing: 14) {
            if !agent.rookName.isEmpty {
                Label {
                    Text(agent.rookName)
                } icon: {
                    Circle()
                        .fill(isOnline ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                }
                .help(isOnline ? "\(agent.rookName) is online" : "\(agent.rookName) is offline")
                .fixedSize()
            }
            if !agent.harness.isEmpty {
                RookeryLabel(agent.harness, icon: .chip)
                    .fixedSize()
                if !agent.model.isEmpty {
                    InfoTag(agent.model)
                        .fixedSize()
                }
            }
            if !agent.cwd.isEmpty {
                RookeryLabel(agent.cwd.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~"), icon: .folder)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !agent.gitBranch.isEmpty {
                RookeryLabel(agent.gitBranch, icon: .branch)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .font(.system(size: 12))
        .foregroundStyle(StageColors.secondaryText)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Conversation

    private var conversation: some View {
        TranscriptView(
            reader: reader,
            agentId: agentId,
            memory: fleetModel.pageMemory,
            hasTranscript: hasTranscript,
            listOutgoing: listOutgoing,
            mapDeliveries: Dictionary(listDeliveries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            sendToken: sendToken
        ) {
            fleetModel.transcripts.forget(agentId)
            reader = TranscriptReader()
        }
        .id(agentId)
    }

    // MARK: - Composer

    private func composer(_ agent: FleetAgent) -> some View {
        let isReachable = agent.state != .ended && fleetModel.fleet.isOnline(agent)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(listShownDeliveries) { delivery in
                deliveryLine(delivery)
            }
            if let sendError {
                HStack(spacing: 6) {
                    RookeryLabel(sendError, icon: .warning)
                        .foregroundStyle(.orange)
                    dismissButton {
                        self.sendError = nil
                    }
                }
                .font(.system(size: 11))
                .transition(.opacity)
            }
            AgentComposer(
                text: $draft,
                placeholder: isReachable ? "Message \(agent.displayName)" : composerHint(agent),
                isEnabled: isReachable,
                isBusy: isSending,
                onSend: { send(to: agent) },
                isFocused: $isComposerFocused
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.25), value: listShownDeliveries)
        .animation(.easeOut(duration: 0.2), value: sendError)
        .onChange(of: draft) {
            sendError = nil
        }
    }

    /// The prompts on their way, and those whose outcome came in a moment ago and was not dismissed.
    private var listShownDeliveries: [FleetDelivery] {
        let setOutgoingIds = Set(listOutgoing.map(\.id))
        let listShown = listDeliveries.filter { delivery in
            guard
                !setDismissedDeliveries.contains(delivery.id)
                && !setOutgoingIds.contains(delivery.id)
            else {
                return false
            }
            guard delivery.isSettled else {
                return true
            }
            let linger = delivery.isFailed ? Self.failedLinger : Self.deliveredLinger
            return now.timeIntervalSince(mapSettledAt[delivery.id] ?? .distantPast) < linger
        }
        return Array(listShown.prefix(Self.shownDeliveryLimit))
    }

    /// Note when each prompt's outcome first showed up.
    private func noteOutcomes(isOpening: Bool) {
        now = Date()
        for delivery in listDeliveries where delivery.isSettled && mapSettledAt[delivery.id] == nil {
            mapSettledAt[delivery.id] = isOpening ? .distantPast : now
        }
    }

    private func dismissButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RookeryIconView(.close)
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }

    private func composerHint(_ agent: FleetAgent) -> String {
        agent.state == .ended ? "This session has ended" : "\(agent.rookName) is offline"
    }

    private func deliveryLine(_ delivery: FleetDelivery) -> some View {
        let symbol: RookeryIcon = switch delivery.status {
        case "delivered": .check
        case "failed", "expired": .failed
        case "waiting": .hourglass
        default: .send
        }
        let tint: Color = switch delivery.status {
        case "delivered": .green
        case "failed", "expired": .red
        case "waiting": .orange
        default: .secondary
        }
        return HStack(spacing: 6) {
            RookeryIconView(symbol)
                .foregroundStyle(tint)
            Text(Self.summary(of: delivery))
                .lineLimit(1)
                .truncationMode(.tail)
            InfoTag(delivery.status.capitalized, tint: tint)
            Text(delivery.reason)
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
            if delivery.isSettled {
                dismissButton {
                    setDismissedDeliveries.insert(delivery.id)
                }
            }
        }
        .font(.system(size: 11))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func send(to agent: FleetAgent) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }
        isSending = true
        sendError = nil
        isComposerFocused = true
        Task {
            do {
                let delivery = try await fleetModel.send(text, to: agent.id)
                draft = ""
                listDeliveries.insert(delivery, at: 0)
                listOutgoing.append(OutgoingPrompt(
                    id: delivery.id,
                    text: text,
                    sentAt: .now,
                    entryCountAtSend: reader.listEntries.count
                ))
                sendToken += 1
                noteOutcomes(isOpening: false)
            } catch {
                sendError = FleetModel.describe(error)
            }
            isSending = false
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            RookeryIconView(.agent, scale: 3)
                .foregroundStyle(StageColors.tertiaryText)
            Text("This agent is gone from roost")
                .font(.system(size: 14, weight: .semibold))
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Following

    /// Read the transcript's new bytes and the prompts' outcomes until the page goes away.
    private func follow() async {
        reader = TranscriptReader()
        hasTranscript = true
        listDeliveries = []
        listOutgoing = []
        mapSettledAt = [:]
        var isOpening = true
        if let cached = await fleetModel.transcripts.reader(for: agentId) {
            reader = cached
        } else if let client = fleetModel.client() {
            await startAtTail(from: client)
        }
        while !Task.isCancelled {
            if let client = fleetModel.client() {
                await readTranscript(from: client)
                listOutgoing.removeAll { $0.isRecorded(in: reader.listEntries) }
                do {
                    listDeliveries = try await client.deliveries(to: agentId)
                    noteOutcomes(isOpening: isOpening)
                    isOpening = false
                } catch {
                    Self.logger.info("cannot read deliveries: \(FleetModel.describe(error), privacy: .public)")
                }
            }
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return
            }
        }
    }

    /// Begin reading at the transcript's last stretch, so the latest of a long conversation shows at once.
    private func startAtTail(from client: RoostClient) async {
        do {
            guard let probe = try await client.transcript(of: transcriptSessionId, from: 0, limit: 1) else {
                return
            }
            if probe.total > Self.openingTailBytes {
                reader = TranscriptReader(startOffset: probe.total - Self.openingTailBytes)
            }
        } catch {
            Self.logger.info("cannot read the transcript: \(FleetModel.describe(error), privacy: .public)")
        }
    }

    /// Read what the transcript grew by since the last read, all of it, a chunk at a time; start over when
    /// the agent rewrote it.
    private func readTranscript(from client: RoostClient) async {
        do {
            while !Task.isCancelled {
                guard let chunk = try await client.transcript(of: transcriptSessionId, from: reader.nextOffset) else {
                    hasTranscript = false
                    return
                }
                hasTranscript = true
                if chunk.total < reader.nextOffset {
                    fleetModel.transcripts.forget(agentId)
                    reader = TranscriptReader()
                    continue
                }
                guard !chunk.data.isEmpty else {
                    return
                }
                reader.append(chunk.data)
                fleetModel.transcripts.append(chunk.data, after: reader, for: agentId)
                if reader.nextOffset >= chunk.total {
                    return
                }
            }
        } catch {
            Self.logger.info("cannot read the transcript: \(FleetModel.describe(error), privacy: .public)")
        }
    }
}
