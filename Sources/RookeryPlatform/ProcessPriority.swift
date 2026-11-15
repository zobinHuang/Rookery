import Darwin

/// A failure to change how the scheduler treats a process.
public enum ProcessPriorityError: Error {
    case cannotApply(processId: pid_t, errno: Int32)
}

/// How the scheduler treats a process: normally, or in the background, where macOS runs it on efficiency
/// cores only, at the lowest priority, with its disk and network use throttled. A process in the background
/// goes on running, so an application there still receives messages, only more slowly and on less power.
public enum ProcessPriority {
    private static let maximumChildren = 1024

    /// Put a process and every process descended from it, such as the helpers that render a browser's or an
    /// Electron application's pages, in the background or back to normal.
    ///
    /// - Parameters:
    ///   - isBackground: whether to put the processes in the background rather than back to normal
    ///   - processId: the process at the root of the tree
    /// - Throws: `ProcessPriorityError.cannotApply` if the root process cannot be changed, as when it has exited
    public static func applyBackground(_ isBackground: Bool, toTreeOf processId: pid_t) throws {
        let value = isBackground ? PRIO_DARWIN_BG : 0
        try apply(value, to: processId)
        for descendantId in listDescendants(of: processId) {
            // A helper that exits meanwhile has nothing left to change.
            try? apply(value, to: descendantId)
        }
    }

    private static func apply(_ value: Int32, to processId: pid_t) throws {
        guard setpriority(PRIO_DARWIN_PROCESS, id_t(processId), value) == 0 else {
            throw ProcessPriorityError.cannotApply(processId: processId, errno: errno)
        }
    }

    private static func listDescendants(of processId: pid_t) -> [pid_t] {
        var listDescendantIds: [pid_t] = []
        var setSeenIds: Set<pid_t> = [processId]
        var listPendingIds = [processId]
        while let parentId = listPendingIds.popLast() {
            for childId in listChildren(of: parentId) where setSeenIds.insert(childId).inserted {
                listDescendantIds.append(childId)
                listPendingIds.append(childId)
            }
        }
        return listDescendantIds
    }

    private static func listChildren(of processId: pid_t) -> [pid_t] {
        var listChildIds = [pid_t](repeating: 0, count: maximumChildren)
        let count = listChildIds.withUnsafeMutableBytes { buffer in
            proc_listchildpids(processId, buffer.baseAddress, Int32(buffer.count))
        }
        return Array(listChildIds.prefix(max(0, Int(count))))
    }
}
