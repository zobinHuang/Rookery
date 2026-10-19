import Foundation
import MuxShotsCore
import MuxShotsPlatform
import Observation
import os

/// The plan limits of the code agent accounts the sidebar shows, read from their harnesses on a schedule
/// no faster than any of their services tolerate, backing off while reads fail. A reset needs no read of
/// its own: the panel shows the limit full once its reset passes, until the next read brings the new window.
@MainActor
@Observable
final class AgentUsageMonitor {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "agents")
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
        guard !listAccounts.isEmpty else {
            return
        }
        isRefreshing = true
        lastReadAt = Date()
        defer { isRefreshing = false }
        await withTaskGroup(of: (String, Result<AgentUsage, AgentUsageError>).self) { group in
            for account in listAccounts {
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
                    mapUsage[accountId] = usage
                    mapErrors[accountId] = nil
                case .failure(let error):
                    Self.logger.error("cannot read the limits of account \(accountId, privacy: .public): \(error.description, privacy: .public)")
                    mapErrors[accountId] = error.description
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
