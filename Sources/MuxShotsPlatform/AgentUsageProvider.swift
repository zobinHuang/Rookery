import Foundation
import MuxShotsCore

/// A failure to read an account's plan limits from its harness.
public enum AgentUsageError: Error, CustomStringConvertible, Sendable {
    /// The harness's command could not be found.
    case harnessNotFound(AgentHarness)
    /// The harness did not answer in time.
    case timedOut
    /// The harness answered with an error, or ended without answering.
    case harnessFailed(String)
    /// The account has no plan limits, as when it signs in with an API key.
    case noPlanLimits

    public var description: String {
        switch self {
        case .harnessNotFound(let harness): "\(harness.title) is not installed"
        case .timedOut: "no answer in time"
        case .harnessFailed(let reason): reason
        case .noPlanLimits: "no plan limits on this account"
        }
    }
}

/// Reads one harness's plan limits for its accounts. One conforming type per harness, so more harnesses
/// can be added alongside.
public protocol AgentUsageProvider: Sendable {
    var harness: AgentHarness { get }
    /// The shortest time between reads the harness's service tolerates, which the schedule never goes under.
    var minimumInterval: TimeInterval { get }

    /// The account's plan limits now.
    ///
    /// - Parameter account: an account of this provider's harness
    /// - Returns: the account's usage
    /// - Throws: `AgentUsageError`
    func usage(of account: AgentAccount) async throws -> AgentUsage
}
