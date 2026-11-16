import RookeryCore
import SwiftUI

/// The Rookmaster console's Raven column: the conversations with Raven, the one last active first, beside
/// the one open, read as an agent's conversation is, and a box to ask in plain words, naming agents and
/// resources with @ and choosing them from suggestions.
struct RavenPanel: View {
    private static let listWidth: CGFloat = 220
    private static let deliveryPollInterval: Duration = .seconds(3)
    /// The most decided proposals shown above the box, the latest.
    private static let shownDecidedLimit = 3

    let fleetModel: FleetModel

    @State private var draft = ""
    @State private var listMentions: [FleetRef] = []
    @State private var highlightedIndex = 0
    @State private var renamingId: String?
    @State private var renameDraft = ""
    @State private var setSendingIds: Set<String> = []
    @FocusState private var isFocused: Bool

    private var raven: RavenAgent {
        fleetModel.raven
    }

    private var openId: String? {
        raven.openConversationId
    }

    private var listSuggestions: [FleetResource] {
        guard let query = Mentions.activeQuery(in: draft) else {
            return []
        }
        let listResources = fleetModel.graph.listKinds
            .filter { !RookmasterView.setHiddenKinds.contains($0.name) }
            .flatMap { fleetModel.graph.listResources(of: $0.name) }
        return Mentions.suggestions(for: query, among: listResources)
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
            VStack(spacing: 0) {
                conversation
                composer
            }
        }
        .onAppear {
            raven.loadIfNeeded()
        }
    }

    // MARK: - Conversations

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    raven.openConversationId = nil
                }
                isFocused = true
            } label: {
                HStack(spacing: 6) {
                    RookeryIconView(.plus)
                    Text("New Conversation")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(openId == nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    openId == nil ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(StageColor.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(raven.conversations.listConversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: raven.conversations.listConversations.map(\.id))
            }
            .scrollIndicators(.never)
        }
        .padding(8)
    }

    private func conversationRow(_ conversation: RavenConversation) -> some View {
        let isOpen = openId == conversation.id
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                raven.openConversationId = conversation.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if renamingId == conversation.id {
                    TextField("Title", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .onSubmit {
                            raven.rename(conversation.id, to: renameDraft)
                            renamingId = nil
                        }
                } else {
                    FittingText(conversation.title, size: 12, weight: .semibold)
                        .foregroundStyle(isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.primaryText))
                }
                HStack(spacing: 5) {
                    if raven.isRunning(conversation.id) {
                        AwaitingDots()
                    } else if case .failed = raven.mapStatuses[conversation.id] {
                        RookeryIconView(.failed)
                            .foregroundStyle(.red)
                    }
                    Text(conversation.lastAt, format: .relative(presentation: .named))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(StageColors.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isOpen ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(StageColor.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                renameDraft = conversation.title
                renamingId = conversation.id
            }
            Button("Delete", role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) {
                    raven.remove(conversation.id)
                }
            }
        }
    }

    // MARK: - The open conversation

    @ViewBuilder
    private var conversation: some View {
        if let openId {
            VStack(spacing: 0) {
                TranscriptView(
                    reader: raven.reader(of: openId),
                    agentId: openId,
                    memory: fleetModel.pageMemory,
                    hasTranscript: true,
                    isWorking: raven.isRunning(openId)
                ) {}
                .id(openId)
                status(of: openId)
                proposals(in: openId)
            }
            .task(id: openId) {
                while !Task.isCancelled {
                    await raven.refreshDeliveries(in: openId)
                    do {
                        try await Task.sleep(for: Self.deliveryPollInterval)
                    } catch {
                        return
                    }
                }
            }
        } else {
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity)
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
                .buttonStyle(.borderedProminent)
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
            default:
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

    private static func icon(of proposal: RavenProposal) -> RookeryIcon {
        switch proposal.action {
        case .message: .send
        case .interrupt: .stop
        case .approve: proposal.choice == RavenProposal.approveOnce ? .check : .close
        case .spawn: .terminal
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
        }
    }

    /// The button that carries the proposal out.
    private static func verb(of proposal: RavenProposal) -> String {
        switch proposal.action {
        case .message: "Send"
        case .interrupt: "Interrupt"
        case .approve: proposal.choice == RavenProposal.approveOnce ? "Allow Once" : "Decline"
        case .spawn: "Start"
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

    // MARK: - Composer

    private var composer: some View {
        let isReady = fleetModel.connection == .online
        return VStack(alignment: .leading, spacing: 6) {
            if !listSuggestions.isEmpty {
                suggestions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            AgentComposer(
                text: $draft,
                placeholder: isReady ? "Ask Raven" : "Connect to roost first",
                isEnabled: isReady,
                isBusy: raven.isRunning(openId),
                fontSize: 12,
                onStop: {
                    if let openId {
                        raven.cancel(openId)
                    }
                },
                onSend: send,
                onKey: takeSuggestionKey,
                isFocused: $isFocused
            )
            .onChange(of: draft) {
                highlightedIndex = 0
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: listSuggestions.map(\.id))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(listSuggestions.enumerated()), id: \.element.id) { index, resource in
                Button {
                    pick(resource)
                } label: {
                    HStack(spacing: 8) {
                        RookeryIconView(RookeryIcon.kind(resource.kind))
                            .foregroundStyle(RookmasterStyle.tint(of: resource.kind))
                            .frame(width: 16)
                        Text(resource.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(resource.kind)
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        index == highlightedIndex ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(StageColor.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(StageColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// The keys that work the suggestions while they show.
    private func takeSuggestionKey(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .upArrow:
            return moveHighlight(by: -1)
        case .downArrow:
            return moveHighlight(by: 1)
        case .tab:
            return pickHighlighted()
        case .return where !listSuggestions.isEmpty:
            return pickHighlighted()
        default:
            return .ignored
        }
    }

    private func moveHighlight(by step: Int) -> KeyPress.Result {
        guard !listSuggestions.isEmpty else {
            return .ignored
        }
        highlightedIndex = (highlightedIndex + step + listSuggestions.count) % listSuggestions.count
        return .handled
    }

    private func pickHighlighted() -> KeyPress.Result {
        guard listSuggestions.indices.contains(highlightedIndex) else {
            return .ignored
        }
        pick(listSuggestions[highlightedIndex])
        return .handled
    }

    private func pick(_ resource: FleetResource) {
        draft = Mentions.complete(draft, with: resource)
        listMentions.append(FleetRef(kind: resource.kind, id: resource.id))
        isFocused = true
    }

    private func send() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !raven.isRunning(openId) else {
            return
        }
        let listNamed = listMentions.filter { ref in
            fleetModel.graph.resource(ref).map { request.contains(Mentions.token(for: $0)) } ?? false
        }
        withAnimation(.easeOut(duration: 0.2)) {
            _ = raven.ask(request, mentioning: listNamed, in: openId)
        }
        draft = ""
        listMentions = []
    }
}
