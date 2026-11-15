import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// Accounts signed in to the same login, shown as one: the sidebar's unit for limits.
struct AgentAccountGroup: Identifiable {
    /// The group's accounts, in the order the settings list them.
    let listAccounts: [AgentAccount]
    let usage: AgentUsage?
    let error: String?

    var id: String {
        listAccounts.map(\.id).joined(separator: "+")
    }

    var harness: AgentHarness {
        listAccounts.first?.harness ?? .claudeCode
    }

    /// Whether the harness's default account is among the group's.
    var includesDefault: Bool {
        listAccounts.contains { $0.configDirectory == nil }
    }
}

/// The plan limits of the code agent accounts the sidebar shows, read from their harnesses on a schedule
/// no faster than any of their services tolerate, backing off while reads fail. A reset needs no read of
/// its own: the panel shows the limit full once its reset passes, until the next read brings the new window.
@MainActor
@Observable
final class AgentUsageMonitor {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    /// The pace when no shown account's harness asks for a slower one.
    private static let regularInterval: TimeInterval = 300
    /// The least time between a read and one the user asks for, so repeated clicks do not hammer the services.
    private static let manualRefreshCooldown: TimeInterval = 60
    /// The slowest the schedule backs off to while reads keep failing.
    private static let maximumBackoffInterval: TimeInterval = 1800

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let mapProviders: [AgentHarness: any AgentUsageProvider]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// What of the shown accounts their limits depend on, as last read, to tell a rename from a change
    /// worth reading again for.
    @ObservationIgnored private var listReadAccounts: [AgentAccount] = []
    /// How many reads in a row failed for every account, which lengthens the wait before the next.
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var lastReadAt: Date?
    /// Each account's limits as last read, by account id.
    private(set) var mapUsage: [String: AgentUsage] = [:]
    /// Why reading each account last failed, by account id.
    private(set) var mapErrors: [String: String] = [:]
    /// Who each account is signed in as, by account id, as last read: what tells accounts of one login apart
    /// from others, so each login is read once and shown once.
    private(set) var mapIdentities: [String: String] = [:]
    /// When the limits are read next.
    private(set) var nextRefreshAt: Date?
    private(set) var isRefreshing = false

    init(preferences: Preferences, listProviders: [any AgentUsageProvider] = [ClaudeCodeUsageProvider()]) {
        self.preferences = preferences
        mapProviders = Dictionary(uniqueKeysWithValues: listProviders.map { ($0.harness, $0) })
    }

    /// The accounts the sidebar shows, in the order the settings list them.
    var listShownAccounts: [AgentAccount] {
        preferences.listAgentAccounts.filter(\.isShown)
    }

    /// Start reading the limits on schedule.
    func start() {
        refreshNow()
    }

    /// Stop reading the limits.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        nextRefreshAt = nil
    }

    /// The shown accounts, those signed in to the same login gathered into one group, in the order the
    /// settings list them.
    var listAccountGroups: [AgentAccountGroup] {
        var listGroups: [[AgentAccount]] = []
        var mapGroupIndex: [String: Int] = [:]
        for account in listShownAccounts {
            if let identity = mapIdentities[account.id], let index = mapGroupIndex[identity] {
                listGroups[index].append(account)
                continue
            }
            if let identity = mapIdentities[account.id] {
                mapGroupIndex[identity] = listGroups.count
            }
            listGroups.append([account])
        }
        return listGroups.map { listAccounts in
            let representative = listAccounts.first { mapUsage[$0.id] != nil } ?? listAccounts[0]
            return AgentAccountGroup(
                listAccounts: listAccounts,
                usage: mapUsage[representative.id],
                error: mapErrors[representative.id]
            )
        }
    }

    /// The other shown accounts signed in to the same login as an account.
    func listSameLoginAccounts(as account: AgentAccount) -> [AgentAccount] {
        guard let identity = mapIdentities[account.id] else {
            return []
        }
        return preferences.listAgentAccounts.filter { $0.id != account.id && mapIdentities[$0.id] == identity }
    }

    /// Read the limits again if the shown accounts changed in a way that matters to them.
    func accountsDidChange() {
        if Self.limitKeys(of: listShownAccounts) != Self.limitKeys(of: listReadAccounts) {
            refreshNow()
        }
    }

    /// Read the limits now as the user asks, unless they were read a moment ago.
    func requestRefresh() {
        if let lastReadAt, Date().timeIntervalSince(lastReadAt) < Self.manualRefreshCooldown {
            return
        }
        refreshNow()
    }

    /// Read the limits now, and go on from there on schedule.
    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await refreshShownAccounts()
                let delay = nextDelay()
                nextRefreshAt = Date().addingTimeInterval(delay)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshShownAccounts() async {
        let listAccounts = listShownAccounts
        listReadAccounts = listAccounts
        let setShownIds = Set(listAccounts.map(\.id))
        mapUsage = mapUsage.filter { setShownIds.contains($0.key) }
        mapErrors = mapErrors.filter { setShownIds.contains($0.key) }
        mapIdentities = mapIdentities.filter { setShownIds.contains($0.key) }
        guard !listAccounts.isEmpty else {
            return
        }
        // One account per known login is read; the rest of its login take its answer.
        var setReadIdentities = Set<String>()
        let listAccountsToRead = listAccounts
            .sorted { lhs, rhs in lhs.configDirectory == nil && rhs.configDirectory != nil }
            .filter { account in
                guard let identity = mapIdentities[account.id] else {
                    return true
                }
                return setReadIdentities.insert(identity).inserted
            }
        isRefreshing = true
        lastReadAt = Date()
        defer { isRefreshing = false }
        await withTaskGroup(of: (String, Result<AgentUsage, AgentUsageError>).self) { group in
            for account in listAccountsToRead {
                guard let provider = mapProviders[account.harness] else {
                    continue
                }
                group.addTask {
                    do {
                        return (account.id, .success(try await provider.usage(of: account)))
                    } catch let error as AgentUsageError {
                        return (account.id, .failure(error))
                    } catch {
                        return (account.id, .failure(.harnessFailed(String(describing: error))))
                    }
                }
            }
            var isAnyRead = false
            for await (accountId, result) in group {
                switch result {
                case .success(let usage):
                    isAnyRead = true
                    let previousIdentity = mapIdentities[accountId]
                    let harness = listAccounts.first { $0.id == accountId }?.harness.rawValue ?? ""
                    let identity = usage.signedInAs.map { "\(harness):\($0.lowercased())" }
                    mapIdentities[accountId] = identity
                    mapUsage[accountId] = usage
                    mapErrors[accountId] = nil
                    if let identity, previousIdentity == nil || previousIdentity == identity {
                        for other in listAccounts where other.id != accountId && mapIdentities[other.id] == identity {
                            mapUsage[other.id] = usage
                            mapErrors[other.id] = nil
                        }
                    } else if let previousIdentity {
                        // The account signed in to another login; the rest of its old login are read on their own.
                        mapIdentities = mapIdentities.filter { $0.key == accountId || $0.value != previousIdentity }
                    }
                case .failure(let error):
                    Self.logger.error("cannot read the limits of account \(accountId, privacy: .public): \(error.description, privacy: .public)")
                    mapErrors[accountId] = error.description
                    // A login that cannot be read may have changed; its accounts are read one by one again.
                    if let identity = mapIdentities[accountId] {
                        mapIdentities = mapIdentities.filter { $0.value != identity }
                    }
                }
            }
            consecutiveFailures = isAnyRead ? 0 : consecutiveFailures + 1
        }
    }

    /// Of each account, what its limits depend on: which account of which harness it is.
    private static func limitKeys(of listAccounts: [AgentAccount]) -> [String] {
        listAccounts.map { "\($0.id)|\($0.harness.rawValue)|\($0.configDirectory ?? "")" }
    }

    /// How long until the next read: the slowest pace any shown account's harness asks for, doubled for
    /// each read in a row that failed, up to a ceiling.
    private func nextDelay() -> TimeInterval {
        let interval = listShownAccounts
            .compactMap { mapProviders[$0.harness]?.minimumInterval }
            .reduce(Self.regularInterval, max)
        let backoff = interval * pow(2, Double(min(consecutiveFailures, 4)))
        return min(backoff, max(Self.maximumBackoffInterval, interval))
    }
}
