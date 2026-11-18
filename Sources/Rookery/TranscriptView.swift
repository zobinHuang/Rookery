import AppKit
import RookeryCore
import SwiftUI

/// A transcript's blocks and where each run of replies starts, worked out again only once the transcript
/// has taken in more, as going through a long one takes a while and a view is drawn again often.
@MainActor
final class TranscriptLayout {
    /// How many blocks a conversation lays out at first, and how many more each time more are asked for.
    static let pageSize = 150

    private var byteCount = -1
    private var entryCount = -1
    private(set) var listBlocks: [TranscriptBlock] = []
    private(set) var setRunStartIds: Set<Int> = []

    /// Work the blocks out again if the transcript changed since.
    func update(for reader: TranscriptReader) {
        guard reader.byteCount != byteCount || reader.listEntries.count != entryCount else {
            return
        }
        byteCount = reader.byteCount
        entryCount = reader.listEntries.count
        listBlocks = TranscriptBlock.blocks(of: reader.listEntries)
        setRunStartIds = TranscriptView.runStartIds(in: listBlocks)
    }
}

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
    /// Who answers in this conversation, named over each run of its replies, as Raven among the rooks
    /// that message it; nil where only the agent answers.
    var replierName: String?
    /// Read the conversation from its start, when the page began at its last stretch.
    let onLoadEarlier: () -> Void

    @Environment(\.people) private var people

    private var isSubagent: Bool {
        FleetAgent.transcriptSessionId(of: agentId) != agentId
    }

    /// The last step shown when the conversation opened: the user's requests after it arrived while it was
    /// shown, and pop in as they come.
    @State private var firstShownBlockId = Int.max
    @State private var layout = TranscriptLayout()
    /// How many of the latest blocks are laid out; a long conversation shows its last stretch, and more
    /// on asking, rather than thousands of rows at once.
    @State private var shownBlockCount = TranscriptLayout.pageSize

    private var setOpenBlockIds: Set<Int> {
        memory.mapOpenTranscriptBlocks[agentId] ?? []
    }

    var body: some View {
        let _ = layout.update(for: reader)
        let listBlocks = layout.listBlocks
        let setRunStartIds = layout.setRunStartIds
        let hiddenCount = max(0, listBlocks.count - shownBlockCount)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hiddenCount > 0 {
                    showEarlierButton(hiddenCount: hiddenCount)
                        .padding(.bottom, 14)
                } else if reader.startOffset > 0 {
                    earlierButton
                        .padding(.bottom, 14)
                }
                if listBlocks.isEmpty {
                    empty
                }
                ForEach(Array(listBlocks[hiddenCount...].enumerated()), id: \.element.id) { shownIndex, block in
                    let index = hiddenCount + shownIndex
                    let previous = index > 0 ? listBlocks[index - 1] : nil
                    let next = index + 1 < listBlocks.count ? listBlocks[index + 1] : nil
                    VStack(spacing: 0) {
                        if let header = Self.timeHeader(of: block, after: previous) {
                            Text(header)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(StageColors.tertiaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, previous == nil ? 0 : 14)
                                .padding(.bottom, 8)
                        }
                        blockView(
                            block,
                            hasTail: Self.isLastOfRun(block, before: next) && !(next == nil && !listOutgoing.isEmpty && Self.isPrompt(block)),
                            isRunStart: setRunStartIds.contains(block.id)
                        )
                    }
                    .modifier(ArrivalEffect(
                        isNew: block.id > firstShownBlockId && Self.isPrompt(block),
                        anchor: Self.isPrompt(block) ? .bottomTrailing : .bottomLeading
                    ))
                    .padding(.top, Self.spacing(between: previous, and: block))
                }
                if isWorking {
                    MessageBubble(isTrailing: false, hasTail: true) {
                        AwaitingDots()
                            .foregroundStyle(StageColors.secondaryText)
                            .padding(.vertical, 3)
                    }
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                }
                ForEach(Array(listOutgoing.enumerated()), id: \.element.id) { index, outgoing in
                    outgoingPrompt(outgoing, hasTail: index == listOutgoing.count - 1)
                        .padding(.top, index == 0 && !(listBlocks.last.map(Self.isPrompt) ?? false) ? 14 : 3)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .scrollTargetLayout()
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: listOutgoing)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isWorking)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .onAppear {
            layout.update(for: reader)
            firstShownBlockId = layout.listBlocks.last?.id ?? -1
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
    private func blockView(_ block: TranscriptBlock, hasTail: Bool, isRunStart: Bool) -> some View {
        switch block {
        case .entry(let entry):
            entryView(entry, hasTail: hasTail, isRunStart: isRunStart)
        case .tools(let listEntries):
            toolRun(listEntries, blockId: block.id)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry, hasTail: Bool, isRunStart: Bool) -> some View {
        switch entry.role {
        case .user:
            prompt(entry, hasTail: hasTail)
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
                if let replierName, isRunStart {
                    SpeakerHeading(name: replierName, isRaven: true, detail: nil, timestamp: nil)
                }
                MessageBubble(isTrailing: false, hasTail: hasTail, copiedText: entry.text) {
                    MarkdownText(text: entry.text)
                }
            }
            .help(entry.timestamp.map(Self.time(of:)) ?? "")
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
        case .message(let sender):
            VStack(alignment: .leading, spacing: 3) {
                if isRunStart {
                    SpeakerHeading(
                        name: sender,
                        isRaven: false,
                        detail: "through rook",
                        timestamp: entry.timestamp.map(Self.time(of:))
                    )
                }
                MessageBubble(isTrailing: false, hasTail: hasTail, tint: SpeakerHeading.rookTint, copiedText: entry.text) {
                    MarkdownText(text: entry.text)
                }
            }
            .help("\(sender), through rook")
        }
    }

    private func prompt(_ entry: TranscriptEntry, hasTail: Bool) -> some View {
        MessageBubble(isTrailing: true, hasTail: hasTail, copiedText: entry.text) {
            mentionText(entry.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(entry.timestamp.map(Self.time(of:)) ?? "")
    }

    /// A prompt on its way: as it will read once recorded, with what became of it beneath, and the agent's
    /// answer awaited once it arrived.
    private func outgoingPrompt(_ outgoing: OutgoingPrompt, hasTail: Bool) -> some View {
        let delivery = mapDeliveries[outgoing.id]
        let isFailed = delivery?.isFailed == true
        return VStack(alignment: .trailing, spacing: 4) {
            MessageBubble(isTrailing: true, hasTail: hasTail, isFailed: isFailed, copiedText: outgoing.text) {
                mentionText(outgoing.text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(delivery?.status == "delivered" || isFailed ? 1 : 0.7)
            .help(Self.time(of: outgoing.sentAt))
            if hasTail || isFailed {
                outgoingStatus(delivery)
                    .padding(.trailing, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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

    /// The way to the blocks laid out before the last stretch, a page more at a time.
    private func showEarlierButton(hiddenCount: Int) -> some View {
        Button {
            shownBlockCount += TranscriptLayout.pageSize
        } label: {
            RookeryLabel(
                "Show \(min(hiddenCount, TranscriptLayout.pageSize)) earlier of \(hiddenCount)",
                icon: .arrowUp
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
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

    /// What the user wrote, each person they named shown as their mark and their name in place of the
    /// mention.
    private func mentionText(_ text: String) -> Text {
        guard let people, !people.listPeople.isEmpty else {
            return Text(text)
        }
        let listRanges = people.book.mentionRanges(in: text)
        guard !listRanges.isEmpty else {
            return Text(text)
        }
        var shown = Text("")
        var index = text.startIndex
        for mention in listRanges {
            shown = shown + Text(text[index..<mention.range.lowerBound])
            shown = shown
                + Text(Image(nsImage: people.markImage(of: mention.person, side: Self.mentionMarkSide))).baselineOffset(Self.mentionMarkDrop)
                + Text("\u{2009}\(mention.person.name)").fontWeight(.semibold)
            index = mention.range.upperBound
        }
        return shown + Text(text[index...])
    }

    private static let mentionMarkSide: CGFloat = 15
    /// How far the mark sits below the text's baseline, to center it on the line.
    private static let mentionMarkDrop: CGFloat = -3

    private static func isPrompt(_ block: TranscriptBlock) -> Bool {
        if case .entry(let entry) = block, entry.role == .user {
            return true
        }
        return false
    }

    private static func isReply(_ block: TranscriptBlock) -> Bool {
        if case .entry(let entry) = block, entry.role == .assistant {
            return true
        }
        return false
    }

    /// The blocks that begin a run from one speaker: a reply after the user or a rook spoke, the agent's
    /// tools in between not counting, and a rook's message after anyone but the same sender.
    static func runStartIds(in listBlocks: [TranscriptBlock]) -> Set<Int> {
        var setStartIds: Set<Int> = []
        var lastSpeaker: TranscriptEntry.Role?
        for block in listBlocks {
            guard case .entry(let entry) = block else {
                continue
            }
            switch entry.role {
            case .user, .assistant, .message:
                if lastSpeaker != entry.role {
                    setStartIds.insert(block.id)
                }
                lastSpeaker = entry.role
            case .command, .compaction:
                lastSpeaker = nil
            case .tool:
                break
            }
        }
        return setStartIds
    }

    /// Whether a message ends a run of messages from the same side, which draws its bubble's tail.
    private static func isLastOfRun(_ block: TranscriptBlock, before next: TranscriptBlock?) -> Bool {
        guard let next else {
            return true
        }
        if case .entry(let entry) = block, case .message = entry.role, case .entry(let nextEntry) = next {
            return nextEntry.role != entry.role
        }
        return isPrompt(block) ? !isPrompt(next) : !isReply(next)
    }

    /// The space above a block: tight within a run from one side, as Messages groups them, and wider where
    /// the other side speaks or the agent turns to its tools.
    private static func spacing(between previous: TranscriptBlock?, and block: TranscriptBlock) -> CGFloat {
        guard let previous else {
            return 0
        }
        if (isPrompt(previous) && isPrompt(block)) || (isReply(previous) && isReply(block)) {
            return 3
        }
        if !isPrompt(previous) && !isPrompt(block) {
            return 6
        }
        return 14
    }

    /// The time over a message, as Messages shows one: over the first message and wherever ten minutes
    /// passed since the one before.
    private static func timeHeader(of block: TranscriptBlock, after previous: TranscriptBlock?) -> String? {
        guard
            isPrompt(block) || isReply(block),
            case .entry(let entry) = block,
            let timestamp = entry.timestamp
        else {
            return nil
        }
        if let previous, let previousTime = lastTimestamp(of: previous), timestamp.timeIntervalSince(previousTime) < timeHeaderGap {
            return nil
        }
        return dayAndTime(of: timestamp)
    }

    private static let timeHeaderGap: TimeInterval = 600

    private static func lastTimestamp(of block: TranscriptBlock) -> Date? {
        switch block {
        case .entry(let entry):
            entry.timestamp
        case .tools(let listEntries):
            listEntries.last?.timestamp
        }
    }

    /// The day and the time, as a header between messages reads: Today, Yesterday, the weekday this week,
    /// else the date.
    private static func dayAndTime(of date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
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
    /// How tall the gap between two paragraphs is, as a share of the text's size, drawn as a short line.
    private static let paragraphGapShare: CGFloat = 0.45

    let text: String
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.groups(of: MarkdownBlock.blocks(of: text)).enumerated()), id: \.offset) { _, listGroup in
                if case .code(let language, let code)? = listGroup.first {
                    codeView(language: language, code: code)
                } else {
                    Text(prose(listGroup))
                        .font(.system(size: fontSize))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The blocks in runs shown as one: each code block alone, the prose between them together, so a
    /// selection runs across its paragraphs and headings.
    private static func groups(of listBlocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
        var listGroups: [[MarkdownBlock]] = []
        for block in listBlocks {
            if case .code = block {
                listGroups.append([block])
            } else if let last = listGroups.last?.last, !Self.isCode(last) {
                listGroups[listGroups.count - 1].append(block)
            } else {
                listGroups.append([block])
            }
        }
        return listGroups
    }

    private static func isCode(_ block: MarkdownBlock) -> Bool {
        if case .code = block {
            return true
        }
        return false
    }

    /// A run of prose as one text: headings larger and bold, paragraphs apart by a short blank line.
    private func prose(_ listGroup: [MarkdownBlock]) -> AttributedString {
        var joined = AttributedString()
        for (index, block) in listGroup.enumerated() {
            if index > 0 {
                var gap = AttributedString("\n\n")
                gap.font = .system(size: fontSize * Self.paragraphGapShare)
                joined += gap
            }
            switch block {
            case .paragraph(let paragraph):
                joined += Self.inline(paragraph)
            case .heading(let level, let heading):
                var title = Self.inline(heading)
                title.font = .system(size: fontSize + (level <= 2 ? 3 : 1), weight: .semibold)
                joined += title
            case .code:
                break
            }
        }
        return joined
    }

    private func codeView(language: String, code: String) -> some View {
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

    /// Prose with its inline marks, a list item's leading dash or star drawn as a bullet.
    private static func inline(_ text: String) -> AttributedString {
        let bulleted = text.replacing(#/(?m)^(\s*)[-*] /#) { match in "\(match.1)• " }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(bulleted)
    }
}

/// Three dots rising one after another, as a conversation waits on an answer. Core Animation runs them,
/// so waiting costs the app nothing frame by frame: a view redrawn every frame would lay the whole window
/// out again each time.
struct AwaitingDots: NSViewRepresentable {
    func makeNSView(context: Context) -> AwaitingDotsView {
        AwaitingDotsView()
    }

    func updateNSView(_ view: AwaitingDotsView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AwaitingDotsView, context: Context) -> CGSize? {
        AwaitingDotsView.size
    }
}

/// The layers of `AwaitingDots`: three dots, each rising and brightening in its third of a loop.
final class AwaitingDotsView: NSView {
    static let size = CGSize(width: dotSize * 3 + spacing * 2, height: 8)
    private static let dotSize: CGFloat = 4
    private static let spacing: CGFloat = 3
    private static let period: CFTimeInterval = 1.2
    private static let rise: CGFloat = 2
    private static let restingOpacity: Float = 0.45
    private static let animationKey = "rise"
    /// Each dot rises over the first sixth of the loop, falls over the next, then rests.
    private static let keyTimes: [NSNumber] = [0, NSNumber(value: 1.0 / 6), NSNumber(value: 1.0 / 3), 1]

    private var listDots: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(
                x: CGFloat(index) * (Self.dotSize + Self.spacing),
                y: (Self.size.height - Self.dotSize) / 2,
                width: Self.dotSize,
                height: Self.dotSize
            )
            dot.cornerRadius = Self.dotSize / 2
            layer?.addSublayer(dot)
            listDots.append(dot)
        }
        tint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        Self.size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        play()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.secondaryLabelColor.cgColor
            for dot in listDots {
                dot.backgroundColor = color
            }
        }
    }

    /// Start each dot's loop, a third of a loop after the one before; none while off screen.
    private func play() {
        for (index, dot) in listDots.enumerated() {
            dot.removeAnimation(forKey: Self.animationKey)
            guard window != nil else {
                continue
            }
            let position = CAKeyframeAnimation(keyPath: "position.y")
            let base = dot.position.y
            position.values = [base, base + Self.rise, base, base]
            position.keyTimes = Self.keyTimes
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [Self.restingOpacity, 1, Self.restingOpacity, Self.restingOpacity]
            opacity.keyTimes = Self.keyTimes
            let group = CAAnimationGroup()
            group.animations = [position, opacity]
            group.duration = Self.period
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Self.period * Double(index) / 3
            group.isRemovedOnCompletion = false
            dot.opacity = Self.restingOpacity
            dot.add(group, forKey: Self.animationKey)
        }
    }
}

/// A message in a bubble as Messages draws one: the user's on the right in blue, the agent's on the left in
/// grey, rounded, the last of a run from one side with a tail at its bottom corner. As the conversation
/// scrolls, a bubble at the edge of the view shrinks a little and fades, and springs back as it comes in.
struct MessageBubble<Content: View>: View {
    private static var cornerRadius: CGFloat { 17 }
    private static var tailWidth: CGFloat { 6 }
    /// The share of the conversation's width a bubble may take.
    private static var widthShare: CGFloat { 0.78 }

    let isTrailing: Bool
    let hasTail: Bool
    var isFailed = false
    /// A colour the bubble is washed in, telling a speaker apart from the agent, as a rook's message.
    var tint: Color?
    /// What Copy in the bubble's menu puts on the clipboard, the message as it was written; nil for no menu.
    var copiedText: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let widthShare = Self.widthShare
        let edgeAnchor: UnitPoint = isTrailing ? .trailing : .leading
        return content()
            .textSelection(.enabled)
            .foregroundStyle(isTrailing ? AnyShapeStyle(StageColors.userBubbleText) : AnyShapeStyle(StageColors.primaryText))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                MessageBubbleShape(isTrailing: isTrailing, hasTail: hasTail)
                    .fill(fill)
                    .overlay {
                        MessageBubbleShape(isTrailing: isTrailing, hasTail: hasTail)
                            .stroke(border, lineWidth: 1)
                    }
            }
            .contextMenu {
                if let copiedText {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copiedText, forType: .string)
                    }
                }
            }
            .containerRelativeFrame(.horizontal, alignment: isTrailing ? .trailing : .leading) { width, _ in
                width * widthShare
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
            .padding(isTrailing ? .trailing : .leading, Self.tailWidth)
            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .scaleEffect(phase.isIdentity ? 1 : 0.93, anchor: edgeAnchor)
                    .opacity(phase.isIdentity ? 1 : 0.55)
                    .offset(y: phase.value * 8)
            }
    }

    private var border: AnyShapeStyle {
        if isTrailing {
            return AnyShapeStyle(Color.clear)
        }
        if let tint {
            return AnyShapeStyle(tint.opacity(0.45))
        }
        return AnyShapeStyle(StageColors.agentBubbleBorder)
    }

    private var fill: AnyShapeStyle {
        if isFailed {
            return AnyShapeStyle(Color.red.opacity(0.75))
        }
        if let tint, !isTrailing {
            return AnyShapeStyle(tint.opacity(0.14))
        }
        return isTrailing ? AnyShapeStyle(StageColors.userBubble) : AnyShapeStyle(StageColors.agentBubble)
    }
}

/// A message bubble's outline: a rounded rectangle, with a tail curling out of its bottom corner on its
/// side when it ends a run, or out of its top corner, toward a mark above it.
struct MessageBubbleShape: Shape {
    private static var cornerRadius: CGFloat { 17 }
    private static var tailWidth: CGFloat { 6 }

    let isTrailing: Bool
    let hasTail: Bool
    var isTailOnTop = false

    func path(in rect: CGRect) -> Path {
        let radius = min(Self.cornerRadius, rect.height / 2, rect.width / 2)
        guard hasTail else {
            return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        }
        var path = Path()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        path.move(to: CGPoint(x: minX + radius, y: minY))
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: maxX, y: maxY - 8))
        path.addQuadCurve(to: CGPoint(x: maxX + Self.tailWidth, y: maxY), control: CGPoint(x: maxX, y: maxY - 1))
        path.addQuadCurve(to: CGPoint(x: maxX - 8, y: maxY - 2.5), control: CGPoint(x: maxX - 2, y: maxY + 0.5))
        path.addQuadCurve(to: CGPoint(x: maxX - 16, y: maxY), control: CGPoint(x: maxX - 11, y: maxY))
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + radius, y: minY), radius: radius)
        path.closeSubpath()
        if !isTrailing {
            path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        if isTailOnTop {
            path = path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY))
        }
        return path
    }
}

/// A request of the user's that arrived while the conversation was shown popping in on its own, growing
/// from its corner as it fades in, without moving the steps around it. An answer streaming in does not
/// pop: a line arriving every moment would keep an animation running for as long as the answer, and the
/// conversation laid out again on every frame of it.
struct ArrivalEffect: ViewModifier {
    private static let popAnimation = Animation.spring(response: 0.38, dampingFraction: 0.78)
    private static let startScale: CGFloat = 0.85

    let isNew: Bool
    let anchor: UnitPoint

    @State private var isShown = false

    func body(content: Content) -> some View {
        let isAtRest = isShown || !isNew
        content
            .scaleEffect(isAtRest ? 1 : Self.startScale, anchor: anchor)
            .opacity(isAtRest ? 1 : 0)
            .animation(Self.popAnimation, value: isShown)
            .onAppear {
                if isNew, !isShown {
                    isShown = true
                }
            }
    }
}

/// Who speaks a run of left-hand messages in a conversation with several speakers: a still of Raven or of a
/// rook's crow, the name, and for a rook how its message came and when.
struct SpeakerHeading: View {
    /// The wash of a rook's messages and the colour of its name, the crows' gold.
    static let rookTint = RookmasterStyle.tint(of: AgentFleet.agentKind)
    private static let avatarSize: CGFloat = 18
    /// The pixels a point the avatar is drawn at, enough for any screen.
    private static let avatarScale: CGFloat = 3
    @Environment(\.stageTheme) private var theme

    let name: String
    let isRaven: Bool
    let detail: String?
    let timestamp: String?

    var body: some View {
        HStack(spacing: 5) {
            avatar
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isRaven ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(Self.rookTint))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(StageColors.secondaryText)
            }
            if let timestamp {
                Text(timestamp)
                    .font(.system(size: 10))
                    .foregroundStyle(StageColors.tertiaryText)
            }
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private var avatar: some View {
        let key = CrowFrames.Key(
            act: isRaven ? .ravenIdle : .agent(.needsInput),
            side: Int(Self.avatarSize * Self.avatarScale),
            look: CrowFrames.look(of: theme)
        )
        if let still = CrowFrames.shared.still(key) {
            Image(decorative: still, scale: Self.avatarScale)
                .resizable()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
        } else {
            RookeryIconView(.agent)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
        }
    }
}

