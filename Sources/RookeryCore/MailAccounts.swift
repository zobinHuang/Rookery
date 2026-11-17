import CryptoKit
import Foundation

/// The app the owner registered with a mail and calendar provider, as roost keeps it: its secret, if any,
/// is never sent back.
public struct MailProviderApp: Decodable, Equatable, Sendable {
    public static let google = "google"
    public static let microsoft = "microsoft"

    public let provider: String
    public let clientId: String
    public let hasClientSecret: Bool

    enum CodingKeys: String, CodingKey {
        case provider
        case clientId = "client_id"
        case hasClientSecret = "has_client_secret"
    }

    public init(provider: String, clientId: String, hasClientSecret: Bool) {
        self.provider = provider
        self.clientId = clientId
        self.hasClientSecret = hasClientSecret
    }
}

/// One of the owner's mail and calendar accounts, as roost holds it.
public struct MailAccount: Decodable, Equatable, Identifiable, Sendable {
    public static let statusConnected = "connected"
    public static let statusNeedsLogin = "needs_login"
    public static let kindWork = "work"

    public let id: String
    public let provider: String
    /// `personal` or `work`.
    public let kind: String
    public let email: String
    public let displayName: String
    /// `connected`, `needs_login` or `failing`.
    public let status: String
    public let error: String
    public let syncedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case kind
        case email
        case displayName = "display_name"
        case status
        case error
        case syncedAt = "synced_at"
    }

    public init(
        id: String,
        provider: String,
        kind: String,
        email: String,
        displayName: String,
        status: String,
        error: String = "",
        syncedAt: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.email = email
        self.displayName = displayName
        self.status = status
        self.error = error
        self.syncedAt = syncedAt
    }
}

/// What one sign-in to a provider carries: a PKCE verifier and its S256 challenge, and a state to check
/// the sign-in comes back with.
public struct LoginChallenge: Equatable, Sendable {
    private static let verifierBytes = 48
    private static let stateBytes = 16

    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh challenge, from the system's random source.
    public static func make() -> LoginChallenge {
        LoginChallenge(verifier: base64URL(randomData(count: verifierBytes)), state: base64URL(randomData(count: stateBytes)))
    }

    /// Bytes in base64 for a URL: `-` and `_` for `+` and `/`, no padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The code a sign-in returned, from the query of the request the browser made to the loopback address.
    ///
    /// - Parameter query: the request's query, without the `?`
    /// - Returns: the code, or nil when the state does not match or the provider sent an error instead
    public func code(inQuery query: String) -> String? {
        var components = URLComponents()
        components.percentEncodedQuery = query
        let mapItems = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        guard mapItems["state"] == state, let code = mapItems["code"], !code.isEmpty else {
            return nil
        }
        return code
    }
}
