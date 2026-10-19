import Foundation
import MuxShotsCore

/// Reads Claude Code's plan limits by asking Claude Code itself: it runs headless with its stream-json
/// control protocol, answers a `get_usage` request and exits. Claude Code signs in on its own, so
/// MuxShots never handles the account's credentials; no prompt is sent, so no model is called, and the
/// run neither saves a session nor runs the user's hooks.
public struct ClaudeCodeUsageProvider: AgentUsageProvider {
    private static let executableName = "claude"
    /// Where Claude Code installs itself, as an app started from Finder does not see the shell's path.
    private static let listSearchDirectories = [
        "~/.local/bin",
        "~/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
    private static let listArguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--setting-sources", "",
    ]
    private static let configDirectoryVariable = "CLAUDE_CONFIG_DIR"
    private static let initializeRequestId = "muxshots-initialize"
    private static let usageRequestId = "muxshots-usage"
    private static let timeout = Duration.seconds(20)

    public let harness = AgentHarness.claudeCode
    /// Claude Code refreshes its own usage at this pace, and its usage endpoint is rate limited.
    public let minimumInterval: TimeInterval = 300

    public init() {}

    public func usage(of account: AgentAccount) async throws -> AgentUsage {
        guard let executable = Self.executableUrl() else {
            throw AgentUsageError.harnessNotFound(harness)
        }
        return try await Self.askForUsage(executable: executable, configDirectory: account.configDirectory)
    }

    private static func decode(usage: Data, initialize: Data?) throws -> AgentUsage {
        do {
            return try ClaudeCodeUsageDecoder.decode(usage, initializeData: initialize, fetchedAt: Date())
        } catch ClaudeCodeUsageDecoder.DecodingError.noPlanLimits {
            throw AgentUsageError.noPlanLimits
        } catch {
            throw AgentUsageError.harnessFailed("unreadable answer: \(error)")
        }
    }

    private static func executableUrl() -> URL? {
        let listDirectories = listSearchDirectories.map { NSString(string: $0).expandingTildeInPath }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return listDirectories
            .map { URL(filePath: $0).appending(path: executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Run Claude Code until it answers the usage request, and read its answers. The requests are
    /// written and the input closed at once, so Claude Code answers and exits; a run that outlasts the
    /// timeout, or whose task is cancelled, is killed.
    private static func askForUsage(executable: URL, configDirectory: String?) async throws -> AgentUsage {
        let process = Process()
        process.executableURL = executable
        process.arguments = listArguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        if let configDirectory {
            environment[configDirectoryVariable] = NSString(string: configDirectory).expandingTildeInPath
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let collector = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try input.fileHandleForWriting.write(contentsOf: requestLines())
        try input.fileHandleForWriting.close()
        let lines = try await withTaskCancellationHandler {
            try await collector.lines(timeout: timeout) {
                kill(process.processIdentifier, SIGKILL)
            }
        } onCancel: {
            kill(process.processIdentifier, SIGKILL)
        }
        var initializeBody: Data?
        for line in lines {
            guard
                let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                message["type"] as? String == "control_response",
                let response = message["response"] as? [String: Any]
            else {
                continue
            }
            let isSuccess = response["subtype"] as? String == "success"
            switch response["request_id"] as? String {
            case initializeRequestId:
                if isSuccess, let body = response["response"] {
                    initializeBody = try JSONSerialization.data(withJSONObject: body)
                }
            case usageRequestId:
                guard isSuccess, let body = response["response"] else {
                    throw AgentUsageError.harnessFailed(response["error"] as? String ?? "usage request failed")
                }
                return try decode(usage: JSONSerialization.data(withJSONObject: body), initialize: initializeBody)
            default:
                continue
            }
        }
        let errorText = String(decoding: errors.fileHandleForReading.availableData.prefix(600), as: UTF8.self)
        throw AgentUsageError.harnessFailed(errorText.isEmpty ? "Claude Code ended without answering" : errorText)
    }

    /// The initialize and get_usage control requests, one JSON line each.
    private static func requestLines() throws -> Data {
        var data = Data()
        let listRequests: [(String, [String: Any])] = [
            (initializeRequestId, ["subtype": "initialize"]),
            (usageRequestId, ["subtype": "get_usage", "skip_behaviors": true]),
        ]
        for (requestId, request) in listRequests {
            data.append(try JSONSerialization.data(withJSONObject: [
                "type": "control_request",
                "request_id": requestId,
                "request": request,
            ]))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}

/// Claude Code's output as it arrives, until it ends.
// The buffer is guarded by the lock: the reading handler appends on its own queue while one waiter reads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isEnded = false
    private var continuation: CheckedContinuation<[Data], Error>?

    /// Take a chunk of output; an empty one means the output ended.
    func append(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            isEnded = true
        } else {
            buffer.append(chunk)
        }
        let waiter = isEnded ? continuation : nil
        if waiter != nil {
            continuation = nil
        }
        let lines = Self.split(buffer)
        lock.unlock()
        waiter?.resume(returning: lines)
    }

    /// Every line of output once it ends, or what has arrived when the timeout passes, after calling
    /// `onTimeout`.
    func lines(timeout: Duration, onTimeout: @escaping @Sendable () -> Void) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isEnded {
                let lines = Self.split(buffer)
                lock.unlock()
                continuation.resume(returning: lines)
                return
            }
            self.continuation = continuation
            lock.unlock()
            let seconds = Double(timeout.components.seconds)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                onTimeout()
                self?.finishOnTimeout()
            }
        }
    }

    private func finishOnTimeout() {
        lock.lock()
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(throwing: AgentUsageError.timedOut)
    }

    private static func split(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }
}
