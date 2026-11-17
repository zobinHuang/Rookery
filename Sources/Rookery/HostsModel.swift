import Foundation
import Observation
import os
import RookeryCore
import RookeryPlatform

/// A failure of a command run on a host over ssh.
enum HostCommandError: Error, CustomStringConvertible {
    case cannotRun(String)
    case failed(status: Int32, output: String)
    case timedOut

    var description: String {
        switch self {
        case .cannotRun(let reason): "ssh could not run: \(reason)"
        case .failed(let status, let output): output.isEmpty ? "ssh exited with \(status)" : output
        case .timedOut: "the host did not answer in time"
        }
    }
}

/// How a check of a host over ssh stands.
enum HostCheck: Equatable {
    case running
    case passed(HostProbe)
    case failed(String)
}

/// How installing rook on a host stands.
enum HostInstall: Equatable {
    case running
    case finished
    case failed(String)
}

/// The hosts this Mac reaches over ssh, as `~/.ssh/config` names them, with the rook each runs and the
/// workdirs the user keeps for each; the checks and installs run on them; and the agents launched and not
/// yet reported in. Hosts and workdirs stay on this Mac, since only its ssh configuration reaches them.
@MainActor
@Observable
final class HostsModel {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    private nonisolated static let sshPath = "/usr/bin/ssh"
    private static let checkTimeout: Duration = .seconds(20)
    private static let installTimeout: Duration = .seconds(600)
    private static let listTimeout: Duration = .seconds(20)
    private nonisolated static let outputTailLines = 12
    private static let deliveryPollInterval: Duration = .seconds(2)
    /// How long a launch waits for its session to report in after its rook started it.
    private static let reportInDeadline: TimeInterval = 90
    private static let setupURL = "https://api.github.com/repos/zobinHuang/Rookery/contents/rook/setup.sh"

    private(set) var listHosts: [SSHHost] = []
    private(set) var book: HostBook
    private(set) var mapChecks: [String: HostCheck] = [:]
    private(set) var mapInstalls: [String: HostInstall] = [:]
    private(set) var listLaunches: [AgentLaunch] = []
    /// The host the launch form opens on, and its workdir, while the form is shown.
    var launchFormAlias: String?
    var launchFormWorkdirId: String?
    var isLaunchFormShown = false

    @ObservationIgnored private unowned let fleetModel: FleetModel
    @ObservationIgnored private var mapLaunchTasks: [String: Task<Void, Never>] = [:]

    init(fleetModel: FleetModel) {
        self.fleetModel = fleetModel
        book = Self.loadBook()
        reloadHosts()
    }

    /// Read the ssh configuration again.
    func reloadHosts() {
        let directory = URL.homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)
        guard let text = try? String(contentsOf: directory.appending(path: "config"), encoding: .utf8) else {
            listHosts = []
            return
        }
        listHosts = SSHConfig.hosts(in: text) { pattern in
            Self.readIncluded(pattern, relativeTo: directory)
        }
    }

    /// The names of the rooks roost knows.
    var setRookNames: Set<String> {
        Set(fleetModel.graph.listResources(of: AgentFleet.rookKind).map(\.id))
    }

    /// The rook a host runs, as matched or chosen.
    func rookName(of host: SSHHost) -> String? {
        book.rookName(of: host, among: setRookNames)
    }

    /// Whether a rook holds its link to roost open now.
    func isOnline(_ rookName: String) -> Bool {
        fleetModel.graph.resource(FleetRef(kind: AgentFleet.rookKind, id: rookName))?.mapAttributes["online"]?.boolValue == true
    }

    /// The rooks roost knows that no ssh host here runs.
    var listUnmatchedRooks: [String] {
        let setMatched = Set(listHosts.compactMap(rookName(of:)))
        return setRookNames.subtracting(setMatched).filter { $0 != AgentFleet.rookeryRookName }.sorted()
    }

    func assignRook(_ rookName: String?, to alias: String) {
        book.assignRook(rookName, to: alias)
        saveBook()
    }

    func put(_ workdir: Workdir, on alias: String) {
        book.put(workdir, on: alias)
        saveBook()
    }

    func removeWorkdir(_ workdirId: String, from alias: String) {
        book.removeWorkdir(workdirId, from: alias)
        saveBook()
    }

    /// Show the launch form, set to a host and one of its workdirs where given.
    func openLaunchForm(alias: String? = nil, workdirId: String? = nil) {
        launchFormAlias = alias
        launchFormWorkdirId = workdirId
        isLaunchFormShown = true
    }

    // MARK: - Commands over ssh

    /// Check what a host has for running agents.
    func check(_ alias: String) {
        mapChecks[alias] = .running
        Task {
            do {
                let output = try await Self.run(on: alias, command: "sh -lc \(Self.quoted(HostProbe.command))", timeout: Self.checkTimeout)
                mapChecks[alias] = .passed(HostProbe.parse(output))
            } catch {
                mapChecks[alias] = .failed(String(describing: error))
            }
        }
    }

    /// Install rook on a host under a name and connect it to the roost this Mac follows; the token goes
    /// over ssh's input, never on a command line.
    func installRook(on alias: String, name: String) {
        guard
            let endpoint = try? RoostEndpoint(address: fleetModel.roostAddress, token: fleetModel.token),
            let host = endpoint.baseURL.host()
        else {
            mapInstalls[alias] = .failed("connect Rookery to roost first")
            return
        }
        let port = endpoint.baseURL.port ?? (endpoint.baseURL.scheme == "https" ? 443 : 80)
        let tlsFlag = endpoint.baseURL.scheme == "https" ? " --tls" : ""
        let script = [
            "read -r ROOK_TOKEN",
            "export PATH=\"$HOME/.local/bin:$PATH\"",
            "curl -fsSL -H 'Accept: application/vnd.github.v3.raw' \(Self.quoted(Self.setupURL)) | bash -s -- --name \(Self.quoted(name)) < /dev/null",
            "\"$HOME/.local/bin/rook\" connect \(Self.quoted(host)) \(port) --token \"$ROOK_TOKEN\"\(tlsFlag)",
        ].joined(separator: " && ")
        mapInstalls[alias] = .running
        let token = fleetModel.token
        Task {
            do {
                _ = try await Self.run(on: alias, command: "bash -c \(Self.quoted(script))", input: token + "\n", timeout: Self.installTimeout)
                mapInstalls[alias] = .finished
                book.assignRook(name == alias ? nil : name, to: alias)
                saveBook()
                check(alias)
            } catch {
                mapInstalls[alias] = .failed(String(describing: error))
            }
        }
    }

    /// The directories in a directory on a host, and the directory itself resolved.
    ///
    /// - Parameter path: an absolute path, or empty for the home directory
    /// - Throws: `HostCommandError`
    func listDirectories(on alias: String, in path: String) async throws -> RemoteDirectory {
        let target = path.isEmpty ? "\"$HOME\"" : Self.quoted(path)
        let output = try await Self.run(on: alias, command: "cd \(target) && pwd && ls -1Ap", timeout: Self.listTimeout)
        return RemoteDirectory.parse(output)
    }

    // MARK: - Launches

    /// Start a new agent and follow it until its session reports in or its rook fails to start it.
    func launch(_ request: LaunchRequest, title: String) {
        var launch = AgentLaunch(launchId: request.launchId, title: title, rookName: request.rookName, cwd: request.cwd, startedAt: .now)
        listLaunches.append(launch)
        mapLaunchTasks[launch.id] = Task { [weak self] in
            do {
                guard let client = self?.fleetModel.client() else {
                    throw RoostError.invalidAddress("")
                }
                let delivery = try await client.launch(request)
                launch.deliveryId = delivery.id
                self?.update(launch)
                await self?.follow(launch, client: client)
            } catch {
                launch.phase = .failed(FleetModel.describe(error))
                self?.update(launch)
            }
        }
    }

    /// The agent a launch started, once it reported in.
    func agentId(of launch: AgentLaunch) -> String? {
        fleetModel.graph.listResources(of: AgentFleet.agentKind).first { resource in
            resource.mapAttributes["launch"]?.stringValue == launch.launchId
        }?.id
    }

    func dismiss(_ launchId: String) {
        mapLaunchTasks.removeValue(forKey: launchId)?.cancel()
        listLaunches.removeAll { $0.launchId == launchId }
    }

    func stop() {
        for task in mapLaunchTasks.values {
            task.cancel()
        }
        mapLaunchTasks.removeAll()
    }

    private func follow(_ launch: AgentLaunch, client: RoostClient) async {
        var launch = launch
        var deliveredAt: Date?
        while !Task.isCancelled {
            if agentId(of: launch) != nil {
                listLaunches.removeAll { $0.launchId == launch.launchId }
                mapLaunchTasks[launch.launchId] = nil
                return
            }
            if let deliveryId = launch.deliveryId, deliveredAt == nil, let delivery = try? await client.delivery(deliveryId) {
                if delivery.status == "failed" || delivery.status == "expired" {
                    launch.phase = .failed(delivery.mapDetail["reason"]?.stringValue ?? "the rook could not start it")
                    update(launch)
                    return
                }
                if delivery.status == "delivered" {
                    deliveredAt = .now
                }
            }
            if let deliveredAt, Date.now.timeIntervalSince(deliveredAt) > Self.reportInDeadline {
                launch.phase = .failed("the rook started it, but the session never reported in")
                update(launch)
                return
            }
            try? await Task.sleep(for: Self.deliveryPollInterval)
        }
    }

    private func update(_ launch: AgentLaunch) {
        guard let index = listLaunches.firstIndex(where: { $0.launchId == launch.launchId }) else {
            return
        }
        listLaunches[index] = launch
    }

    // MARK: - Running ssh

    /// Run a command on a host through ssh, never asking for a password, off the main thread; it is ended
    /// when it runs past its time.
    private static func run(on alias: String, command: String, input: String? = nil, timeout: Duration) async throws -> String {
        let timeoutSeconds = Double(timeout.components.seconds)
        return try await Task.detached(priority: .userInitiated) {
            try runBlocking(alias: alias, command: command, input: input, timeoutSeconds: timeoutSeconds)
        }.value
    }

    private nonisolated static func runBlocking(alias: String, command: String, input: String?, timeoutSeconds: Double) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: sshPath)
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", alias, command]
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        do {
            try process.run()
        } catch {
            throw HostCommandError.cannotRun(error.localizedDescription)
        }
        let startedAt = Date.now
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            if process.isRunning {
                process.terminate()
            }
        }
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try? inputPipe.fileHandleForWriting.close()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationReason == .uncaughtSignal && Date.now.timeIntervalSince(startedAt) >= timeoutSeconds {
            throw HostCommandError.timedOut
        }
        guard process.terminationStatus == 0 else {
            let tail = output.split(whereSeparator: \.isNewline).suffix(outputTailLines).joined(separator: "\n")
            throw HostCommandError.failed(status: process.terminationStatus, output: tail)
        }
        return output
    }

    /// A string as one word of a POSIX shell command.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Files

    private static func readIncluded(_ pattern: String, relativeTo directory: URL) -> String? {
        let expanded = pattern.hasPrefix("~/") ? URL.homeDirectory.path() + pattern.dropFirst(2) : pattern
        let absolute = expanded.hasPrefix("/") ? expanded : directory.appending(path: expanded).path()
        let parent = (absolute as NSString).deletingLastPathComponent
        let namePattern = (absolute as NSString).lastPathComponent
        guard let listNames = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
            return try? String(contentsOfFile: absolute, encoding: .utf8)
        }
        let listTexts = listNames.sorted().filter { name in
            fnmatch(namePattern, name, 0) == 0
        }.compactMap { name in
            try? String(contentsOfFile: (parent as NSString).appendingPathComponent(name), encoding: .utf8)
        }
        return listTexts.isEmpty ? nil : listTexts.joined(separator: "\n")
    }

    private static func loadBook() -> HostBook {
        let url = DataDirectory.file(named: HostBook.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return HostBook()
        }
        do {
            return try JSONDecoder().decode(HostBook.self, from: Data(contentsOf: url))
        } catch {
            logger.error("cannot read the hosts: \(error, privacy: .public)")
            return HostBook()
        }
    }

    private func saveBook() {
        do {
            try FileManager.default.createDirectory(at: DataDirectory.url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(book).write(to: DataDirectory.file(named: HostBook.fileName), options: .atomic)
        } catch {
            Self.logger.error("cannot save the hosts: \(error, privacy: .public)")
        }
    }
}
