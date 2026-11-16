import Foundation

/// Something Raven would do to another agent, put to the user rather than done: `rook-client propose`
/// prints it, and it arrives in Raven's output as the result of that command.
public struct RavenProposal: Codable, Equatable, Identifiable, Sendable {
    /// What Raven would do.
    public enum Action: String, Codable, Sendable {
        case message
    }

    public let id: String
    public let action: Action
    /// The agent it is for.
    public let agentId: String
    /// What the agent was called when Raven proposed it.
    public let agentTitle: String
    /// The text to send.
    public let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case agentId = "agent"
        case agentTitle = "agent_title"
        case text
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
        /// Carried out: the message went as a delivery roost tracks.
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
