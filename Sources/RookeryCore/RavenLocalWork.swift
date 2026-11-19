import Foundation

/// Whether Raven asks the user before working on their Mac in a conversation: running a command,
/// writing or changing a file.
public enum RavenLocalAccess: String, Codable, Equatable, Sendable {
    /// Each action waits on the user's approval.
    case ask
    /// The user allowed every action in the conversation.
    case allowed
    /// On Codex, which cannot ask action by action: the user kept the conversation to its sandbox.
    case sandboxed
}

/// What the user answers an action Raven asks to take on their Mac.
public enum RavenApprovalChoice: String, Codable, Equatable, Sendable {
    /// This action alone, or on Codex this turn alone.
    case once
    /// Every action in the conversation from now on.
    case conversation
    case deny
}

/// An action Raven asks to take on the user's Mac, as Claude Code hands it to the tool that answers its
/// permission prompts: the tool, its input, and the conversation it is in.
public struct RavenApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    /// The tool Codex is asked about as a whole before a turn, which it cannot ask action by action.
    public static let codexTurnTool = "CodexTurn"

    public let id: String
    public let conversationId: String
    public let toolName: String
    /// The tool's input, as JSON.
    public let inputJSON: String

    public init(id: String, conversationId: String, toolName: String, inputJSON: String) {
        self.id = id
        self.conversationId = conversationId
        self.toolName = toolName
        self.inputJSON = inputJSON
    }

    /// The tool's input, or an empty object when it is not JSON.
    public var input: JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(inputJSON.utf8))) ?? .object([:])
    }

    /// The action in a line the user reads: the command, the file, the address, or the input itself.
    public var summary: String {
        let value = input
        for key in ["command", "file_path", "notebook_path", "url", "query", "path", "pattern"] {
            if let text = value[key]?.stringValue, !text.isEmpty {
                return text
            }
        }
        return inputJSON
    }

    /// What the action does, in a few words: a command, a file written or changed, or the tool's name.
    public var verb: String {
        switch toolName {
        case "Bash": "Run a command"
        case "Write": "Write a file"
        case "Edit", "MultiEdit", "NotebookEdit": "Change a file"
        case Self.codexTurnTool: "Work on this Mac"
        default: "Use \(toolName)"
        }
    }

    /// The answer Claude Code reads from its permission prompt tool: allowed with the input unchanged, or
    /// turned down with why.
    ///
    /// - Parameter isAllowed: whether the user allowed the action
    /// - Returns: the answer as JSON text
    public func decisionText(isAllowed: Bool) -> String {
        let decision: JSONValue = isAllowed
            ? .object(["behavior": .string("allow"), "updatedInput": input])
            : .object(["behavior": .string("deny"), "message": .string("The user declined this action. Do not try it another way; say what you would have done and ask.")])
        return String(decoding: (try? JSONEncoder().encode(decision)) ?? Data(), as: UTF8.self)
    }
}

/// Where Raven works on the user's Mac, and what tells it so.
public enum RavenLocalWork {
    /// The folder a conversation works in until the user chooses another.
    public static var defaultFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Raven", directoryHint: .isDirectory)
    }

    /// What Raven is told of its folder at the start of every turn.
    public static func folderPrompt(_ folder: URL) -> String {
        """
        You can work on the user's Mac. This conversation's folder is \(folder.path): create files there, \
        and work there, unless the user names another place. Write and change files with the Write and \
        Edit tools rather than through the shell, so the user sees each one in the conversation and can \
        open it. Running a command or writing a file waits on the user's approval in Rookery unless they \
        allowed it; when they decline, say what you would have done instead of trying another way. A \
        mention of `@` followed by a path names a file or folder on this Mac.
        """
    }
}
