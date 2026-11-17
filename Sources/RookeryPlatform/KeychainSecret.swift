import Foundation
import Security

/// A failure reading or writing the keychain.
public enum KeychainError: Error, CustomStringConvertible, Sendable {
    case failed(OSStatus, operation: String)

    public var description: String {
        switch self {
        case .failed(let status, let operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "can't \(operation) the keychain: \(message)"
        }
    }
}

/// Somewhere one secret is kept.
public protocol SecretStore: Sendable {
    /// The secret, or nil when none is kept.
    func read() throws -> String?
    /// Keep a secret, replacing the one kept; an empty one removes it.
    func write(_ secret: String) throws
}

/// One secret Rookery keeps in the user's login keychain, as a generic password under the app's service.
public struct KeychainSecret: SecretStore {
    public static let service = "io.github.zobinhuang.rookery"

    public let account: String

    public init(account: String) {
        self.account = account
    }

    /// The secret, or nil when none is kept.
    ///
    /// - Throws: `KeychainError`
    public func read() throws -> String? {
        var result: CFTypeRef?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.failed(status, operation: "read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keep a secret, replacing the one kept; an empty one removes it.
    ///
    /// - Throws: `KeychainError`
    public func write(_ secret: String) throws {
        guard !secret.isEmpty else {
            try delete()
            return
        }
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.failed(updateStatus, operation: "update")
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.failed(addStatus, operation: "write to")
        }
    }

    /// Remove the secret, if one is kept.
    ///
    /// - Throws: `KeychainError`
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status, operation: "delete from")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// One secret Rookery keeps in a file of its data directory that only the user may read or write, as rook
/// keeps its token. The keychain asks again each time an app signed by a self-made certificate is rebuilt,
/// and a prompt left unanswered left the app unconnected; a file does not, and the user's account is what
/// guards both.
public struct FileSecret: SecretStore {
    private static let fileMode = 0o600

    public let url: URL
    /// Where the secret was kept before, read once when the file does not exist yet, then moved here.
    public let formerStore: (any SecretStore)?

    public init(url: URL, formerStore: (any SecretStore)? = nil) {
        self.url = url
        self.formerStore = formerStore
    }

    public func read() throws -> String? {
        if let data = try? Data(contentsOf: url) {
            let secret = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return secret.isEmpty ? nil : secret
        }
        guard let former = try formerStore?.read(), !former.isEmpty else {
            return nil
        }
        try write(former)
        return former
    }

    public func write(_ secret: String) throws {
        if secret.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: Self.fileMode])
        }
        try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: url.path)
        try Data(secret.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: url.path)
    }
}
