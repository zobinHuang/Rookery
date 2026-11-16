import Foundation

/// One step of an agent's conversation, as the detail page shows it.
public struct TranscriptEntry: Equatable, Identifiable, Sendable {
    /// Who the step is from.
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        /// A tool the agent called, by name.
        case tool(String)
    }

    /// The step's place in the transcript.
    public let id: Int
    public let role: Role
    public let text: String

    public init(id: Int, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Reads an agent's JSONL transcript as it grows, into the steps a person reads: what the user said, what
/// the agent answered, and the tools it called. Understands Claude Code's transcripts and codex's
/// rollouts; lines of any other shape, the agent's thinking, tool output and injected context are left out.
public struct TranscriptReader: Sendable {
    /// The longest a tool call's summary runs.
    private static let toolSummaryMaxLength = 160
    /// The arguments that best say what a tool call does, in the order they are looked for.
    private static let listSummaryKeys = ["command", "file_path", "path", "pattern", "url", "description", "prompt", "skill", "query"]

    public private(set) var listEntries: [TranscriptEntry] = []
    /// How many bytes of the transcript have been read.
    public private(set) var byteCount = 0
    private var pending = Data()

    public init() {}

    /// Read bytes the transcript grew by.
    ///
    /// - Parameter data: the bytes that follow those read so far
    public mutating func append(_ data: Data) {
        byteCount += data.count
        pending.append(data)
        while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newlineIndex]
            pending.removeSubrange(pending.startIndex...newlineIndex)
            read(line: Data(line))
        }
    }

    private mutating func read(line: Data) {
        guard
            !line.isEmpty,
            let object = try? JSONDecoder().decode(JSONValue.self, from: line)
        else {
            return
        }
        if object["type"]?.stringValue == "response_item", let payload = object["payload"] {
            readCodex(payload)
        } else {
            readClaude(object)
        }
    }

    private mutating func readClaude(_ object: JSONValue) {
        guard
            object["isSidechain"]?.boolValue != true,
            object["isMeta"]?.boolValue != true,
            let type = object["type"]?.stringValue,
            type == "user" || type == "assistant"
        else {
            return
        }
        let role: TranscriptEntry.Role = type == "user" ? .user : .assistant
        let content = object["message"]?["content"]
        if let text = content?.stringValue {
            add(role, text)
            return
        }
        guard case .array(let listBlocks) = content else {
            return
        }
        for block in listBlocks {
            switch block["type"]?.stringValue {
            case "text":
                add(role, block["text"]?.stringValue ?? "")
            case "tool_use":
                add(.tool(block["name"]?.stringValue ?? "Tool"), Self.summary(of: block["input"]))
            default:
                break
            }
        }
    }

    private mutating func readCodex(_ payload: JSONValue) {
        switch payload["type"]?.stringValue {
        case "message":
            let role: TranscriptEntry.Role = payload["role"]?.stringValue == "user" ? .user : .assistant
            guard payload["role"]?.stringValue != "developer", case .array(let listBlocks) = payload["content"] else {
                return
            }
            for block in listBlocks {
                add(role, block["text"]?.stringValue ?? "")
            }
        case "function_call", "custom_tool_call":
            let arguments = payload["arguments"]?.stringValue ?? payload["input"]?.stringValue ?? ""
            let parsed = arguments.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            add(.tool(payload["name"]?.stringValue ?? "tool"), parsed.map { Self.summary(of: $0) } ?? arguments)
        default:
            break
        }
    }

    /// Keep a step, unless it is empty or context the harness injected rather than words of the user's.
    private mutating func add(_ role: TranscriptEntry.Role, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .tool = role {
            listEntries.append(TranscriptEntry(id: listEntries.count, role: role, text: trimmed))
            return
        }
        guard !trimmed.isEmpty, !(role == .user && trimmed.hasPrefix("<")) else {
            return
        }
        listEntries.append(TranscriptEntry(id: listEntries.count, role: role, text: trimmed))
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
