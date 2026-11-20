import Foundation
import RookeryControl
import RookeryCore

/// `rookery-mail`: an MCP server over stdio that gives a code agent Rookery's mail and calendar tools. It
/// holds no permission of its own: each call goes to the running Rookery over its control socket, which
/// reads Mail's library and the calendars, and only proposes changes for the user to approve.
@main
enum RookeryMail {
    private static let serverName = "rookery-mail"
    private static let serverVersion = "1.0.0"
    private static let defaultProtocolVersion = "2025-06-18"
    private static let methodNotFound = -32601
    private static let invalidParams = -32602
    private static let parseError = -32700
    /// The tool Claude Code asks whether Raven may take an action on the user's Mac, passed to it as its
    /// permission prompt tool.
    static let approvalToolName = "approve_local_action"
    private static let approvalToolDescription = "Rookery asks the user whether Raven may take this action on their Mac. Claude Code calls it itself; never call it."
    /// The tool an agent shows the user the files it made with, each as a card they can open.
    static let presentToolName = "present_files"
    private static let presentToolDescription = "Show the user the files you made or changed for them, once they are done: each shows in the conversation as a card they can open or show in the Finder. Pass only what the user should look at, not every file you touched along the way, by absolute path."

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
                write(.object(["jsonrpc": .string("2.0"), "id": .null, "error": error(parseError, "not JSON")]))
                continue
            }
            if let response = await answer(request) {
                write(response)
            }
        }
    }

    /// The response to one JSON-RPC message, or nil for a notification.
    static func answer(_ request: JSONValue) async -> JSONValue? {
        let method = request["method"]?.stringValue ?? ""
        guard let requestId = request["id"] else {
            return nil
        }
        let result: JSONValue
        switch method {
        case "initialize":
            result = .object([
                "protocolVersion": request["params"]?["protocolVersion"] ?? .string(defaultProtocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
                "instructions": .string(
                    "The user's mail and calendars on their Mac, every account they allowed. Read and search freely. Changes are proposals: the user approves them in Rookery's Raven panel, and no tool sends mail."
                ),
            ])
        case "ping":
            result = .object([:])
        case "tools/list":
            result = .object(["tools": .array(MailTool.allCases.map { tool in
                .object([
                    "name": .string(tool.rawValue),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": .object([
                        "readOnlyHint": .bool(true),
                        "destructiveHint": .bool(false),
                        "openWorldHint": .bool(false),
                    ]),
                ])
            } + [approvalTool, presentTool])])
        case "tools/call":
            guard let name = request["params"]?["name"]?.stringValue else {
                return .object(["jsonrpc": .string("2.0"), "id": requestId, "error": error(invalidParams, "a tool call needs a name")])
            }
            let arguments = request["params"]?["arguments"] ?? .object([:])
            switch name {
            case approvalToolName:
                result = await approve(arguments)
            case presentToolName:
                result = present(arguments)
            default:
                result = await call(name, arguments: arguments)
            }
        default:
            return .object(["jsonrpc": .string("2.0"), "id": requestId, "error": error(methodNotFound, "no method \(method)")])
        }
        return .object(["jsonrpc": .string("2.0"), "id": requestId, "result": result])
    }

    /// A tool's result as MCP gives it: its text, and whether it failed.
    static func call(_ name: String, arguments: JSONValue) async -> JSONValue {
        let text: String
        let isError: Bool
        do {
            let argumentsJSON = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
            let connection = try await ControlConnection.connect(to: ControlSocket.url)
            defer { connection.cancel() }
            try await connection.send(ControlRequest.mailTool(name: name, argumentsJSON: argumentsJSON))
            switch try await connection.receive(ControlMessage.self) {
            case .mailToolResult(let resultText, let isFailed):
                text = resultText
                isError = isFailed
            case .failure(let message):
                text = message
                isError = true
            default:
                text = "Rookery gave no answer"
                isError = true
            }
        } catch {
            text = "Rookery is not running, or cannot be reached: \(error)"
            isError = true
        }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    private static var approvalTool: JSONValue {
        .object([
            "name": .string(approvalToolName),
            "description": .string(approvalToolDescription),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "tool_name": .object(["type": .string("string")]),
                    "input": .object(["type": .string("object")]),
                    "tool_use_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("tool_name"), .string("input")]),
            ]),
        ])
    }

    private static var presentTool: JSONValue {
        .object([
            "name": .string(presentToolName),
            "description": .string(presentToolDescription),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("absolute paths of the files to show")]),
                ]),
                "required": .array([.string("paths")]),
            ]),
            "annotations": .object(["readOnlyHint": .bool(true)]),
        ])
    }

    /// Show files to the user: Rookery reads the call from the conversation and draws each as a card, so
    /// the tool only checks what it is given.
    static func present(_ arguments: JSONValue) -> JSONValue {
        guard case .array(let listPaths) = arguments["paths"] else {
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("name the files in paths")])]), "isError": .bool(true)])
        }
        let listMissing = listPaths.compactMap(\.stringValue).filter { !FileManager.default.fileExists(atPath: $0) }
        let text = listMissing.isEmpty ? "Shown to the user." : "Shown; these are not on this Mac: \(listMissing.joined(separator: ", "))"
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    /// Ask the user, through Rookery, whether Raven may take an action, and answer as Claude Code reads a
    /// permission prompt tool; an action Rookery cannot be asked about is turned down.
    static func approve(_ arguments: JSONValue) async -> JSONValue {
        let input = arguments["input"] ?? .object([:])
        let request = RavenApprovalRequest(
            id: arguments["tool_use_id"]?.stringValue ?? UUID().uuidString,
            conversationId: ProcessInfo.processInfo.environment["ROOKERY_AGENT_ID"] ?? "",
            toolName: arguments["tool_name"]?.stringValue ?? "",
            inputJSON: String(decoding: (try? JSONEncoder().encode(input)) ?? Data(), as: UTF8.self)
        )
        var isAllowed = false
        do {
            let connection = try await ControlConnection.connect(to: ControlSocket.url)
            defer { connection.cancel() }
            try await connection.send(ControlRequest.ravenApproval(request))
            if case .ravenApprovalResult(let isAllowedByUser) = try await connection.receive(ControlMessage.self) {
                isAllowed = isAllowedByUser
            }
        } catch {
            isAllowed = false
        }
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(request.decisionText(isAllowed: isAllowed))])]),
        ])
    }

    private static func error(_ code: Int, _ message: String) -> JSONValue {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    private static func write(_ message: JSONValue) {
        guard let data = try? JSONEncoder().encode(message) else {
            return
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
