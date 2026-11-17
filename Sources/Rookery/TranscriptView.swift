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
            LazyVStack(alignment: .leading, spacing: 0) {
                if reader.startOffset > 0 {
                    earlierButton
                        .padding(.bottom, 14)
                }
                if listBlocks.isEmpty {
                    empty
                }
                ForEach(Array(listBlocks.enumerated()), id: \.element.id) { index, block in
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
                            hasTail: Self.isLastOfRun(block, before: next) && !(next == nil && !listOutgoing.isEmpty && Self.isPrompt(block))
                        )
                    }
                    .padding(.top, Self.spacing(between: previous, and: block))
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: Self.isPrompt(block) ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
                        removal: .opacity
                    ))
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
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: listOutgoing)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: listBlocks.count)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isWorking)
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
    private func blockView(_ block: TranscriptBlock, hasTail: Bool) -> some View {
        switch block {
        case .entry(let entry):
            entryView(entry, hasTail: hasTail)
        case .tools(let listEntries):
            toolRun(listEntries, blockId: block.id)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry, hasTail: Bool) -> some View {
        switch entry.role {
        case .user:
            prompt(entry, hasTail: hasTail)
        case .assistant:
            MessageBubble(isTrailing: false, hasTail: hasTail) {
                MarkdownText(text: entry.text)
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
        }
    }

    private func prompt(_ entry: TranscriptEntry, hasTail: Bool) -> some View {
        MessageBubble(isTrailing: true, hasTail: hasTail) {
            Text(entry.text)
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
            MessageBubble(isTrailing: true, hasTail: hasTail, isFailed: isFailed) {
                Text(outgoing.text)
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

    /// Whether a message ends a run of messages from the same side, which draws its bubble's tail.
    private static func isLastOfRun(_ block: TranscriptBlock, before next: TranscriptBlock?) -> Bool {
        guard let next else {
            return true
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        let widthShare = Self.widthShare
        let edgeAnchor: UnitPoint = isTrailing ? .trailing : .leading
        return content()
            .foregroundStyle(isTrailing ? AnyShapeStyle(StageColors.userBubbleText) : AnyShapeStyle(StageColors.primaryText))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                MessageBubbleShape(isTrailing: isTrailing, hasTail: hasTail)
                    .fill(fill)
                    .overlay {
                        MessageBubbleShape(isTrailing: isTrailing, hasTail: hasTail)
                            .stroke(isTrailing ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.agentBubbleBorder), lineWidth: 1)
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

    private var fill: AnyShapeStyle {
        if isFailed {
            return AnyShapeStyle(Color.red.opacity(0.75))
        }
        return isTrailing ? AnyShapeStyle(StageColors.userBubble) : AnyShapeStyle(StageColors.agentBubble)
    }
}

/// A message bubble's outline: a rounded rectangle, with a tail curling out of its bottom corner on its
/// side when it ends a run.
struct MessageBubbleShape: Shape {
    private static var cornerRadius: CGFloat { 17 }
    private static var tailWidth: CGFloat { 6 }

    let isTrailing: Bool
    let hasTail: Bool

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
        guard !isTrailing else {
            return path
        }
        return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
}
