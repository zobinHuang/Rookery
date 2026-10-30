import AppKit
import MuxShotsPlatform
import os

/// The applications MuxShots has put in the background (`ProcessPriority`) while all their windows are
/// hidden, so that what they do unseen costs less power. They are remembered across launches, so that one a
/// crash left in the background is put back to normal at the next launch.
@MainActor
final class ApplicationThrottle {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "throttle")
    private static let processIdsKey = "throttledProcessIds"

    private let defaults: UserDefaults
    private var setProcessIds: Set<pid_t>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        setProcessIds = Set((defaults.array(forKey: Self.processIdsKey) as? [Int32]) ?? [])
    }

    /// Put back to normal the applications an earlier run left in the background and that still run.
    func releaseLeftovers() {
        for processId in setProcessIds {
            guard NSRunningApplication(processIdentifier: processId)?.activationPolicy == .regular else {
                setProcessIds.remove(processId)
                continue
            }
            release(processId)
        }
        store()
    }

    /// Put an application and its helper processes in the background. Applying it again also covers helpers
    /// started since.
    func throttle(_ processId: pid_t) {
        do {
            try ProcessPriority.applyBackground(true, toTreeOf: processId)
        } catch {
            Self.logger.error("cannot put process \(processId) in the background: \(error, privacy: .public)")
            return
        }
        if setProcessIds.insert(processId).inserted {
            Self.logger.info("put \(Self.name(of: processId), privacy: .public) in the background")
            store()
        }
    }

    /// Put an application back to normal, if MuxShots put it in the background.
    func release(_ processId: pid_t) {
        guard setProcessIds.remove(processId) != nil else {
            return
        }
        store()
        do {
            try ProcessPriority.applyBackground(false, toTreeOf: processId)
            Self.logger.info("put \(Self.name(of: processId), privacy: .public) back to normal")
        } catch ProcessPriorityError.cannotApply(_, let errorNumber) where errorNumber == ESRCH {
            return
        } catch {
            Self.logger.error("cannot put process \(processId) back to normal: \(error, privacy: .public)")
        }
    }

    /// Put every application MuxShots put in the background back to normal, as MuxShots quits.
    func releaseAll() {
        for processId in setProcessIds {
            release(processId)
        }
    }

    private func store() {
        defaults.set(setProcessIds.sorted(), forKey: Self.processIdsKey)
    }

    private static func name(of processId: pid_t) -> String {
        NSRunningApplication(processIdentifier: processId)?.localizedName ?? String(processId)
    }
}
