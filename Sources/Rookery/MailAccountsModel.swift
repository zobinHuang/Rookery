import AppKit
import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// The owner's mail and calendar accounts, which live on roost and which only the owner's token reaches:
/// that token, kept in this Mac's keychain; the apps registered with Google and Microsoft; and signing in
/// to an account in the browser, whose code roost exchanges and keeps.
@MainActor
@Observable
final class MailAccountsModel {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "accounts")
    /// Where the app keeps roost's owner token.
    static let keychainOwnerToken = KeychainSecret(account: "roost-owner-token")
    private static let signInTimeout: Duration = .seconds(300)
    private static let callbackPath = "/callback"

    private(set) var listProviderApps: [MailProviderApp] = []
    private(set) var listAccounts: [MailAccount] = []
    /// The provider being signed in to, while the browser is open.
    private(set) var signingInProvider: String?
    private(set) var error: String?
    private(set) var hasOwnerToken = false

    @ObservationIgnored private unowned let fleetModel: FleetModel
    @ObservationIgnored private let tokenStore: any SecretStore
    @ObservationIgnored private var ownerToken = ""
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    init(fleetModel: FleetModel, tokenStore: any SecretStore = MailAccountsModel.keychainOwnerToken) {
        self.fleetModel = fleetModel
        self.tokenStore = tokenStore
    }

    /// Read the owner token off the main thread, then roost's apps and accounts.
    func load() async {
        let store = tokenStore
        do {
            ownerToken = try await Task.detached(priority: .userInitiated) {
                try store.read()
            }.value ?? ""
        } catch {
            Self.logger.error("cannot read the owner token: \(error, privacy: .public)")
        }
        hasOwnerToken = !ownerToken.isEmpty
        await refresh()
    }

    /// Keep the owner token in the keychain, then read roost with it.
    func saveOwnerToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try tokenStore.write(trimmed)
            ownerToken = trimmed
            hasOwnerToken = !trimmed.isEmpty
            await refresh()
        } catch {
            self.error = FleetModel.describe(error)
        }
    }

    /// Read the apps and the accounts again.
    func refresh() async {
        guard let client = ownerClient() else {
            listProviderApps = []
            listAccounts = []
            return
        }
        do {
            listProviderApps = try await client.providerApps()
            listAccounts = try await client.mailAccounts()
            error = nil
        } catch {
            self.error = FleetModel.describe(error)
        }
    }

    /// Keep the app registered with a provider on roost.
    func saveProviderApp(_ provider: String, clientId: String, clientSecret: String) async {
        guard let client = ownerClient() else {
            error = "Set the owner token first."
            return
        }
        do {
            try await client.putProviderApp(provider, clientId: clientId, clientSecret: clientSecret)
            await refresh()
        } catch {
            self.error = FleetModel.describe(error)
        }
    }

    /// The app registered with a provider, if any.
    func providerApp(_ provider: String) -> MailProviderApp? {
        listProviderApps.first { $0.provider == provider }
    }

    /// Sign in to an account of a provider: open its sign-in page in the browser, catch the code it returns
    /// to this Mac, and hand the code to roost.
    func signIn(to provider: String) {
        signInTask?.cancel()
        guard let client = ownerClient() else {
            error = "Set the owner token first."
            return
        }
        signingInProvider = provider
        error = nil
        signInTask = Task {
            defer { signingInProvider = nil }
            do {
                let receiver = try LoopbackReceiver()
                let redirectURI = "http://127.0.0.1:\(receiver.port)\(Self.callbackPath)"
                let challenge = LoginChallenge.make()
                NSWorkspace.shared.open(try await client.authorizeURL(provider, redirectURI: redirectURI, challenge: challenge))
                let query = try await receiver.receiveQuery(timeout: Self.signInTimeout)
                guard let code = challenge.code(inQuery: query) else {
                    throw LoopbackError.socketFailed("the provider sent no code back: \(query.removingPercentEncoding ?? query)")
                }
                _ = try await client.connectMailAccount(provider, code: code, challenge: challenge, redirectURI: redirectURI)
                await refresh()
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signingInProvider = nil
    }

    /// Revoke roost's access to an account and forget it.
    func disconnect(_ accountId: String) async {
        guard let client = ownerClient() else {
            return
        }
        do {
            try await client.disconnectMailAccount(accountId)
            await refresh()
        } catch {
            self.error = FleetModel.describe(error)
        }
    }

    private func ownerClient() -> RoostClient? {
        guard
            !ownerToken.isEmpty,
            let endpoint = try? RoostEndpoint(address: fleetModel.roostAddress, token: ownerToken)
        else {
            return nil
        }
        return RoostClient(endpoint: endpoint)
    }
}
