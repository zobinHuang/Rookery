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
        /// A message another agent sent through rook, by the name of who sent it.
        case message(String)
    }

    /// The step's place in the transcript.
    public let id: Int
    public let role: Role
    public let text: String
    public let timestamp: Date?
    /// The file an agent presented to the user, by its absolute path; nil for any other step.
    public let filePath: String?
    /// The web page a tool call opened in the browser, by its address; nil for any other step.
    public let pageURL: String?

    /// The tool an agent presents the files it made for the user with, shown as those files: its name
    /// after the MCP server's prefix.
    public static let presentFilesTool = "present_files"
    /// The prefix of the tools Claude in Chrome gives a session.
    public static let chromeToolPrefix = "mcp__claude-in-chrome__"
    /// The Chrome tools that open a page, shown as the page.
    public static let setPageTools: Set<String> = ["navigate", "tabs_create_mcp"]

    public init(id: Int, role: Role, text: String, timestamp: Date? = nil, filePath: String? = nil, pageURL: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.filePath = filePath
        self.pageURL = pageURL
    }

    /// Whether the step is a tool call.
    public var isTool: Bool {
        if case .tool = role {
            return true
        }
        return false
    }

    /// Whether the step presents a file to the user, which shows on its own rather than among the tool calls.
    public var isFile: Bool {
        filePath != nil
    }

    /// Whether the step opened a web page, which shows on its own rather than among the tool calls.
    public var isPage: Bool {
        pageURL != nil
    }
}

/// What the detail page lays out: a step on its own, or a run of tool calls folded into one.
public enum TranscriptBlock: Equatable, Identifiable, Sendable {
    case entry(TranscriptEntry)
    case tools([TranscriptEntry])
    /// A file an agent presented to the user.
    case file(TranscriptEntry)
    /// A web page a tool call opened in the browser.
    case page(TranscriptEntry)

    public var id: Int {
        switch self {
        case .entry(let entry): entry.id
        case .tools(let listEntries): listEntries.first?.id ?? 0
        case .file(let entry): entry.id
        case .page(let entry): entry.id
        }
    }

    /// Steps as blocks: each run of consecutive tool calls becomes one block, a file presented or a page
    /// opened one of its own.
    public static func blocks(of listEntries: some Collection<TranscriptEntry>) -> [TranscriptBlock] {
        var listBlocks: [TranscriptBlock] = []
        var listRun: [TranscriptEntry] = []
        for entry in listEntries {
            if entry.isTool, !entry.isFile, !entry.isPage {
                listRun.append(entry)
                continue
            }
            if !listRun.isEmpty {
                listBlocks.append(.tools(listRun))
                listRun = []
            }
            listBlocks.append(entry.isFile ? .file(entry) : entry.isPage ? .page(entry) : .entry(entry))
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
    private static let listSummaryKeys = ["command", "file_path", "path", "pattern", "url", "description", "prompt", "skill", "query", "text", "value", "action"]
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
        guard
            object["isMeta"]?.boolValue != true,
            object["isSynthetic"]?.boolValue != true
        else {
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
                let name = block["name"]?.stringValue ?? "Tool"
                let listPresented = Self.presentedPaths(ofTool: name, input: block["input"])
                if listPresented.isEmpty {
                    add(.tool(name), Self.summary(of: block["input"]), timestamp: timestamp, pageURL: Self.pageURL(ofTool: name, input: block["input"]))
                }
                for path in listPresented {
                    add(.tool(name), path, timestamp: timestamp, filePath: path)
                }
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
    private mutating func add(_ role: TranscriptEntry.Role, _ text: String, timestamp: Date?, filePath: String? = nil, pageURL: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case .tool, .command, .compaction, .message:
            break
        case .user:
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else {
                return
            }
            if let message = RookMessage.parse(trimmed) {
                listEntries.append(TranscriptEntry(
                    id: startOffset + listEntries.count,
                    role: .message(message.senderName),
                    text: message.text,
                    timestamp: timestamp
                ))
                return
            }
        case .assistant:
            guard !trimmed.isEmpty else {
                return
            }
        }
        listEntries.append(TranscriptEntry(id: startOffset + listEntries.count, role: role, text: trimmed, timestamp: timestamp, filePath: filePath, pageURL: pageURL))
    }

    /// The address of the web page a Chrome tool call opens, or nil when it is no such call.
    static func pageURL(ofTool name: String, input: JSONValue?) -> String? {
        guard
            name.hasPrefix(TranscriptEntry.chromeToolPrefix),
            TranscriptEntry.setPageTools.contains(String(name.dropFirst(TranscriptEntry.chromeToolPrefix.count))),
            let url = input?["url"]?.stringValue,
            url.hasPrefix("http://") || url.hasPrefix("https://")
        else {
            return nil
        }
        return url
    }

    /// The absolute paths of the files a call presents to the user; none when it is no such call.
    static func presentedPaths(ofTool name: String, input: JSONValue?) -> [String] {
        guard name == TranscriptEntry.presentFilesTool || name.hasSuffix("__" + TranscriptEntry.presentFilesTool) else {
            return []
        }
        guard case .array(let listPaths) = input?["paths"] else {
            return []
        }
        return listPaths.compactMap(\.stringValue).filter { $0.hasPrefix("/") }
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

/// A prompt the user sent an agent through roost, shown at the end of its conversation until the agent's
/// transcript records it.
public struct OutgoingPrompt: Equatable, Identifiable, Sendable {
    /// How much of a prompt's start must show up in a recorded prompt for the two to be the same.
    private static let matchedPrefixLength = 60

    /// The delivery roost made of it.
    public let id: String
    public let text: String
    public let sentAt: Date
    /// The entries the transcript held when it was sent; it is recorded among those after.
    public let entryCountAtSend: Int

    public init(id: String, text: String, sentAt: Date, entryCountAtSend: Int) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.entryCountAtSend = entryCountAtSend
    }

    /// Whether the transcript now records the prompt: a prompt after the point it was sent that holds its
    /// start, which a harness may have framed or the reader trimmed.
    ///
    /// - Parameter listEntries: the transcript's entries
    public func isRecorded(in listEntries: [TranscriptEntry]) -> Bool {
        let needle = Self.normalized(String(text.prefix(Self.matchedPrefixLength)))
        guard !needle.isEmpty else {
            return true
        }
        return listEntries.dropFirst(min(entryCountAtSend, listEntries.count)).contains { entry in
            entry.role == .user && Self.normalized(entry.text).contains(needle)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
