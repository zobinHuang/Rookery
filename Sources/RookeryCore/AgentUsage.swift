import Foundation

/// A code agent harness whose plan limits Rookery can show.
public enum AgentHarness: String, Codable, CaseIterable, Sendable {
    case claudeCode

    /// The harness's name as the settings show it.
    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        }
    }

    /// The shell command that signs an account in, for the user to paste into a terminal.
    ///
    /// - Parameter configDirectory: the account's configuration directory; nil for the harness's default
    /// - Returns: the command, with the directory quoted for the shell
    public func signInCommand(configDirectory: String?) -> String {
        switch self {
        case .claudeCode:
            guard let configDirectory else {
                return "claude auth login"
            }
            return "CLAUDE_CONFIG_DIR=\(Self.shellQuoted(configDirectory)) claude auth login"
        }
    }

    /// A path quoted for the shell, a leading "~/" kept working as the home directory.
    private static func shellQuoted(_ path: String) -> String {
        let homePrefix = "~/"
        let isInHome = path.hasPrefix(homePrefix)
        let rest = isInHome ? String(path.dropFirst(homePrefix.count)) : path
        let escaped = rest.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return isInHome ? "\"$HOME/\(escaped)\"" : "\"\(escaped)\""
    }
}

/// An account of a code agent harness, as the user set it up: the harness, the directory it keeps the
/// account's login in, and how the sidebar names it.
public struct AgentAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var harness: AgentHarness
    public var label: String
    /// The harness's configuration directory holding this account's login; nil for the harness's default.
    public var configDirectory: String?
    /// Whether the sidebar shows the account.
    public var isShown: Bool

    public init(id: String = UUID().uuidString, harness: AgentHarness, label: String, configDirectory: String?, isShown: Bool = true) {
        self.id = id
        self.harness = harness
        self.label = label
        self.configDirectory = configDirectory
        self.isShown = isShown
    }
}

/// How close a limit is to running out, as the harness judges it.
public enum AgentLimitSeverity: String, Codable, Sendable {
    case normal
    case warning
    case critical
}

/// One of an account's plan limits: a window of usage that resets at some time.
public struct AgentLimit: Codable, Equatable, Identifiable, Sendable {
    /// What distinguishes the limit among the account's, stable across refreshes.
    public let id: String
    /// A short name for the limit, as "5h", "7d" or a model's name.
    public let title: String
    /// How much of the limit is used, 0 to 100.
    public let usedPercent: Double
    public let resetsAt: Date?
    public let severity: AgentLimitSeverity

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?, severity: AgentLimitSeverity) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.severity = severity
    }

    /// How much of the limit is left, 0 to 1.
    public var remainingFraction: Double {
        min(max(1 - usedPercent / 100, 0), 1)
    }
}

/// An account's plan limits as last read from its harness.
public struct AgentUsage: Codable, Equatable, Sendable {
    /// Who the harness is signed in as, as an email address; nil when the harness does not say.
    public let signedInAs: String?
    /// The plan, as "max", "ultra" or "pro"; nil when the harness does not say.
    public let plan: String?
    public let listLimits: [AgentLimit]
    public let fetchedAt: Date

    public init(signedInAs: String? = nil, plan: String?, listLimits: [AgentLimit], fetchedAt: Date) {
        self.signedInAs = signedInAs
        self.plan = plan
        self.listLimits = listLimits
        self.fetchedAt = fetchedAt
    }
}

/// Reading Claude Code's answer to a `get_usage` control request into an account's usage.
public enum ClaudeCodeUsageDecoder {
    /// A failure to read an answer.
    public enum DecodingError: Error, Equatable {
        /// The account has no plan limits, as with an API key.
        case noPlanLimits
        case malformed(String)
    }

    private static let titleSession = "5h"
    private static let planNamePrefix = "Claude "
    private static let titleWeekly = "7d"

    /// Read the body of a successful `get_usage` response, with who is signed in and the plan from the
    /// `initialize` response's body when there is one: `get_usage` calls an Ultra plan "max".
    ///
    /// - Parameters:
    ///   - data: the `get_usage` response body as JSON
    ///   - initializeData: the `initialize` response body as JSON
    ///   - fetchedAt: when the answer came
    /// - Returns: the account's usage
    /// - Throws: `DecodingError` when the answer has no plan limits or cannot be read
    public static func decode(_ data: Data, initializeData: Data? = nil, fetchedAt: Date) throws -> AgentUsage {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw DecodingError.malformed(String(describing: error))
        }
        guard body.rateLimitsAvailable, let limits = body.rateLimits?.limits else {
            throw DecodingError.noPlanLimits
        }
        let listLimits = limits.map { limit in
            AgentLimit(
                id: [limit.kind, limit.scope?.model?.displayName].compactMap { $0 }.joined(separator: ":"),
                title: title(of: limit),
                usedPercent: limit.percent,
                resetsAt: limit.resetsAt.flatMap(parseDate),
                severity: AgentLimitSeverity(rawValue: limit.severity ?? "") ?? .normal
            )
        }
        let account = initializeData.flatMap { try? JSONDecoder().decode(Initialize.self, from: $0) }?.account
        return AgentUsage(
            signedInAs: account?.email,
            plan: account?.subscriptionType.map(planName) ?? body.subscriptionType,
            listLimits: listLimits,
            fetchedAt: fetchedAt
        )
    }

    /// The part of the `initialize` answer that says who is signed in and on which plan.
    private struct Initialize: Decodable {
        struct Account: Decodable {
            let email: String?
            let subscriptionType: String?
        }

        let account: Account?
    }

    /// The plan as `initialize` names it, "Claude Ultra", in the short form `get_usage` uses, "ultra".
    private static func planName(_ subscriptionType: String) -> String {
        let name = subscriptionType.hasPrefix(planNamePrefix)
            ? String(subscriptionType.dropFirst(planNamePrefix.count))
            : subscriptionType
        return name.lowercased()
    }

    private static func title(of limit: Body.Limit) -> String {
        if let model = limit.scope?.model?.displayName {
            return model
        }
        switch limit.group {
        case "session": return titleSession
        case "weekly": return titleWeekly
        default: return limit.kind
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The parts of the answer that hold the limits, spelled as Claude Code spells them.
    private struct Body: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let displayName: String?

                    enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                    }
                }

                let model: Model?
            }

            let kind: String
            let group: String?
            let percent: Double
            let resetsAt: String?
            let severity: String?
            let scope: Scope?

            enum CodingKeys: String, CodingKey {
                case kind
                case group
                case percent
                case resetsAt = "resets_at"
                case severity
                case scope
            }
        }

        struct RateLimits: Decodable {
            let limits: [Limit]?
        }

        let subscriptionType: String?
        let rateLimitsAvailable: Bool
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case subscriptionType = "subscription_type"
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
    }
}

/// What a configuration directory holds, as far as the code agents it may belong to go.
public enum AgentDirectoryContents: Equatable, Sendable {
    /// A harness Rookery reads the limits of keeps its configuration there.
    case harness(AgentHarness)
    /// A code agent Rookery cannot read the limits of yet keeps its configuration there.
    case unsupported(name: String)
    /// Nothing is there yet, as for a directory made for a new account to sign in to.
    case empty
    /// Something else is there.
    case unknown

    private static let listClaudeCodeMarkers = [".claude.json", "settings.json", "projects", "plugins"]
    private static let listCodexMarkers = ["config.toml", "auth.json"]
    private static let codexName = "Codex"

    /// Tell what a directory holds from the files each code agent keeps there.
    ///
    /// - Parameter path: the directory, a leading "~" standing for the home directory
    /// - Returns: what the directory holds
    public static func inspect(_ path: String) -> AgentDirectoryContents {
        let directory = NSString(string: path).expandingTildeInPath
        let setNames = Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        if listCodexMarkers.allSatisfy(setNames.contains) {
            return .unsupported(name: codexName)
        }
        if listClaudeCodeMarkers.contains(where: setNames.contains) {
            return .harness(.claudeCode)
        }
        return setNames.allSatisfy { $0.hasPrefix(".") } ? .empty : .unknown
    }
}
