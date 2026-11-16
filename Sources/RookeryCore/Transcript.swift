import Foundation

/// One step of an agent's conversation, as the detail page shows it.
public struct TranscriptEntry: Equatable, Identifiable, Sendable {
    /// Who the step is from.
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        /// A tool the agent called, by name.
        case tool(String)
        /// A slash command the user ran, as `/compact`.
        case command(String)
        /// The summary the harness wrote when it compacted the conversation, which the agent read in place
        /// of everything before.
        case compaction
    }

    /// The step's place in the transcript.
    public let id: Int
    public let role: Role
    public let text: String
    public let timestamp: Date?

    public init(id: Int, role: Role, text: String, timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }

    /// Whether the step is a tool call.
    public var isTool: Bool {
        if case .tool = role {
            return true
        }
        return false
    }
}

/// What the detail page lays out: a step on its own, or a run of tool calls folded into one.
public enum TranscriptBlock: Equatable, Identifiable, Sendable {
    case entry(TranscriptEntry)
    case tools([TranscriptEntry])

    public var id: Int {
        switch self {
        case .entry(let entry): entry.id
        case .tools(let listEntries): listEntries.first?.id ?? 0
        }
    }

    /// Steps as blocks: each run of consecutive tool calls becomes one block.
    public static func blocks(of listEntries: some Collection<TranscriptEntry>) -> [TranscriptBlock] {
        var listBlocks: [TranscriptBlock] = []
        var listRun: [TranscriptEntry] = []
        for entry in listEntries {
            if entry.isTool {
                listRun.append(entry)
                continue
            }
            if !listRun.isEmpty {
                listBlocks.append(.tools(listRun))
                listRun = []
            }
            listBlocks.append(.entry(entry))
        }
        if !listRun.isEmpty {
            listBlocks.append(.tools(listRun))
        }
        return listBlocks
    }
}

/// Reads an agent's JSONL transcript as it grows, into the steps a person reads: what the user said and
/// the commands they ran, what the agent answered, the tools it called, and where the harness compacted
/// the conversation; and the session's title. Understands Claude Code's transcripts and codex's
/// rollouts; the agent's thinking, tool output, injected context and the harness's bookkeeping are left
/// out. It may start partway through a transcript, at its last stretch.
public struct TranscriptReader: Sendable {
    /// The longest a tool call's summary runs.
    private static let toolSummaryMaxLength = 160
    /// The arguments that best say what a tool call does, in the order they are looked for.
    private static let listSummaryKeys = ["command", "file_path", "path", "pattern", "url", "description", "prompt", "skill", "query"]
    private static var commandNamePattern: Regex<(Substring, Substring)> {
        /<command-name>([^<]*)<\/command-name>/
    }
    private static var commandArgsPattern: Regex<(Substring, Substring)> {
        /<command-args>([^<]*)<\/command-args>/
    }

    public private(set) var listEntries: [TranscriptEntry] = []
    /// The byte of the transcript reading began at; 0 when it began at the start.
    public let startOffset: Int
    /// How many bytes of the transcript have been read since `startOffset`.
    public private(set) var byteCount = 0
    /// The session's title: the one the user gave it, else the one the harness wrote.
    public var title: String? {
        customTitle ?? generatedTitle
    }

    private var pending = Data()
    private var isSkippingPartialLine: Bool
    private var customTitle: String?
    private var generatedTitle: String?

    /// - Parameter startOffset: the byte reading begins at; past 0, the line it falls in is skipped
    public init(startOffset: Int = 0) {
        self.startOffset = startOffset
        isSkippingPartialLine = startOffset > 0
    }

    /// The transcript's byte the next read should start at.
    public var nextOffset: Int {
        startOffset + byteCount
    }

    /// Read bytes the transcript grew by.
    ///
    /// - Parameter data: the bytes that follow those read so far
    public mutating func append(_ data: Data) {
        byteCount += data.count
        pending.append(data)
        var lineStart = pending.startIndex
        while let newlineIndex = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[lineStart..<newlineIndex]
            lineStart = pending.index(after: newlineIndex)
            if isSkippingPartialLine {
                isSkippingPartialLine = false
                continue
            }
            read(line: line)
        }
        pending = Data(pending[lineStart...])
    }

    /// Read one line; the lines of a kind it does not show are passed over before anything is built
    /// from them, which is most of a long transcript.
    private mutating func read(line: Data) {
        guard
            !line.isEmpty,
            let map = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let type = map["type"] as? String
        else {
            return
        }
        let timestamp = (map["timestamp"] as? String).flatMap(FleetTimestamp.date(from:))
        switch type {
        case "response_item":
            if let payload = map["payload"] {
                readCodex(JSONValue(any: payload), timestamp: timestamp)
            }
        case "custom-title":
            customTitle = (map["customTitle"] as? String) ?? customTitle
        case "ai-title":
            generatedTitle = (map["aiTitle"] as? String) ?? generatedTitle
        case "user", "assistant":
            readClaude(JSONValue(any: map), timestamp: timestamp)
        default:
            return
        }
    }

    private mutating func readClaude(_ object: JSONValue, timestamp: Date?) {
        guard
            object["isSidechain"]?.boolValue != true,
            let type = object["type"]?.stringValue,
            type == "user" || type == "assistant"
        else {
            return
        }
        let content = object["message"]?["content"]
        if object["isCompactSummary"]?.boolValue == true {
            add(.compaction, Self.text(of: content), timestamp: timestamp)
            return
        }
        if type == "user", let text = content?.stringValue, let command = Self.command(in: text) {
            add(.command(command), "", timestamp: timestamp)
            return
        }
        guard object["isMeta"]?.boolValue != true else {
            return
        }
        let role: TranscriptEntry.Role = type == "user" ? .user : .assistant
        if let text = content?.stringValue {
            add(role, text, timestamp: timestamp)
            return
        }
        guard case .array(let listBlocks) = content else {
            return
        }
        for block in listBlocks {
            switch block["type"]?.stringValue {
            case "text":
                add(role, block["text"]?.stringValue ?? "", timestamp: timestamp)
            case "tool_use":
                add(.tool(block["name"]?.stringValue ?? "Tool"), Self.summary(of: block["input"]), timestamp: timestamp)
            default:
                break
            }
        }
    }

    private mutating func readCodex(_ payload: JSONValue, timestamp: Date?) {
        switch payload["type"]?.stringValue {
        case "message":
            let role: TranscriptEntry.Role = payload["role"]?.stringValue == "user" ? .user : .assistant
            guard payload["role"]?.stringValue != "developer", case .array(let listBlocks) = payload["content"] else {
                return
            }
            for block in listBlocks {
                add(role, block["text"]?.stringValue ?? "", timestamp: timestamp)
            }
        case "function_call", "custom_tool_call":
            let arguments = payload["arguments"]?.stringValue ?? payload["input"]?.stringValue ?? ""
            let parsed = arguments.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            add(.tool(payload["name"]?.stringValue ?? "tool"), parsed.map { Self.summary(of: $0) } ?? arguments, timestamp: timestamp)
        default:
            break
        }
    }

    /// Keep a step, unless it is empty or context the harness injected rather than words of the user's.
    private mutating func add(_ role: TranscriptEntry.Role, _ text: String, timestamp: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case .tool, .command, .compaction:
            break
        case .user:
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else {
                return
            }
        case .assistant:
            guard !trimmed.isEmpty else {
                return
            }
        }
        listEntries.append(TranscriptEntry(id: startOffset + listEntries.count, role: role, text: trimmed, timestamp: timestamp))
    }

    /// The slash command a user line ran, as `/compact args`, or nil when it is not one.
    private static func command(in text: String) -> String? {
        guard let name = text.firstMatch(of: commandNamePattern)?.1 else {
            return nil
        }
        let arguments = text.firstMatch(of: commandArgsPattern).map { String($0.1) } ?? ""
        let command = String(name).trimmingCharacters(in: .whitespaces)
        return arguments.isEmpty ? command : "\(command) \(arguments)"
    }

    private static func text(of content: JSONValue?) -> String {
        if let text = content?.stringValue {
            return text
        }
        guard case .array(let listBlocks) = content else {
            return ""
        }
        return listBlocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
    }

    /// What a tool call does, in one line: its most telling argument.
    private static func summary(of input: JSONValue?) -> String {
        for key in listSummaryKeys {
            switch input?[key] {
            case .string(let value):
                return clipped(value)
            case .array(let listParts):
                return clipped(listParts.compactMap(\.stringValue).joined(separator: " "))
            default:
                continue
            }
        }
        return ""
    }

    private static func clipped(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > toolSummaryMaxLength ? String(line.prefix(toolSummaryMaxLength)) + "…" : line
    }
}

/// A reply split into what the page draws differently: prose, headings and code.
public enum MarkdownBlock: Equatable, Sendable {
    /// Prose with inline marks, its line breaks kept.
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String, text: String)

    /// A reply's blocks, in order. Lists and quotes stay prose, one line each.
    public static func blocks(of text: String) -> [MarkdownBlock] {
        var listBlocks: [MarkdownBlock] = []
        var listParagraph: [String] = []
        var listCode: [String]?
        var language = ""
        func flushParagraph() {
            let joined = listParagraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                listBlocks.append(.paragraph(joined))
            }
            listParagraph = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let listOpen = listCode {
                    listBlocks.append(.code(language: language, text: listOpen.joined(separator: "\n")))
                    listCode = nil
                } else {
                    flushParagraph()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    listCode = []
                }
                continue
            }
            if listCode != nil {
                listCode?.append(line)
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...4).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph()
                listBlocks.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            listParagraph.append(line)
        }
        if let listOpen = listCode {
            listBlocks.append(.code(language: language, text: listOpen.joined(separator: "\n")))
        }
        flushParagraph()
        return listBlocks
    }
}
