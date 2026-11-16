import RookeryCore
import SwiftUI

/// An agent's conversation as a person reads it: each prompt with when it was sent, the agent's answers
/// with their headings and code set apart, every run of tool calls folded into one line that opens to show
/// each call, the slash commands run, and where the harness compacted the conversation, its summary folded
/// away.
struct TranscriptView: View {
    private static let foldAnimation = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// The most tools named in a folded run's line.
    private static let namedToolLimit = 3

    let reader: TranscriptReader
    /// Whose conversation it is, which keys where the user left it.
    let agentId: String
    let memory: PageMemory
    /// Whether roost holds a transcript of the session at all.
    let hasTranscript: Bool
    /// Prompts sent from Rookery that the transcript does not record yet, oldest first.
    var listOutgoing: [OutgoingPrompt] = []
    /// What became of each outgoing prompt's delivery, by its id.
    var mapDeliveries: [String: FleetDelivery] = [:]
    /// Changes when the user sends a prompt, to bring the end into view.
    var sendToken = 0
    /// Whether the agent is working on the latest prompt, shown at the end.
    var isWorking = false
    /// Read the conversation from its start, when the page began at its last stretch.
    let onLoadEarlier: () -> Void

    private var isSubagent: Bool {
        FleetAgent.transcriptSessionId(of: agentId) != agentId
    }

    private var setOpenBlockIds: Set<Int> {
        memory.mapOpenTranscriptBlocks[agentId] ?? []
    }

    var body: some View {
        let listBlocks = TranscriptBlock.blocks(of: reader.listEntries)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if reader.startOffset > 0 {
                    earlierButton
                }
                if listBlocks.isEmpty {
                    empty
                }
                ForEach(listBlocks) { block in
                    blockView(block)
                }
                if isWorking {
                    HStack(spacing: 6) {
                        AwaitingDots()
                        Text("Working")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
                    .transition(.opacity)
                }
                ForEach(listOutgoing) { outgoing in
                    outgoingPrompt(outgoing)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: listOutgoing)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .modifier(RememberedScroll(
            key: "agent:\(agentId)",
            memory: memory,
            followsEnd: true,
            isReady: !reader.listEntries.isEmpty || !hasTranscript,
            endToken: (reader.listEntries.last?.id ?? 0) &* 31 &+ listOutgoing.count &+ (isWorking ? 7 : 0),
            jumpToken: sendToken
        ))
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case .entry(let entry):
            entryView(entry)
        case .tools(let listEntries):
            toolRun(listEntries, blockId: block.id)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry.role {
        case .user:
            prompt(entry)
        case .assistant:
            MarkdownText(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .command(let command):
            HStack(spacing: 6) {
                RookeryIconView(.terminal)
                Text(command)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if let timestamp = entry.timestamp {
                    Text(Self.time(of: timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(StageColors.tertiaryText)
                }
            }
            .foregroundStyle(StageColors.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(StageColors.tile, in: Capsule())
            .frame(maxWidth: .infinity)
        case .compaction:
            compaction(entry)
        case .tool:
            toolRun([entry], blockId: entry.id)
        }
    }

    private func prompt(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let timestamp = entry.timestamp {
                Text(Self.time(of: timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(StageColors.tertiaryText)
            }
            Text(entry.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .padding(.top, 6)
    }

    /// A prompt on its way: as it will read once recorded, with what became of it beneath, and the agent's
    /// answer awaited once it arrived.
    private func outgoingPrompt(_ outgoing: OutgoingPrompt) -> some View {
        let delivery = mapDeliveries[outgoing.id]
        let isFailed = delivery?.isFailed == true
        return VStack(alignment: .trailing, spacing: 5) {
            Text(Self.time(of: outgoing.sentAt))
                .font(.system(size: 10))
                .foregroundStyle(StageColors.tertiaryText)
            Text(outgoing.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isFailed ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(Color.accentColor.opacity(0.16)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .opacity(delivery?.status == "delivered" ? 1 : 0.75)
            outgoingStatus(delivery)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func outgoingStatus(_ delivery: FleetDelivery?) -> some View {
        HStack(spacing: 5) {
            switch delivery?.status {
            case "delivered":
                AwaitingDots()
                Text("Waiting for the reply")
            case "waiting":
                RookeryIconView(.hourglass)
                Text("Held until the agent stops")
            case .some(let status) where delivery?.isFailed == true:
                RookeryIconView(.failed)
                    .foregroundStyle(.red)
                Text(delivery?.reason.isEmpty == false ? "Not delivered: \(delivery?.reason ?? "")" : "Not delivered (\(status))")
                    .foregroundStyle(.red)
            default:
                ProgressView()
                    .controlSize(.mini)
                Text("Sending")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(StageColors.tertiaryText)
        .animation(.easeOut(duration: 0.2), value: delivery?.status)
    }

    /// Where the harness compacted the conversation: a rule across the page, its summary a click away.
    private func compaction(_ entry: TranscriptEntry) -> some View {
        let isOpen = setOpenBlockIds.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(entry.id)
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(height: 1)
                    HStack(spacing: 5) {
                        RookeryIconView(isOpen ? .chevronDown : .chevronRight)
                        Text("Context compacted")
                            .font(.system(size: 11, weight: .semibold))
                        if let timestamp = entry.timestamp {
                            Text(Self.time(of: timestamp))
                                .font(.system(size: 10))
                                .foregroundStyle(StageColors.tertiaryText)
                        }
                    }
                    .foregroundStyle(StageColors.secondaryText)
                    .fixedSize()
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Fold the summary away" : "Show the summary the agent continued from")
            if isOpen {
                MarkdownText(text: entry.text, fontSize: 12)
                    .foregroundStyle(StageColors.secondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    /// A run of tool calls: one line naming how many and which, with the last call, opening to every call.
    private func toolRun(_ listEntries: [TranscriptEntry], blockId: Int) -> some View {
        let isOpen = setOpenBlockIds.contains(blockId)
        let listNames = listEntries.compactMap(Self.toolName(of:))
        var mapCounts: [String: Int] = [:]
        for name in listNames {
            mapCounts[name, default: 0] += 1
        }
        let listOrdered = mapCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(blockId)
            } label: {
                HStack(spacing: 8) {
                    RookeryIconView(isOpen ? .chevronDown : .chevronRight)
                        .foregroundStyle(StageColors.tertiaryText)
                    HStack(spacing: 3) {
                        ForEach(listOrdered.prefix(Self.namedToolLimit), id: \.key) { name, _ in
                            RookeryIconView(Self.icon(ofTool: name))
                        }
                    }
                    .foregroundStyle(StageColors.secondaryText)
                    if listEntries.count == 1 {
                        Text(listNames.first ?? "Tool")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    } else {
                        Text("\(listEntries.count) steps")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(listOrdered.prefix(Self.namedToolLimit), id: \.key) { name, count in
                            InfoTag("\(name) \(count)")
                        }
                        if listOrdered.count > Self.namedToolLimit {
                            InfoTag("+\(listOrdered.count - Self.namedToolLimit)")
                        }
                    }
                    if !isOpen, let last = listEntries.last, !last.text.isEmpty {
                        Text(last.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(StageColors.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(listEntries) { entry in
                        toolLine(entry)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func toolLine(_ entry: TranscriptEntry) -> some View {
        let name = Self.toolName(of: entry) ?? "Tool"
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            RookeryIconView(Self.icon(ofTool: name))
                .foregroundStyle(StageColors.tertiaryText)
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(StageColors.secondaryText)
                .fixedSize()
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.leading, 20)
    }

    private var earlierButton: some View {
        Button(action: onLoadEarlier) {
            RookeryLabel("Read the whole conversation, from \(Self.megabytes(reader.startOffset)) earlier", icon: .arrowUp)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            RookeryIconView(hasTranscript ? .bubble : .offline, scale: 3)
                .foregroundStyle(StageColors.tertiaryText)
            Text(hasTranscript ? "Nothing said yet" : "roost has no transcript of this session")
                .font(.system(size: 13, weight: .semibold))
            if !hasTranscript {
                Text(isSubagent
                    ? "This subagent left no transcript for rook to upload."
                    : "Transcripts arrive once the agent's machine uploads them with rook connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func toggle(_ blockId: Int) {
        withAnimation(Self.foldAnimation) {
            var setOpen = setOpenBlockIds
            if setOpen.contains(blockId) {
                setOpen.remove(blockId)
            } else {
                setOpen.insert(blockId)
            }
            memory.mapOpenTranscriptBlocks[agentId] = setOpen
        }
    }

    private static func toolName(of entry: TranscriptEntry) -> String? {
        if case .tool(let name) = entry.role {
            return name
        }
        return nil
    }

    /// The glyph for a tool, by what it does.
    static func icon(ofTool name: String) -> RookeryIcon {
        switch name {
        case "Bash", "shell", "exec_command", "BashOutput", "KillShell": .terminal
        case "Read", "NotebookRead", "view_image": .book
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": .tool
        case "Grep", "Glob", "LS": .search
        case "WebFetch", "WebSearch", "web_search": .link
        case "Task", "Agent": .crow
        case "TodoWrite", "update_plan": .check
        case "Skill": .book
        default: .tool
        }
    }

    /// When a step happened: the time today, else the day and the time.
    private static func time(of date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func megabytes(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// An agent's answer with its block structure: headings set larger, code in a box of its own that scrolls
/// sideways, prose with its inline marks and line breaks.
struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.blocks(of: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let paragraph):
            Text(Self.inline(paragraph))
                .font(.system(size: fontSize))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let heading):
            Text(Self.inline(heading))
                .font(.system(size: fontSize + (level <= 2 ? 3 : 1), weight: .semibold))
                .padding(.top, 2)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StageColors.tertiaryText)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Prose with its inline marks, a list item's leading dash or star drawn as a bullet.
    private static func inline(_ text: String) -> AttributedString {
        let bulleted = text.replacing(#/(?m)^(\s*)[-*] /#) { match in "\(match.1)• " }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(bulleted)
    }
}

/// Three dots that rise in turn, while an answer is awaited.
struct AwaitingDots: View {
    private static let dotSize: CGFloat = 4
    private static let period = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .offset(y: Self.lift(phase: phase, index: index))
                        .opacity(0.45 + 0.55 * Self.lift(phase: phase, index: index) / -2)
                }
            }
            .frame(height: 8)
        }
    }

    /// How far a dot rises at a point in the loop: up and back in its third of the loop.
    private static func lift(phase: Double, index: Int) -> CGFloat {
        let local = phase * 3 - Double(index)
        guard local >= 0, local < 1 else {
            return 0
        }
        return -2 * CGFloat(sin(local * .pi))
    }
}
