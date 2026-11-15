import AppKit
import os
import RookeryPlatform

/// The applications an earlier build of MuxShots put in the background (`ProcessPriority`) while all their
/// windows were hidden, which are put back to normal. MuxShots no longer puts any there: their helpers starved
/// in the background band and made the whole machine lag.
@MainActor
final class ApplicationThrottle {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "throttle")
    private static let processIdsKey = "throttledProcessIds"

    private let defaults: UserDefaults
    private var setProcessIds: Set<pid_t>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        setProcessIds = Set((defaults.array(forKey: Self.processIdsKey) as? [Int32]) ?? [])
    }

    /// The applications MuxShots has put in the background.
    var setThrottledProcessIds: Set<pid_t> {
        setProcessIds
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
