import RookeryCore
import SwiftUI

/// A request to start the maintenance agent from, each one of its skills.
enum MaintenanceStarter: CaseIterable {
    case distillPlaybook
    case tidyMemories
    case describeSkills
    case findStuckAgents

    var title: String {
        switch self {
        case .distillPlaybook: "Distill a playbook"
        case .tidyMemories: "Tidy memories"
        case .describeSkills: "Describe skills"
        case .findStuckAgents: "What's stuck?"
        }
    }

    var symbol: RookeryIcon {
        switch self {
        case .distillPlaybook: .playbook
        case .tidyMemories: .memory
        case .describeSkills: .skill
        case .findStuckAgents: .bubble
        }
    }

    /// The request it fills in, for the user to finish or send.
    var request: String {
        switch self {
        case .distillPlaybook: "Distill a playbook from how @"
        case .tidyMemories: "Tidy the memories: merge duplicates and drop what nothing needs."
        case .describeSkills: "Write the missing descriptions of the registered skills."
        case .findStuckAgents: "Which agents are stuck or waiting on me, and on what?"
        }
    }
}

/// The Rookmaster console's maintenance column: a box to ask the maintenance agent for something in plain
/// words, naming resources with @ and choosing them from suggestions, a few requests to start from, and
/// each request's conversation as the agent works through it.
struct MaintenancePanel: View {

    let fleetModel: FleetModel

    @State private var draft = ""
    @State private var listMentions: [FleetRef] = []
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool

    private var maintenance: MaintenanceAgent {
        fleetModel.maintenance
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
        VStack(spacing: 0) {
            conversation
            composer
        }
    }

    // MARK: - Runs

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if maintenance.listRuns.isEmpty {
                    starters
                }
                ForEach(maintenance.listRuns) { run in
                    runView(run)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .textSelection(.enabled)
        }
        .modifier(RememberedScroll(
            key: "rookmaster.maintenance",
            memory: fleetModel.pageMemory,
            followsEnd: true,
            isReady: true,
            endToken: (maintenance.listRuns.count << 16) + (maintenance.listRuns.last?.reader.listEntries.count ?? 0)
        ))
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code on this Mac tidies, distills or explains anything roost holds. Name a resource with @.")
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .padding(.bottom, 4)
            HStack(spacing: 8) {
                ForEach(MaintenanceStarter.allCases, id: \.self) { starter in
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
    }

    private func runView(_ run: MaintenanceRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 30)
                Text(run.prompt)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ForEach(run.reader.listEntries) { entry in
                entryView(entry)
            }
            status(of: run)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry.role {
        case .user, .command, .compaction:
            EmptyView()
        case .assistant:
            Text((try? AttributedString(
                markdown: entry.text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(entry.text))
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                RookeryIconView(TranscriptView.icon(ofTool: name))
                Text(entry.text.isEmpty ? name : entry.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(StageColors.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    @ViewBuilder
    private func status(of run: MaintenanceRun) -> some View {
        switch run.status {
        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Working…")
            }
            .font(.system(size: 11))
            .foregroundStyle(StageColors.secondaryText)
        case .finished:
            RookeryLabel(run.costUSD.map { "Done · $\(String(format: "%.2f", $0))" } ?? "Done", icon: .check)
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let reason):
            RookeryLabel(reason, icon: .failed)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .cancelled:
            RookeryLabel("Stopped", icon: .stop)
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isReady = fleetModel.connection == .online
        return VStack(alignment: .leading, spacing: 6) {
            if !listSuggestions.isEmpty {
                suggestions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(isReady ? "Ask the maintenance agent…" : "Connect to roost first", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .disabled(!isReady)
                    .onChange(of: draft) {
                        highlightedIndex = 0
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                    }
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                    }
                    .onKeyPress(.tab) {
                        pickHighlighted()
                    }
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if !listSuggestions.isEmpty {
                            return pickHighlighted()
                        }
                        guard !keyPress.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        send()
                        return .handled
                    }
                if maintenance.isRunning {
                    Button {
                        maintenance.cancel()
                    } label: {
                        RookeryIconView(.stop)
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the agent")
                } else {
                    Button(action: send) {
                        RookeryIconView(.arrowUp)
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(isEmpty || !isReady ? Color.gray.opacity(0.5) : Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isEmpty || !isReady)
                    .help("Ask (Return)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(StageColors.separator))
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
                        Text(resource.name)
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
        guard !request.isEmpty, !maintenance.isRunning else {
            return
        }
        let listNamed = listMentions.filter { ref in
            fleetModel.graph.resource(ref).map { request.contains(Mentions.token(for: $0)) } ?? false
        }
        withAnimation(.easeOut(duration: 0.2)) {
            maintenance.ask(request, mentioning: listNamed)
        }
        draft = ""
        listMentions = []
    }
}
