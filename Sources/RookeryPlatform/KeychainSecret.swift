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
