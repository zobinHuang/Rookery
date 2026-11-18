import Foundation

/// A token for a git hosting service as roost lists it, so roost and the rooks reach the user's private
/// repositories: the host it opens, the user name git gives with it, and only the token's last characters.
public struct GitCredential: Decodable, Equatable, Identifiable, Sendable {
    /// The host GitHub's app tokens and personal tokens open.
    public static let githubHost = "github.com"

    public let host: String
    public let username: String
    /// The token's last characters, as `…a1b2`.
    public let tokenHint: String
    public let updatedAt: String

    public var id: String {
        host
    }

    enum CodingKeys: String, CodingKey {
        case host
        case username
        case tokenHint = "token_hint"
        case updatedAt = "updated_at"
    }
}
