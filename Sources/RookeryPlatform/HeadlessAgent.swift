import Foundation

/// A code agent that runs headless: Claude Code or Codex.
public enum AgentProgram: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    /// What the user knows it as.
    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Where a code agent is installed.
public enum ClaudeCodeExecutable {
    /// Where the code agents install themselves, as an app started from Finder does not see the shell's path.
    private static let listSearchDirectories = [
        "~/.local/bin",
        "~/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// A code agent's executable, Claude Code's unless another is named, or nil when it is not installed.
    public static func url(of program: AgentProgram = .claude) -> URL? {
        let listDirectories = listSearchDirectories.map { NSString(string: $0).expandingTildeInPath }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return listDirectories
            .map { URL(filePath: $0).appending(path: program.rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// A failure running a headless code agent.
public enum HeadlessAgentError: Error, CustomStringConvertible, Sendable {
    case notInstalled(AgentProgram)
    case failedToStart(AgentProgram, String)
    /// The agent exited with a status other than zero, and what it printed to its error output.
    case exited(AgentProgram, Int32, String)

    public var description: String {
        switch self {
        case .notInstalled(let program): "\(program.title) is not installed"
        case .failedToStart(let program, let reason): "\(program.title) didn't start: \(reason)"
        case .exited(let program, let status, let errors): errors.isEmpty ? "\(program.title) exited with status \(status)" : errors
        }
    }
}

/// A code agent run headless: one Claude Code or Codex process given one prompt, whose JSON output arrives
/// line by line. Cancelling the stream kills the process.
public struct HeadlessAgent: Sendable {
    /// How the process runs.
    public struct Launch: Sendable {
        public let arguments: [String]
        public let workingDirectory: URL
        /// Variables set or replaced in the app's own environment; nil removes one.
        public let mapEnvironment: [String: String?]
        /// The program to run in place of the installed code agent, or nil for it.
        public let executable: URL?
        public let program: AgentProgram

        public init(
            arguments: [String],
            workingDirectory: URL,
            mapEnvironment: [String: String?],
            executable: URL? = nil,
            program: AgentProgram = .claude
        ) {
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.mapEnvironment = mapEnvironment
            self.executable = executable
            self.program = program
        }
    }

    private static let errorTailBytes = 2000

    public let launch: Launch

    public init(launch: Launch) {
        self.launch = launch
    }

    /// Start the process.
    ///
    /// - Returns: its output, one line at a time, ending when it exits; throws `HeadlessAgentError` when
    ///   it cannot start or exits with a failure
    public func run() -> AsyncThrowingStream<Data, any Error> {
        let launch = launch
        return AsyncThrowingStream { continuation in
            guard let executable = launch.executable ?? ClaudeCodeExecutable.url(of: launch.program) else {
                continuation.finish(throwing: HeadlessAgentError.notInstalled(launch.program))
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = launch.arguments
            process.currentDirectoryURL = launch.workingDirectory
            var mapEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in launch.mapEnvironment {
                mapEnvironment[key] = value
            }
            process.environment = mapEnvironment
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            let splitter = LineSplitter { line in
                continuation.yield(line)
            }
            let errorTail = LineSplitter.Tail(limit: Self.errorTailBytes)
            output.fileHandleForReading.readabilityHandler = { handle in
                splitter.append(handle.availableData)
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                errorTail.append(handle.availableData)
            }
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                splitter.append(output.fileHandleForReading.readDataToEndOfFile())
                splitter.finish()
                if finished.terminationStatus == 0 || finished.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: HeadlessAgentError.exited(launch.program, finished.terminationStatus, errorTail.text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: HeadlessAgentError.failedToStart(launch.program, error.localizedDescription))
                return
            }
            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

/// Cuts a stream of bytes into lines as they arrive.
// The buffer is guarded by the lock: the pipe's handler appends on its own queue, and the termination
// handler flushes on another.
final class LineSplitter: @unchecked Sendable {
    /// The last bytes of a stream, for an error message.
    // The buffer is guarded by the lock, for the same reason.
    final class Tail: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var buffer = Data()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.lock()
            buffer.append(chunk)
            if buffer.count > limit {
                buffer = buffer.suffix(limit)
            }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (Data) -> Void

    init(onLine: @escaping @Sendable (Data) -> Void) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var listLines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            listLines.append(Data(buffer[buffer.startIndex..<newlineIndex]))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        lock.unlock()
        for line in listLines where !line.isEmpty {
            onLine(line)
        }
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty {
            onLine(rest)
        }
    }
}
