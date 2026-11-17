import RookeryCore
import SwiftUI

/// The Rookmaster console's Raven column: the conversations with Raven, the one last active first, beside
/// the one open, read as an agent's conversation is, and a box to ask in plain words, naming agents and
/// resources with @ and choosing them from suggestions.
struct RavenPanel: View {
    let fleetModel: FleetModel

    @State private var listMentions: [FleetRef] = []
    @State private var highlightedIndex = 0
    @State private var renamingId: String?
    @State private var renameDraft = ""
    /// Changes with every request sent, to bring the conversation's end into view.
    @State private var sendToken = 0
    @FocusState private var isFocused: Bool

    private var raven: RavenAgent {
        fleetModel.raven
    }

    private var openId: String? {
        raven.openConversationId
    }

    private var draft: String {
        get { fleetModel.pageMemory.ravenDraft }
        nonmutating set { fleetModel.pageMemory.ravenDraft = newValue }
    }

    private var listSuggestions: [MentionTarget] {
        fleetModel.mentionTargets(in: draft)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !fleetModel.pageColumns.isHidden(.ravenConversations) {
                conversationList
                    .frame(width: fleetModel.pageColumns.width(of: .ravenConversations))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ColumnDivider(columns: fleetModel.pageColumns, column: .ravenConversations)
            }
            VStack(spacing: 0) {
                conversation
                    .overlay(alignment: .bottomLeading) {
                        if !listSuggestions.isEmpty {
                            suggestions
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: listSuggestions.map(\.id))
                composer
            }
            .overlay(alignment: .topLeading) {
                if fleetModel.pageColumns.isHidden(.ravenConversations) {
                    ColumnToggle(columns: fleetModel.pageColumns, column: .ravenConversations, title: "Conversations")
                        .background(StageColors.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(8)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            raven.loadIfNeeded()
        }
    }

    // MARK: - Conversations

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RavenView(isWorking: raven.isAnyRunning)
                Text("Raven")
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                ColumnToggle(columns: fleetModel.pageColumns, column: .ravenConversations, title: "Conversations")
            }
            .padding(.horizontal, 4)
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
                .foregroundStyle(openId == nil ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    if openId == nil {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StageColors.selectedRow)
                            .strokeBorder(StageColors.contrastActiveBorder)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                }
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
                        .foregroundStyle(StageColors.primaryText)
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
            .background {
                if isOpen {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.selectedRow)
                        .strokeBorder(StageColors.contrastActiveBorder)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                }
            }
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
            RavenThreadView(fleetModel: fleetModel, conversationId: openId, sendToken: sendToken)
                .id(openId)
        } else {
            RavenView(isWorking: false, crowSize: .large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        let isReady = fleetModel.connection == .online
        return VStack(alignment: .leading, spacing: 6) {
            engineRow
            let listNamedPeople = fleetModel.people.book.people(mentionedIn: draft)
            if !listNamedPeople.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(listNamedPeople) { person in
                        HStack(spacing: 5) {
                            PersonMark(person: person, size: 16)
                            Text(person.name)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.leading, 2)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                        .background(StageColors.segmentGroove, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(StageColors.segmentGrooveBorder)
                        }
                        .help(person.listAddresses.joined(separator: ", "))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            AgentComposer(
                text: Bindable(fleetModel.pageMemory).ravenDraft,
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
    }

    /// Which code agent the conversation runs on: chosen for a new one, shown for one under way.
    @ViewBuilder
    private var engineRow: some View {
        if let openId, let conversation = raven.conversations.conversation(openId) {
            Text("On \(conversation.engine == RavenConversation.engineCodex ? "Codex" : "Claude Code")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
                .padding(.leading, 4)
        } else {
            HStack(spacing: 6) {
                Text("Run on")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StageColors.tertiaryText)
                StageSegmentedControl(
                    selection: Binding(get: { fleetModel.ravenEngine }, set: { fleetModel.ravenEngine = $0 }),
                    listOptions: [RavenConversation.engineClaude, RavenConversation.engineCodex],
                    title: { $0 == RavenConversation.engineCodex ? "Codex" : "Claude Code" },
                    isSmall: true
                )
            }
            .padding(.leading, 4)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(listSuggestions.enumerated()), id: \.element.id) { index, target in
                Button {
                    pick(target)
                } label: {
                    HStack(spacing: 8) {
                        switch target {
                        case .person(let person):
                            PersonMark(person: person, size: 18)
                                .frame(width: 16)
                            Text(person.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(person.listAddresses.first ?? "person")
                                .opacity(0.6)
                                .lineLimit(1)
                        case .resource(let resource):
                            RookeryIconView(RookeryIcon.kind(resource.kind))
                                .frame(width: 16)
                            Text(resource.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(resource.kind)
                                .opacity(0.6)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(index == highlightedIndex ? AnyShapeStyle(StageColors.selectedSegmentText) : AnyShapeStyle(StageColors.primaryText))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if index == highlightedIndex {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StageColors.selectedSegment)
                                .strokeBorder(StageColors.contrastActiveBorder)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StageColors.window)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StageColors.card)
                }
        }
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

    private func pick(_ target: MentionTarget) {
        switch target {
        case .person(let person):
            draft = Mentions.complete(draft, with: person)
        case .resource(let resource):
            draft = Mentions.complete(draft, with: resource)
            listMentions.append(FleetRef(kind: resource.kind, id: resource.id))
        }
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
        sendToken += 1
        draft = ""
        listMentions = []
        isFocused = true
    }
}
