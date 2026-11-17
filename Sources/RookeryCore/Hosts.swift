import Foundation

/// One host the Mac reaches over ssh, as an entry of `~/.ssh/config` names it.
public struct SSHHost: Equatable, Identifiable, Sendable {
    /// The name ssh takes, as `ssh <alias>`.
    public let alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?

    public var id: String {
        alias
    }

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
    }

    /// Where it is, as a person reads it: `user@host:port`, each part where the entry gives one.
    public var address: String {
        var text = hostName ?? alias
        if let user {
            text = "\(user)@\(text)"
        }
        if let port {
            text += ":\(port)"
        }
        return text
    }
}

/// The hosts an ssh configuration names, read as ssh reads it.
public enum SSHConfig {
    /// The characters that make a `Host` name a pattern rather than one host.
    private static let setPatternCharacters: Set<Character> = ["*", "?", "!"]
    private static let defaultPort = 22

    /// The concrete hosts a configuration names, in the order it names them. A pattern names no host, and
    /// a host's first value of each keyword wins, as in ssh; `Include` brings in the files it names.
    ///
    /// - Parameters:
    ///   - text: the configuration
    ///   - including: the text of the files an `Include` argument names, joined, or nil when none can be read
    /// - Returns: the hosts
    public static func hosts(in text: String, including: (String) -> String?) -> [SSHHost] {
        var listHosts: [SSHHost] = []
        var listCurrent: [String] = []
        read(text, into: &listHosts, current: &listCurrent, including: including, depth: 0)
        return listHosts
    }

    private static let includeDepthLimit = 8

    private static func read(
        _ text: String,
        into listHosts: inout [SSHHost],
        current listCurrent: inout [String],
        including: (String) -> String?,
        depth: Int
    ) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            let listWords = words(of: line)
            guard let keyword = listWords.first?.lowercased() else {
                continue
            }
            let listArguments = Array(listWords.dropFirst())
            switch keyword {
            case "host":
                listCurrent = listArguments.filter { name in
                    !name.contains(where: setPatternCharacters.contains)
                }
                for alias in listCurrent where !listHosts.contains(where: { $0.alias == alias }) {
                    listHosts.append(SSHHost(alias: alias))
                }
            case "match":
                listCurrent = []
            case "include":
                guard depth < includeDepthLimit else {
                    continue
                }
                for argument in listArguments {
                    if let included = including(argument) {
                        read(included, into: &listHosts, current: &listCurrent, including: including, depth: depth + 1)
                    }
                }
            case "hostname", "user", "port":
                guard let value = listArguments.first else {
                    continue
                }
                for alias in listCurrent {
                    guard let index = listHosts.firstIndex(where: { $0.alias == alias }) else {
                        continue
                    }
                    apply(keyword, value: value, to: &listHosts[index])
                }
            default:
                continue
            }
        }
    }

    private static func apply(_ keyword: String, value: String, to host: inout SSHHost) {
        switch keyword {
        case "hostname" where host.hostName == nil:
            host.hostName = value
        case "user" where host.user == nil:
            host.user = value
        case "port" where host.port == nil:
            if let port = Int(value), port != defaultPort {
                host.port = port
            }
        default:
            return
        }
    }

    /// A line's words, split on spaces, tabs or the first `=`, with double quotes holding spaces.
    private static func words(of line: String) -> [String] {
        var listWords: [String] = []
        var word = ""
        var isQuoted = false
        var isKeywordDone = false
        for character in line {
            if character == "\"" {
                isQuoted.toggle()
            } else if !isQuoted && (character == " " || character == "\t" || (character == "=" && !isKeywordDone)) {
                if !word.isEmpty {
                    listWords.append(word)
                    word = ""
                    isKeywordDone = true
                }
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty {
            listWords.append(word)
        }
        return listWords
    }
}

/// A team a new agent joins, and its duty there.
public struct LaunchTeam: Codable, Equatable, Hashable, Sendable {
    public var teamId: String
    public var duty: String

    public init(teamId: String, duty: String) {
        self.teamId = teamId
        self.duty = duty
    }
}

/// A directory on a host where the user starts agents, with what an agent started there begins with.
public struct Workdir: Codable, Equatable, Identifiable, Sendable {
    public static let harnessClaude = "claude"
    public static let harnessCodex = "codex"
    public static let listHarnesses = [harnessClaude, harnessCodex]

    public let id: String
    public var name: String
    /// The directory, an absolute path on the host.
    public var path: String
    /// `claude` or `codex`.
    public var harness: String
    public var playbookId: String?
    public var listSkillIds: [String]
    public var role: String
    public var listTeams: [LaunchTeam]

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        harness: String = Workdir.harnessClaude,
        playbookId: String? = nil,
        listSkillIds: [String] = [],
        role: String = "",
        listTeams: [LaunchTeam] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.harness = harness
        self.playbookId = playbookId
        self.listSkillIds = listSkillIds
        self.role = role
        self.listTeams = listTeams
    }

    /// The directory's last component, a name for it until the user gives one.
    public static func defaultName(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }
}

/// What the user keeps on this Mac for one ssh host: the rook running on it, when its name is not the
/// host's, and its workdirs.
public struct HostSettings: Codable, Equatable, Sendable {
    public var rookName: String?
    public var listWorkdirs: [Workdir]

    public init(rookName: String? = nil, listWorkdirs: [Workdir] = []) {
        self.rookName = rookName
        self.listWorkdirs = listWorkdirs
    }
}

/// Every host's settings on this Mac, by ssh alias. The hosts themselves are read from the ssh
/// configuration each time; a host it no longer names keeps its settings until it comes back.
public struct HostBook: Codable, Equatable, Sendable {
    public static let fileName = "hosts.json"

    public private(set) var mapHosts: [String: HostSettings]

    public init(mapHosts: [String: HostSettings] = [:]) {
        self.mapHosts = mapHosts
    }

    public func settings(of alias: String) -> HostSettings {
        mapHosts[alias] ?? HostSettings()
    }

    /// The rook a host runs: the one the user chose, else one named as the host or its short host name.
    ///
    /// - Parameters:
    ///   - host: the host
    ///   - setRookNames: the rooks roost knows
    /// - Returns: the rook's name, or nil when none matches
    public func rookName(of host: SSHHost, among setRookNames: Set<String>) -> String? {
        if let chosen = mapHosts[host.alias]?.rookName, !chosen.isEmpty {
            return chosen
        }
        if setRookNames.contains(host.alias) {
            return host.alias
        }
        if let short = host.hostName?.split(separator: ".").first.map(String.init), setRookNames.contains(short) {
            return short
        }
        return nil
    }

    /// Name the rook a host runs, or clear it to match by name again.
    public mutating func assignRook(_ rookName: String?, to alias: String) {
        var settings = settings(of: alias)
        settings.rookName = rookName?.isEmpty == true ? nil : rookName
        mapHosts[alias] = settings
    }

    /// Add a workdir to a host, or replace the one with its id.
    public mutating func put(_ workdir: Workdir, on alias: String) {
        var settings = settings(of: alias)
        if let index = settings.listWorkdirs.firstIndex(where: { $0.id == workdir.id }) {
            settings.listWorkdirs[index] = workdir
        } else {
            settings.listWorkdirs.append(workdir)
        }
        mapHosts[alias] = settings
    }

    public mutating func removeWorkdir(_ workdirId: String, from alias: String) {
        var settings = settings(of: alias)
        settings.listWorkdirs.removeAll { $0.id == workdirId }
        mapHosts[alias] = settings
    }
}

/// A new agent to start on a rook: where, with which harness, what it installs first, who it is, the
/// teams it joins, and its first prompt, if any. The launch id ties the session to it as it starts.
public struct LaunchRequest: Equatable, Sendable {
    private static let launchPrefix = "l-"

    public var rookName: String
    public var cwd: String
    public var harness: String
    public var prompt: String
    public var playbookId: String?
    public var listSkillIds: [String]
    public var role: String
    public var listTeams: [LaunchTeam]
    public let launchId: String

    public init(
        rookName: String,
        cwd: String,
        harness: String,
        prompt: String = "",
        playbookId: String? = nil,
        listSkillIds: [String] = [],
        role: String = "",
        listTeams: [LaunchTeam] = [],
        launchId: String = LaunchRequest.makeLaunchId()
    ) {
        self.rookName = rookName
        self.cwd = cwd
        self.harness = harness
        self.prompt = prompt
        self.playbookId = playbookId
        self.listSkillIds = listSkillIds
        self.role = role
        self.listTeams = listTeams
        self.launchId = launchId
    }

    /// A request for a workdir as the user set it up.
    public init(workdir: Workdir, rookName: String, prompt: String = "") {
        self.init(
            rookName: rookName,
            cwd: workdir.path,
            harness: workdir.harness,
            prompt: prompt,
            playbookId: workdir.playbookId,
            listSkillIds: workdir.listSkillIds,
            role: workdir.role,
            listTeams: workdir.listTeams
        )
    }

    /// A fresh launch id.
    public static func makeLaunchId() -> String {
        launchPrefix + UUID().uuidString.lowercased().prefix(12)
    }

    /// The spawn roost takes, as `POST /v1/messages`.
    public var body: [String: JSONValue] {
        var mapOptions: [String: JSONValue] = [
            "cwd": .string(cwd),
            "harness": .string(harness),
            "launch": .string(launchId),
        ]
        if let playbookId, !playbookId.isEmpty {
            mapOptions["playbook"] = .string(playbookId)
        }
        if !listSkillIds.isEmpty {
            mapOptions["skills"] = .array(listSkillIds.map(JSONValue.string))
        }
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRole.isEmpty {
            mapOptions["role"] = .string(trimmedRole)
        }
        if !listTeams.isEmpty {
            mapOptions["teams"] = .array(listTeams.map { team in
                .object(["team": .string(team.teamId), "duty": .string(team.duty)])
            })
        }
        return [
            "kind": .string("spawn"),
            "rook": .string(rookName),
            "text": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            "options": .object(mapOptions),
        ]
    }
}

/// What a host has for running agents, as a check over ssh found it: tmux, the harnesses, rook, the name
/// rook goes by there, and whether rook reports to a roost.
public struct HostProbe: Equatable, Sendable {
    /// The shell command that prints what the probe reads, a `key=value` a line, in a login shell so the
    /// harnesses installed into the user's path are found.
    public static let command = """
        export PATH="$HOME/.local/bin:$PATH"; \
        for tool in tmux claude codex; do \
        if command -v "$tool" >/dev/null 2>&1; then echo "$tool=yes"; else echo "$tool=no"; fi; done; \
        if [ -x "$HOME/.local/bin/rook-client" ]; then echo rook=yes; else echo rook=no; fi; \
        sed -n 's/.*"name"[^"]*"\\([^"]*\\)".*/rook_name=\\1/p' "${XDG_CONFIG_HOME:-$HOME/.config}/rook/config.json" 2>/dev/null | head -1; \
        if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/rook/connect.json" ]; then echo connected=yes; else echo connected=no; fi
        """
    private static let yes = "yes"

    public var hasTmux: Bool
    public var hasClaude: Bool
    public var hasCodex: Bool
    public var hasRook: Bool
    public var isConnected: Bool
    public var rookName: String?

    public init(
        hasTmux: Bool = false,
        hasClaude: Bool = false,
        hasCodex: Bool = false,
        hasRook: Bool = false,
        isConnected: Bool = false,
        rookName: String? = nil
    ) {
        self.hasTmux = hasTmux
        self.hasClaude = hasClaude
        self.hasCodex = hasCodex
        self.hasRook = hasRook
        self.isConnected = isConnected
        self.rookName = rookName
    }

    /// The probe from what its command printed; lines it does not know are skipped, as a login shell's
    /// greeting.
    public static func parse(_ output: String) -> HostProbe {
        var mapValues: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let listParts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if listParts.count == 2 {
                mapValues[listParts[0].trimmingCharacters(in: .whitespaces)] = listParts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return HostProbe(
            hasTmux: mapValues["tmux"] == yes,
            hasClaude: mapValues["claude"] == yes,
            hasCodex: mapValues["codex"] == yes,
            hasRook: mapValues["rook"] == yes,
            isConnected: mapValues["connected"] == yes,
            rookName: mapValues["rook_name"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// A new agent on its way: asked of a rook, until its session reports in with the launch's id, or the
/// rook says it could not start it.
public struct AgentLaunch: Equatable, Identifiable, Sendable {
    public enum Phase: Equatable, Sendable {
        case starting
        case failed(String)
    }

    public var id: String {
        launchId
    }

    public let launchId: String
    public let title: String
    public let rookName: String
    public let cwd: String
    public let startedAt: Date
    public var deliveryId: String?
    public var phase: Phase

    public init(launchId: String, title: String, rookName: String, cwd: String, startedAt: Date, deliveryId: String? = nil, phase: Phase = .starting) {
        self.launchId = launchId
        self.title = title
        self.rookName = rookName
        self.cwd = cwd
        self.startedAt = startedAt
        self.deliveryId = deliveryId
        self.phase = phase
    }
}

/// A directory on a host as a listing over ssh found it: its absolute path and the directories in it.
public struct RemoteDirectory: Equatable, Sendable {
    public let path: String
    public let listDirectories: [String]

    public init(path: String, listDirectories: [String]) {
        self.path = path
        self.listDirectories = listDirectories
    }

    /// The parent directory, or nil at the root.
    public var parent: String? {
        guard path != "/" else {
            return nil
        }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// A listing from `pwd && ls -1Ap`: the path on the first line, then one entry a line, a directory's
    /// ending in `/`; hidden directories come last.
    public static func parse(_ output: String) -> RemoteDirectory {
        let listLines = output.split(whereSeparator: \.isNewline).map(String.init)
        let listDirectories = listLines.dropFirst()
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
            .sorted { first, second in
                if first.hasPrefix(".") != second.hasPrefix(".") {
                    return !first.hasPrefix(".")
                }
                return first.lowercased() < second.lowercased()
            }
        return RemoteDirectory(path: listLines.first ?? "/", listDirectories: listDirectories)
    }
}
