import Darwin
import Foundation
import MuxShotsPlatform
import Testing

struct ProcessPriorityTests {
    static func priority(of processId: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(processId, PROC_PIDTASKINFO, 0, &info, size) == size else {
            return nil
        }
        return info.pti_priority
    }

    static func childIds(of processId: pid_t) -> [pid_t] {
        var listChildIds = [pid_t](repeating: 0, count: 16)
        let count = listChildIds.withUnsafeMutableBytes { buffer in
            proc_listchildpids(processId, buffer.baseAddress, Int32(buffer.count))
        }
        return Array(listChildIds.prefix(max(0, Int(count))))
    }

    @Test func backgroundCoversTheProcessTreeAndIsUndone() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30 & wait"]
        try shell.run()
        defer { shell.terminate() }
        var listChildIds: [pid_t] = []
        for _ in 0..<50 where listChildIds.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            listChildIds = Self.childIds(of: shell.processIdentifier)
        }
        let childId = try #require(listChildIds.first)
        defer { kill(childId, SIGTERM) }
        let normalPriority = try #require(Self.priority(of: childId))

        try ProcessPriority.applyBackground(true, toTreeOf: shell.processIdentifier)
        #expect(try #require(Self.priority(of: shell.processIdentifier)) < normalPriority)
        #expect(try #require(Self.priority(of: childId)) < normalPriority)

        try ProcessPriority.applyBackground(false, toTreeOf: shell.processIdentifier)
        #expect(Self.priority(of: shell.processIdentifier) == normalPriority)
        #expect(Self.priority(of: childId) == normalPriority)
    }

    @Test func anExitedProcessCannotBeChanged() {
        #expect(throws: ProcessPriorityError.self) {
            try ProcessPriority.applyBackground(true, toTreeOf: pid_t(Int32.max))
        }
    }
}
