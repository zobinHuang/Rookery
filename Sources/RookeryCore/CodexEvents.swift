import Foundation

/// What one event of `codex exec --json` comes to for Raven: the lines it adds to the conversation, in the
/// form Claude Code's transcripts take, so one reader shows both; the thread it opened; and, when the turn
/// ended, whether it failed.
public struct CodexTranslation: Equatable, Sendable {
    public var listLines: [Data] = []
    /// The thread a new session opened, which `codex exec resume` takes.
    public var threadId: String?
    /// Set when the turn ended: nil for success, else why it failed.
    public var turnEnd: TurnEnd?

    public enum TurnEnd: Equatable, Sendable {
        case succeeded
        case failed(String)
    }

    public init() {}

    /// The translation of one event line; an event that says nothing to the user, as reasoning or a
    /// configuration warning, comes to nothing.
    public static func of(_ line: Data) -> CodexTranslation {
        var translation = CodexTranslation()
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return translation
        }
        switch event["type"]?.stringValue {
        case "thread.started":
            translation.threadId = event["thread_id"]?.stringValue
        case "turn.completed":
            translation.turnEnd = .succeeded
        case "turn.failed":
            translation.turnEnd = .failed(event["error"]?["message"]?.stringValue ?? "Codex stopped on an error")
        case "error":
            translation.turnEnd = .failed(event["message"]?.stringValue ?? "Codex stopped on an error")
        case "item.started":
            translation.listLines = startedLines(event["item"] ?? .null)
        case "item.completed":
            translation.listLines = completedLines(event["item"] ?? .null)
        default:
            break
        }
        return translation
    }

    private static func startedLines(_ item: JSONValue) -> [Data] {
        let itemId = item["id"]?.stringValue ?? ""
        switch item["type"]?.stringValue {
        case "mcp_tool_call":
            let name = "mcp__\(item["server"]?.stringValue ?? "")__\(item["tool"]?.stringValue ?? "")"
            return [toolUse(itemId, name: name, input: item["arguments"] ?? .object([:]))]
        case "command_execution":
            return [toolUse(itemId, name: "Bash", input: .object(["command": item["command"] ?? .string("")]))]
        default:
            return []
        }
    }

    private static func completedLines(_ item: JSONValue) -> [Data] {
        let itemId = item["id"]?.stringValue ?? ""
        switch item["type"]?.stringValue {
        case "agent_message":
            let text = item["text"]?.stringValue ?? ""
            return text.isEmpty ? [] : [encode([
                "type": .string("assistant"),
                "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
            ])]
        case "mcp_tool_call":
            let isError = item["status"]?.stringValue == "failed" || item["error"].map { $0 != .null } == true
            let text = isError ? (item["error"]?["message"]?.stringValue ?? item["error"]?.stringValue ?? "failed") : resultText(item["result"] ?? .null)
            return [toolResult(itemId, text: text, isError: isError)]
        case "command_execution":
            return [toolResult(itemId, text: item["aggregated_output"]?.stringValue ?? "", isError: (item["exit_code"]?.numberValue ?? 0) != 0)]
        case "web_search":
            let query = item["action"]?["query"]?.stringValue ?? item["query"]?.stringValue ?? ""
            return query.isEmpty ? [] : [toolUse(itemId, name: "WebSearch", input: .object(["query": .string(query)]))]
        case "file_change":
            guard item["status"]?.stringValue != "failed", case .array(let listChanges) = item["changes"] else {
                return []
            }
            return listChanges.enumerated().compactMap { index, change in
                guard let path = change["path"]?.stringValue, change["kind"]?.stringValue != "delete" else {
                    return nil
                }
                let name = change["kind"]?.stringValue == "add" ? "Write" : "Edit"
                return toolUse("\(itemId)-\(index)", name: name, input: .object(["file_path": .string(path)]))
            }
        default:
            return []
        }
    }

    /// An MCP result's text: its content's text parts, joined.
    private static func resultText(_ result: JSONValue) -> String {
        guard case .array(let listParts) = result["content"] else {
            return result.stringValue ?? ""
        }
        return listParts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private static func toolUse(_ itemId: String, name: String, input: JSONValue) -> Data {
        encode([
            "type": .string("assistant"),
            "message": .object([
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("tool_use"), "id": .string(itemId), "name": .string(name), "input": input])]),
            ]),
        ])
    }

    private static func toolResult(_ itemId: String, text: String, isError: Bool) -> Data {
        encode([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(itemId),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "is_error": .bool(isError),
                ])]),
            ]),
        ])
    }

    private static func encode(_ mapObject: [String: JSONValue]) -> Data {
        (try? JSONEncoder().encode(JSONValue.object(mapObject))) ?? Data()
    }
}
