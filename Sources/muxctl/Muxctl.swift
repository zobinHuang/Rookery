import Foundation
import RookeryControl
import RookeryCore

/// Command-line client of the running MuxShots app.
@main
enum Muxctl {
    private static let usage = """
        usage: muxctl list [--json]
               muxctl watch
               muxctl manage <window-id> [group-name-or-position]
               muxctl release <window-id>
               muxctl focus|hide|show|maximize <window-id>
               muxctl switch <group-name-or-position> | --all
               muxctl stage on|off
               muxctl agents [--json]
               muxctl audio [--json]
               muxctl audio take|release|mute|unmute <bundle-id>|tab:<session>.<tab>
               muxctl audio set <bundle-id>|tab:<session>.<tab> <setting>=<value>...
               muxctl audio pip tab:<session>.<tab>
                 settings: mute=on|off volume=0...2 pan=-1...1 width=0...2 invert=none|left|right|both swap=on|off
                           eq=on|off eq<1-10>=-12...12 (\(bandList)) preset=<preset> reverb=<room> mix=0...100
                 presets: \(EqualizerPreset.allCases.map(\.rawValue).joined(separator: " "))
                 rooms: \(ReverbRoom.allCases.map(\.rawValue).joined(separator: " "))
        """
    private static let bandList = MixerTrackSettings.listEqualizerFrequencies
        .map { $0 >= 1_000 ? "\(Int($0 / 1_000))k" : "\(Int($0))" }
        .joined(separator: " ")
    private static let jsonFlag = "--json"
    private static let allFlag = "--all"
    private static let titleWidth = 60

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let listArguments = Array(CommandLine.arguments.dropFirst())
        guard let command = listArguments.first else {
            exit(withMessage: usage)
        }
        let request: ControlRequest
        switch command {
        case "list":
            request = .list
        case "watch":
            request = .watch
        case "manage", "release":
            guard let rawId = listArguments.dropFirst().first.flatMap(UInt32.init) else {
                exit(withMessage: usage)
            }
            let windowId = WindowId(rawValue: rawId)
            let groupNameOrPosition = listArguments.dropFirst(2).first
            request = command == "manage"
                ? .manage(windowId: windowId, groupNameOrPosition: groupNameOrPosition)
                : .release(windowId: windowId)
        case "switch":
            guard let argument = listArguments.dropFirst().first else {
                exit(withMessage: usage)
            }
            request = .switchGroup(nameOrPosition: argument == allFlag ? nil : argument)
        case "stage":
            guard let state = listArguments.dropFirst().first, state == "on" || state == "off" else {
                exit(withMessage: usage)
            }
            request = .stage(isOpen: state == "on")
        case "agents":
            request = .agentUsage
        case "audio":
            request = await audioRequest(Array(listArguments.dropFirst()))
        case let name where WindowAction(rawValue: name) != nil:
            guard
                let action = WindowAction(rawValue: name),
                let rawId = listArguments.dropFirst().first.flatMap(UInt32.init)
            else {
                exit(withMessage: usage)
            }
            request = .act(action: action, windowId: WindowId(rawValue: rawId))
        default:
            exit(withMessage: usage)
        }
        let isJson = listArguments.contains(jsonFlag)

        do {
            let connection = try await ControlConnection.connect(to: ControlSocket.url)
            defer { connection.cancel() }
            try await connection.send(request)
            while let message = try await connection.receive(ControlMessage.self) {
                try print(message, isJson: isJson)
            }
        } catch {
            exit(withMessage: "muxctl: \(error)")
        }
    }

    private static func print(_ message: ControlMessage, isJson: Bool) throws {
        if isJson {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Swift.print(String(decoding: try encoder.encode(message), as: UTF8.self))
            return
        }
        switch message {
        case .workspace(let listGroups, let setActiveGroupIds, let listWindows):
            let mapWindows = Dictionary(uniqueKeysWithValues: listWindows.map { ($0.windowId, $0) })
            for group in listGroups {
                let marker = setActiveGroupIds.contains(group.groupId) ? "* " : ""
                Swift.print("\(marker)\(group.name) (\(group.listMembers.count))")
                for member in group.listMembers {
                    let observedRow = mapWindows[member.windowId].map { row(for: $0, isHidden: member.isHidden, name: member.customName) }
                    Swift.print("  " + (observedRow ?? row(for: member)))
                }
            }
            Swift.print("\(listGroups.count) groups, \(listGroups.map(\.listMembers.count).reduce(0, +)) windows")
        case .change(.added(let window)):
            Swift.print("+ \(row(for: window, isHidden: false))")
        case .change(.updated(let window)):
            Swift.print("~ \(row(for: window, isHidden: false))")
        case .change(.removed(let windowId)):
            Swift.print("- \(windowId)")
        case .mixer(let listTracks, let mapLevels, let listTabs):
            for track in listTracks {
                let marker = track.isCapturing ? "* " : track.settings.isTakenOver ? "~ " : "  "
                let state = track.isPlaying ? "playing" : "silent "
                let level = mapLevels[track.bundleId].map { String(format: " level %.3f", $0) } ?? ""
                Swift.print("\(marker)\(state) \(track.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(track.bundleId)\(level)")
                if track.settings.isCaptureNeeded {
                    Swift.print("    \(summary(of: track.settings))")
                }
                if let error = track.error {
                    Swift.print("    error: \(error)")
                }
            }
            for status in listTabs {
                let target = MixerTarget.browserTab(sessionId: status.sessionId, tabId: status.tab.tabId)
                let marker = status.settings.isTakenOver ? "* " : "  "
                let title = String(status.tab.title.prefix(titleWidth))
                Swift.print("\(marker)\(status.tab.mode.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(target.description) \(String(format: "level %.3f", status.level)) \(title)")
                if status.settings.isCaptureNeeded {
                    Swift.print("    \(summary(of: status.settings))")
                }
                if let size = status.pictureSize {
                    Swift.print("    in sidebar: \(size == .zero ? "waiting for the first picture" : "\(Int(size.width))x\(Int(size.height))")")
                }
            }
            Swift.print("\(listTracks.count) tracks, \(listTracks.filter(\.isCapturing).count) captured, \(listTabs.count) browser tabs")
        case .agentUsage(let listAccounts, let nextRefreshAt):
            for status in listAccounts {
                let plan = status.usage?.plan.map { " · \($0)" } ?? ""
                Swift.print("\(status.account.label)\(plan)  (\(status.account.configDirectory ?? "default account"))")
                for limit in status.usage?.listLimits ?? [] {
                    let resets = limit.resetsAt.map { " resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                    Swift.print("  \(limit.title.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Int((limit.remainingFraction * 100).rounded()))% left\(resets)")
                }
                if let error = status.error {
                    Swift.print("  error: \(error)")
                }
            }
            Swift.print("next read: \(nextRefreshAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "not scheduled")")
        case .done:
            break
        case .failure(let failure):
            exit(withMessage: "muxctl: \(failure)")
        }
    }

    /// One table row: id, flags (Fullscreen, Minimized, On screen, Hidden by MuxShots), application, frame, title.
    private static func row(for window: WindowRecord, isHidden: Bool, name: String? = nil) -> String {
        let flags = [
            window.isFullscreen ? "F" : "-",
            window.isMinimized ? "M" : "-",
            window.isOnScreen ? "O" : "-",
            isHidden ? "H" : "-",
        ].joined()
        let frame = window.frame
        let frameText = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        return [
            String(describing: window.windowId).padding(toLength: 8, withPad: " ", startingAt: 0),
            flags,
            window.application.name.padding(toLength: 20, withPad: " ", startingAt: 0),
            frameText.padding(toLength: 22, withPad: " ", startingAt: 0),
            String((name ?? window.title).prefix(titleWidth)),
        ].joined(separator: " ")
    }

    /// A row for a managed window whose state has not been observed yet.
    private static func row(for member: ManagedWindow) -> String {
        [
            String(describing: member.windowId).padding(toLength: 8, withPad: " ", startingAt: 0),
            member.isHidden ? "???H" : "????",
            member.application.name.padding(toLength: 20, withPad: " ", startingAt: 0),
            "".padding(toLength: 22, withPad: " ", startingAt: 0),
            String(member.displayName.prefix(titleWidth)),
        ].joined(separator: " ")
    }

    // MARK: - Audio

    /// The request for an `audio` command; changing settings first reads the current ones from the app.
    private static func audioRequest(_ listArguments: [String]) async -> ControlRequest {
        guard let subcommand = listArguments.first, subcommand != jsonFlag else {
            return .mixer
        }
        guard let targetText = listArguments.dropFirst().first else {
            exit(withMessage: usage)
        }
        let target = MixerTarget(targetText)
        if subcommand == "pip" {
            guard case .browserTab(let sessionId, let tabId) = target else {
                exit(withMessage: usage)
            }
            return .mixerTogglePicture(sessionId: sessionId, tabId: tabId)
        }
        var settings = await currentSettings(of: target)
        switch subcommand {
        case "take":
            settings.isTakenOver = true
        case "release":
            settings.isTakenOver = false
        case "mute", "unmute":
            settings.isMuted = subcommand == "mute"
        case "set":
            settings.isTakenOver = true
            for assignment in listArguments.dropFirst(2) where assignment != jsonFlag {
                let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, apply(parts[1], to: parts[0], in: &settings) else {
                    exit(withMessage: "muxctl: bad setting \(assignment)\n\(usage)")
                }
            }
        default:
            exit(withMessage: usage)
        }
        return .mixerApply(target: target, settings: settings)
    }

    private static func currentSettings(of target: MixerTarget) async -> MixerTrackSettings {
        do {
            let connection = try await ControlConnection.connect(to: ControlSocket.url)
            defer { connection.cancel() }
            try await connection.send(ControlRequest.mixer)
            guard case .mixer(let listTracks, _, let listTabs) = try await connection.receive(ControlMessage.self) else {
                return MixerTrackSettings()
            }
            switch target {
            case .application(let bundleId):
                return listTracks.first { $0.bundleId == bundleId }?.settings ?? MixerTrackSettings()
            case .browserTab(let sessionId, let tabId):
                return listTabs.first { $0.sessionId == sessionId && $0.tab.tabId == tabId }?.settings ?? MixerTrackSettings()
            }
        } catch {
            exit(withMessage: "muxctl: \(error)")
        }
    }

    /// Set one setting from its text, reporting whether the text made sense.
    private static func apply(_ value: String, to key: String, in settings: inout MixerTrackSettings) -> Bool {
        let number = Float(value)
        switch key {
        case "volume":
            guard let number else { return false }
            settings.volume = number
        case "pan":
            guard let number else { return false }
            settings.pan = number
        case "width":
            guard let number else { return false }
            settings.width = number
        case "mix":
            guard let number else { return false }
            settings.reverbMix = number
        case "invert":
            guard ["none", "left", "right", "both"].contains(value) else { return false }
            settings.isLeftInverted = value == "left" || value == "both"
            settings.isRightInverted = value == "right" || value == "both"
        case "mute":
            guard value == "on" || value == "off" else { return false }
            settings.isMuted = value == "on"
        case "swap":
            guard value == "on" || value == "off" else { return false }
            settings.isSwapped = value == "on"
        case "eq":
            guard value == "on" || value == "off" else { return false }
            settings.isEqualizerEnabled = value == "on"
        case "preset":
            guard let preset = EqualizerPreset(rawValue: value) else { return false }
            settings.applyEqualizerPreset(preset)
        case "reverb":
            guard let room = ReverbRoom(rawValue: value) else { return false }
            settings.reverbRoom = room
        case let band where band.hasPrefix("eq"):
            guard
                let number,
                let index = Int(band.dropFirst(2)),
                settings.listEqualizerGains.indices.contains(index - 1)
            else {
                return false
            }
            settings.listEqualizerGains[index - 1] = number
        default:
            return false
        }
        return true
    }

    private static func summary(of settings: MixerTrackSettings) -> String {
        let invert = switch (settings.isLeftInverted, settings.isRightInverted) {
        case (true, true): "both"
        case (true, false): "left"
        case (false, true): "right"
        case (false, false): "none"
        }
        let listGains = settings.listEqualizerGains.map { String(format: "%+.0f", $0) }.joined(separator: " ")
        return [
            settings.isMuted ? "muted" : "unmuted",
            String(format: "volume %.2f", settings.volume),
            String(format: "pan %+.2f", settings.pan),
            String(format: "width %.2f", settings.width),
            "invert \(invert)",
            "swap \(settings.isSwapped ? "on" : "off")",
            "eq \(settings.isEqualizerEnabled ? settings.equalizerPreset?.rawValue ?? listGains : "off")",
            String(format: "reverb %@ %.0f%%", settings.reverbRoom.rawValue, settings.reverbMix),
        ].joined(separator: " · ")
    }

    private static func exit(withMessage message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(1)
    }
}
