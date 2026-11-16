import Foundation

/// Something Raven would do to another agent, or on a rook, put to the user rather than done:
/// `rook-client propose` prints it, and it arrives in Raven's output as the result of that command.
public struct RavenProposal: Codable, Equatable, Identifiable, Sendable {
    /// What Raven would do.
    public enum Action: String, Codable, Sendable {
        /// Send the agent a prompt.
        case message
        /// Stop what the agent is doing.
        case interrupt
        /// Answer the agent's approval prompt with `choice`.
        case approve
        /// Start a new session on `rook`, in `cwd`, with `text` as its first prompt.
        case spawn
    }

    /// The answers to an approval prompt Raven may propose.
    public static let approveOnce = "once"
    public static let approveDeny = "deny"

    public let id: String
    public let action: Action
    /// The agent it is for; nil for a new session.
    public let agentId: String?
    /// What the agent was called when Raven proposed it, or the new session's harness and rook.
    public let agentTitle: String
    /// The text to send, or the new session's first prompt; empty for none.
    public let text: String
    /// For an approval: `once` or `deny`.
    public let choice: String?
    /// For a new session: the rook, the directory there and the harness.
    public let rook: String?
    public let cwd: String?
    public let harness: String?

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case agentId = "agent"
        case agentTitle = "agent_title"
        case text
        case choice
        case rook
        case cwd
        case harness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(Action.self, forKey: .action)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentTitle = try container.decodeIfPresent(String.self, forKey: .agentTitle) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
        rook = try container.decodeIfPresent(String.self, forKey: .rook)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        harness = try container.decodeIfPresent(String.self, forKey: .harness)
    }

    /// The marker the proposal's line starts with in the command's output.
    private static let marker = #"{"proposal":"#

    /// The proposals in one line of Raven's output or history: those a command's result printed.
    ///
    /// - Parameter line: one JSON line, as the stream-json output and the transcript hold it
    public static func proposals(in line: Data) -> [RavenProposal] {
        guard
            let object = try? JSONDecoder().decode(JSONValue.self, from: line),
            object["type"]?.stringValue == "user",
            case .array(let listBlocks) = object["message"]?["content"]
        else {
            return []
        }
        return listBlocks
            .filter { $0["type"]?.stringValue == "tool_result" }
            .flatMap { block in resultText(of: block).split(whereSeparator: \.isNewline) }
            .filter { $0.hasPrefix(marker) }
            .compactMap { proposalLine in
                try? JSONDecoder().decode([String: RavenProposal].self, from: Data(proposalLine.utf8))["proposal"]
            }
    }

    private static func resultText(of block: JSONValue) -> String {
        switch block["content"] {
        case .string(let text):
            return text
        case .array(let listParts):
            return listParts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default:
            return ""
        }
    }
}

/// What the user decided about a proposal, and whether Raven has heard.
public struct RavenDecision: Codable, Equatable, Sendable {
    /// The decision itself.
    public enum Outcome: Codable, Equatable, Sendable {
        /// Carried out: it went to its agent or rook as a delivery roost tracks.
        case sent(deliveryId: String)
        case rejected
    }

    public let outcome: Outcome
    public let decidedAt: Date
    /// Whether Raven was told, with the request after it.
    public var isReported: Bool

    public init(outcome: Outcome, decidedAt: Date, isReported: Bool = false) {
        self.outcome = outcome
        self.decidedAt = decidedAt
        self.isReported = isReported
    }
}
