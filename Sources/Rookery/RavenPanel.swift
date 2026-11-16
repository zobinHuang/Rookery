import RookeryCore
import SwiftUI

/// A request to start Raven from, each one of its skills.
enum RavenStarter: CaseIterable {
    case fleetStatus
    case inspectAgent
    case registerSkill
    case writePlaybook
    case distillPlaybook
    case tidyMemories
    case describeSkills

    var title: String {
        switch self {
        case .fleetStatus: "How are my agents?"
        case .inspectAgent: "What is an agent doing?"
        case .registerSkill: "Register a skill"
        case .writePlaybook: "Write a playbook"
        case .distillPlaybook: "Distill a playbook"
        case .tidyMemories: "Tidy memories"
        case .describeSkills: "Describe skills"
        }
    }

    var symbol: RookeryIcon {
        switch self {
        case .fleetStatus: .agent
        case .inspectAgent: .bubble
        case .registerSkill: .skill
        case .writePlaybook: .playbook
        case .distillPlaybook: .playbook
        case .tidyMemories: .memory
        case .describeSkills: .skill
        }
    }

    /// The request it fills in, for the user to finish or send.
    var request: String {
        switch self {
        case .fleetStatus: "How are my agents? Who needs me, and for what?"
        case .inspectAgent: "What is @agent/"
        case .registerSkill: "Register the skill at "
        case .writePlaybook: "Write a playbook for "
        case .distillPlaybook: "Distill a playbook from how @"
        case .tidyMemories: "Tidy the memories: merge duplicates and drop what nothing needs."
        case .describeSkills: "Write the missing descriptions of the registered skills."
        }
    }
}

/// The Rookmaster console's Raven column: the conversations with Raven, the one last active first, beside
/// the one open, read as an agent's conversation is, and a box to ask in plain words, naming agents and
/// resources with @ and choosing them from suggestions; a new conversation offers a few requests to start
/// from.
struct RavenPanel: View {
    private static let listWidth: CGFloat = 220

    let fleetModel: FleetModel

    @State private var draft = ""
    @State private var listMentions: [FleetRef] = []
    @State private var highlightedIndex = 0
    @State private var renamingId: String?
    @State private var renameDraft = ""
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
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ask Raven about your agents and everything roost holds.")
                        .font(.system(size: 13, weight: .semibold))
                    starters
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var starters: some View {
        FlowRow(spacing: 8) {
            ForEach(RavenStarter.allCases, id: \.self) { starter in
                Button {
                    draft = starter.request
                    isFocused = true
                } label: {
                    RookeryLabel(starter.title, icon: starter.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                placeholder: isReady ? "Ask Raven; name an agent or a resource with @" : "Connect to roost first",
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
