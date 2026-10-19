import AppKit
import MapKit
import MuxShotsCore
import MuxShotsPlatform
import SwiftUI

/// The settings window's content: general options, dragging and shortcuts.
struct SettingsView: View {
    /// The modifier sets offered for the group shortcuts.
    private static let listGroupModifierChoices: [NSEvent.ModifierFlags] = [
        [.control, .option],
        [.control, .command],
        [.option, .command],
        [.control, .option, .command],
        [.control, .shift],
    ]

    @Bindable var preferences: Preferences
    let recorder: ShortcutRecorder
    let agentUsageMonitor: AgentUsageMonitor
    @State private var isLaunchingAtLogin = LoginItem.isEnabled
    @State private var citySearch = WorldClockCitySearch()
    @State private var clockSearchError: String?
    @State private var loginItemError: String?

    /// An AppKit view hosting the settings.
    static func makeHostingView(
        preferences: Preferences,
        recorder: ShortcutRecorder,
        agentUsageMonitor: AgentUsageMonitor
    ) -> NSView {
        NSHostingView(rootView: SettingsView(preferences: preferences, recorder: recorder, agentUsageMonitor: agentUsageMonitor))
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open MuxShots at login", isOn: $isLaunchingAtLogin)
                    .onChange(of: isLaunchingAtLogin) { _, isEnabled in
                        applyLoginItem(isEnabled)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Offer groups while dragging a window", isOn: $preferences.isDropTrayEnabled)
                Toggle("Return dropped windows to where the drag started", isOn: $preferences.isReturningDroppedWindows)
                    .disabled(!preferences.isDropTrayEnabled)
            } header: {
                Text("Dragging")
            } footer: {
                Text("With the panel open, drop windows on it; otherwise a tray appears at the top of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(preferences.listClockCities) { city in
                    HStack {
                        Text(city.name)
                        Text(city.timeZoneId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            preferences.listClockCities.removeAll { $0 == city }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(city.name)")
                    }
                }
                TextField("Add a city", text: $citySearch.query, prompt: Text("Search any city, e.g. Shenzhen or 深圳"))
                ForEach(WorldClock.searchTimeZoneCities(matching: citySearch.query).filter {
                    !preferences.listClockCities.contains($0)
                }) { city in
                    Button {
                        addClockCity(city)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text(city.name)
                            Text(city.timeZoneId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(Array(citySearch.listCompletions.enumerated()), id: \.offset) { _, completion in
                    Button {
                        addClockCity(from: completion)
                    } label: {
                        HStack {
                            Image(systemName: "mappin.circle")
                            Text(completion.title)
                            Text(completion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                if let clockSearchError {
                    Text(clockSearchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("World Clock")
            } footer: {
                Text("Shown at the bottom of the stage's sidebar, from the system clock and time zones. Cities other than those time zones are named after are found through Apple Maps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($preferences.listAgentAccounts) { $account in
                    AgentAccountRow(account: $account, monitor: agentUsageMonitor) {
                        preferences.listAgentAccounts.removeAll { $0.id == account.id }
                    }
                }
                Button("Add Account…", action: addAgentAccount)
                    .fixedSize()
            } header: {
                Text("Code Agent Usage")
            } footer: {
                Text("Shown in the sidebar as the plan's limits left, read from each harness itself. An account is a harness's configuration directory, as CLAUDE_CONFIG_DIR names it for Claude Code; leave the default for the one you sign in to normally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Show group 1–9", selection: groupModifiersBinding) {
                    ForEach(Self.listGroupModifierChoices, id: \.rawValue) { modifiers in
                        Text("\(Hotkey.symbols(for: modifiers))1 … \(Hotkey.symbols(for: modifiers))9")
                            .tag(modifiers.rawValue)
                    }
                }
                recorderRow("Open or close the stage", hotkey: preferences.stageHotkey) { preferences.stageHotkey = $0 }
                recorderRow("Show all windows", hotkey: preferences.showAllHotkey) { preferences.showAllHotkey = $0 }
                recorderRow("Group switcher", hotkey: preferences.switcherHotkey) { preferences.switcherHotkey = $0 }
                recorderRow("Next window in group", hotkey: preferences.cycleHotkey) { preferences.cycleHotkey = $0 }
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        preferences.restoreDefaultShortcuts()
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Hold the switcher's modifiers to keep choosing; add ⇧ to go backwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addClockCity(_ city: WorldClockCity) {
        preferences.listClockCities.append(city)
        citySearch.query = ""
        clockSearchError = nil
    }

    /// Add the city a place found through Apple Maps lies in, once its time zone is known.
    private func addClockCity(from completion: MKLocalSearchCompletion) {
        Task {
            do {
                guard let city = try await citySearch.city(for: completion) else {
                    clockSearchError = "No time zone is known for \(completion.title)."
                    return
                }
                if !preferences.listClockCities.contains(city) {
                    addClockCity(city)
                }
            } catch {
                clockSearchError = "Couldn't look up \(completion.title): \(error.localizedDescription)"
            }
        }
    }

    /// Add an account from the configuration directory the user picks, telling its code agent from what
    /// the directory holds; an empty directory is taken for a new Claude Code account to sign in to.
    private func addAgentAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL.homeDirectory
        panel.message = "Choose a code agent's configuration directory, or make a new one to sign a new account in to"
        panel.prompt = "Add Account"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let path = url.path.replacingOccurrences(of: URL.homeDirectory.path, with: "~")
        let harness: AgentHarness
        switch AgentDirectoryContents.inspect(path) {
        case .harness(let detected):
            harness = detected
        case .empty:
            harness = .claudeCode
        case .unsupported(let name):
            showAccountAlert("MuxShots can't read \(name)'s limits yet", detail: "\(path) belongs to \(name).")
            return
        case .unknown:
            showAccountAlert(
                "This isn't a code agent's configuration directory",
                detail: "MuxShots reads \(AgentHarness.allCases.map(\.title).joined(separator: ", ")); \(path) holds none of them."
            )
            return
        }
        let isDefault = path == "~/.claude"
        let configDirectory = isDefault ? nil : path
        guard !preferences.listAgentAccounts.contains(where: { $0.harness == harness && $0.configDirectory == configDirectory }) else {
            return
        }
        preferences.listAgentAccounts.append(AgentAccount(
            harness: harness,
            label: harness.title,
            configDirectory: configDirectory
        ))
    }

    private func showAccountAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private var groupModifiersBinding: Binding<UInt> {
        Binding(
            get: { preferences.groupModifiers.rawValue },
            set: { preferences.groupModifiers = NSEvent.ModifierFlags(rawValue: $0) }
        )
    }

    private func recorderRow(_ title: String, hotkey: Hotkey, onCapture: @escaping (Hotkey) -> Void) -> some View {
        LabeledContent(title) {
            Button {
                if recorder.recordingName == title {
                    recorder.cancel()
                } else {
                    recorder.record(title, onCapture: onCapture)
                }
            } label: {
                Text(recorder.recordingName == title ? "Type shortcut…" : hotkey.description)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recorder.recordingName == title ? .accentColor : nil)
        }
    }

    private func applyLoginItem(_ isEnabled: Bool) {
        do {
            try LoginItem.apply(isEnabled)
            loginItemError = nil
        } catch {
            loginItemError = "Could not change: \(error.localizedDescription)"
            isLaunchingAtLogin = LoginItem.isEnabled
        }
    }
}

/// One code agent account in the settings: whether the sidebar shows it, its name, who it is signed in
/// as, and the command that signs it in, to copy into a terminal.
private struct AgentAccountRow: View {
    private static let copiedFeedbackDuration = Duration.seconds(1.5)

    @Binding var account: AgentAccount
    let monitor: AgentUsageMonitor
    let onRemove: () -> Void
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $account.isShown)
                .labelsHidden()
                .help(account.isShown ? "Hide this account from the sidebar" : "Show this account in the sidebar")
            VStack(alignment: .leading, spacing: 4) {
                Text(account.harness.title)
                Text(account.configDirectory ?? "Default directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                if let sameLogin = monitor.listSameLoginAccounts(as: account).first {
                    Label(
                        "Same account as \(sameLogin.configDirectory ?? "the default"), shown once in the sidebar",
                        systemImage: "link"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                signInCommand
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this account")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let signedInAs = monitor.mapUsage[account.id]?.signedInAs {
            Label("Signed in as \(signedInAs)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let error = monitor.mapErrors[account.id] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if account.isShown {
            Label("Checking…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The command that signs the account in, with buttons to copy it and to check again once it ran.
    private var signInCommand: some View {
        let command = account.harness.signInCommand(configDirectory: account.configDirectory)
        return HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                isCopied = true
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy the command, then run it in a terminal to sign this account in")
            .task(id: isCopied) {
                guard isCopied, (try? await Task.sleep(for: Self.copiedFeedbackDuration)) != nil else {
                    return
                }
                isCopied = false
            }
            Button(action: monitor.refreshNow) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check this account again, as after signing in")
        }
    }
}
