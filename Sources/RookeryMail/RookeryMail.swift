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
            })])
        case "tools/call":
            guard let name = request["params"]?["name"]?.stringValue else {
                return .object(["jsonrpc": .string("2.0"), "id": requestId, "error": error(invalidParams, "a tool call needs a name")])
            }
            result = await call(name, arguments: request["params"]?["arguments"] ?? .object([:]))
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
