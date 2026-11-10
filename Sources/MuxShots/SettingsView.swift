import AppKit
import MapKit
import MuxShotsCore
import MuxShotsPlatform
import SwiftUI

/// The settings: general options, dragging, the world clock, code agent accounts and shortcuts, as cards
/// under a title, spread over as many columns as fill the page. Shown in a stage's content area, or in a
/// window of its own when no stage is open.
struct SettingsView: View {
    /// The modifier sets offered for the group shortcuts.
    private static let listGroupModifierChoices: [NSEvent.ModifierFlags] = [
        [.control, .option],
        [.control, .command],
        [.option, .command],
        [.control, .option, .command],
        [.control, .shift],
    ]
    /// How narrow a column of cards may get before the page drops to fewer columns.
    private static let columnMinimumWidth: CGFloat = 420
    private static let columnSpacing: CGFloat = 24
    private static let pagePadding: CGFloat = 36
    private static let titleFieldWidth: CGFloat = 200
    /// The corner radius of a card of settings.
    static let cardCornerRadius: CGFloat = 12

    @Bindable var preferences: Preferences
    let recorder: ShortcutRecorder
    let agentUsageMonitor: AgentUsageMonitor
    /// Closes the settings, for the close button; nil in the settings window, which has its own.
    var onClose: (() -> Void)?
    @State private var isLaunchingAtLogin = LoginItem.isEnabled
    @State private var citySearch = WorldClockCitySearch()
    @State private var clockSearchError: String?
    @State private var loginItemError: String?
    @State private var pageWidth: CGFloat = 0

    /// An AppKit view hosting the settings, for the settings window.
    static func makeHostingView(
        preferences: Preferences,
        recorder: ShortcutRecorder,
        agentUsageMonitor: AgentUsageMonitor
    ) -> NSView {
        NSHostingView(rootView: SettingsView(preferences: preferences, recorder: recorder, agentUsageMonitor: agentUsageMonitor)
            .frame(width: 560, height: 680)
            .background(StageColors.window))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                columns
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, Self.pagePadding)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.automatic)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pageWidth = width
        }
    }

    /// The cards spread over as many columns as the page is wide enough for, each column filling its share.
    @ViewBuilder
    private var columns: some View {
        let columnCount = max(1, min(3, Int((pageWidth - Self.pagePadding * 2) / Self.columnMinimumWidth)))
        switch columnCount {
        case 1:
            column {
                general
                dragging
                worldClock
                codeAgents
                shortcuts
            }
        case 2:
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                column {
                    general
                    dragging
                    shortcuts
                }
                column {
                    worldClock
                    codeAgents
                }
            }
        default:
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                column {
                    general
                    dragging
                    shortcuts
                }
                column {
                    worldClock
                }
                column {
                    codeAgents
                }
            }
        }
    }

    private func column<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var general: some View {
        SettingsSection(title: "General", symbol: "gearshape.fill", tint: .gray) {
            SettingsRow(title: "Open at Login") {
                Toggle("", isOn: $isLaunchingAtLogin)
                    .onChange(of: isLaunchingAtLogin) { _, isEnabled in
                        applyLoginItem(isEnabled)
                    }
            }
            if let loginItemError {
                SettingsMessage(text: loginItemError)
            }
            SettingsRow(title: "Sidebar Title") {
                TextField(Preferences.hostName, text: $preferences.stageTitle)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: Self.titleFieldWidth)
            }
        }
    }

    private var dragging: some View {
        SettingsSection(title: "Dragging", symbol: "hand.point.up.left.fill", tint: .blue) {
            SettingsRow(title: "Show Groups While Dragging") {
                Toggle("", isOn: $preferences.isDropTrayEnabled)
            }
            SettingsRow(title: "Return Dropped Windows") {
                Toggle("", isOn: $preferences.isReturningDroppedWindows)
                    .disabled(!preferences.isDropTrayEnabled)
            }
        }
    }

    private var worldClock: some View {
        SettingsSection(title: "World Clock", symbol: "globe.asia.australia.fill", tint: .teal) {
            clockCities
        }
    }

    private var codeAgents: some View {
        SettingsSection(title: "Code Agents", symbol: "gauge.with.dots.needle.67percent", tint: .orange) {
            ForEach($preferences.listAgentAccounts) { $account in
                AgentAccountRow(account: $account, monitor: agentUsageMonitor) {
                    preferences.listAgentAccounts.removeAll { $0.id == account.id }
                }
            }
            SettingsActionRow(title: "Add Account…", symbol: "plus", action: addAgentAccount)
        }
    }

    private var shortcuts: some View {
        SettingsSection(title: "Shortcuts", symbol: "command", tint: .purple) {
            SettingsRow(title: "Switch to Group") {
                Picker("", selection: groupModifiersBinding) {
                    ForEach(Self.listGroupModifierChoices, id: \.rawValue) { modifiers in
                        Text("\(Hotkey.symbols(for: modifiers))1 … \(Hotkey.symbols(for: modifiers))9")
                            .tag(modifiers.rawValue)
                    }
                }
                .fixedSize()
            }
            recorderRow("Open or Close Stage", hotkey: preferences.stageHotkey) { preferences.stageHotkey = $0 }
            recorderRow("Show All Windows", hotkey: preferences.showAllHotkey) { preferences.showAllHotkey = $0 }
            recorderRow("Group Switcher", hotkey: preferences.switcherHotkey) { preferences.switcherHotkey = $0 }
            recorderRow("Next Window in Group", hotkey: preferences.cycleHotkey) { preferences.cycleHotkey = $0 }
            SettingsActionRow(title: "Restore Default Shortcuts", symbol: "arrow.uturn.backward") {
                preferences.restoreDefaultShortcuts()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold))
            Spacer()
            if let onClose {
                SettingsCloseButton(action: onClose)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var clockCities: some View {
        ForEach(preferences.listClockCities) { city in
            SettingsRow(title: city.name, detail: city.timeZoneId) {
                SettingsIconButton(symbol: "minus.circle.fill", help: "Remove \(city.name)") {
                    preferences.listClockCities.removeAll { $0 == city }
                }
            }
        }
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Add City or Time Zone", text: $citySearch.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .modifier(SettingsSeparator())
        ForEach(WorldClock.searchTimeZoneCities(matching: citySearch.query).filter {
            !preferences.listClockCities.contains($0)
        }) { city in
            SettingsResultRow(title: city.name, detail: city.timeZoneId, symbol: "plus.circle.fill") {
                addClockCity(city)
            }
        }
        ForEach(listTimeZoneResults) { city in
            SettingsResultRow(title: city.name, detail: city.timeZoneId, symbol: "clock.fill") {
                addClockCity(city)
            }
        }
        ForEach(Array(citySearch.listCompletions.enumerated()), id: \.offset) { _, completion in
            SettingsResultRow(title: completion.title, detail: completion.subtitle, symbol: "mappin.circle.fill") {
                addClockCity(from: completion)
            }
        }
        if let clockSearchError {
            SettingsMessage(text: clockSearchError)
        }
    }

    /// Zones the query names as zones, rather than as cities, not on the clock already.
    private var listTimeZoneResults: [WorldClockCity] {
        TimeZoneSearch.listMatches(for: citySearch.query)
            .map { WorldClockCity(name: $0.name, timeZoneId: $0.timeZoneId) }
            .filter { !preferences.listClockCities.contains($0) }
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
        let isRecording = recorder.recordingName == title
        return SettingsRow(title: title) {
            Button {
                if isRecording {
                    recorder.cancel()
                } else {
                    recorder.record(title, onCapture: onCapture)
                }
            } label: {
                Text(isRecording ? "Type Shortcut…" : hotkey.description)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
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

/// A titled card of settings rows, with a hairline between rows.
private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .padding(.top, -SettingsSeparator.height)
            .background(StageColors.tile)
            .clipShape(RoundedRectangle(cornerRadius: SettingsView.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsView.cardCornerRadius, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
        }
    }
}

/// A setting's name, with an optional value beside it, and its control at the trailing edge. A hairline
/// above it parts it from the row before; the card clips the first row's.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .modifier(SettingsSeparator())
    }
}

/// The hairline above a settings row.
private struct SettingsSeparator: ViewModifier {
    static let height: CGFloat = 1

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: Self.height)
                .padding(.leading, 14)
        }
    }
}

/// A row that does something when clicked, in the accent color, lit while the pointer is over it.
private struct SettingsActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(isHovered ? StageColors.hoveredRow : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .modifier(SettingsSeparator())
    }
}

/// A search result that adds itself when clicked, lit while the pointer is over it.
private struct SettingsResultRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(isHovered ? StageColors.hoveredRow : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .modifier(SettingsSeparator())
    }
}

/// A borderless symbol button that darkens while the pointer is over it.
private struct SettingsIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
    }
}

/// A failure to show under the setting it concerns.
private struct SettingsMessage: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(SettingsSeparator())
    }
}

/// The button that closes the settings shown in a stage.
private struct SettingsCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background(isHovered ? StageColors.groove : StageColors.idleTab, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .keyboardShortcut(.cancelAction)
        .help("Close Settings")
    }
}

/// One code agent account: whether the sidebar shows it, its agent and directory, who it is signed in as,
/// and the command that signs it in, to copy into a terminal.
private struct AgentAccountRow: View {
    private static let copiedFeedbackDuration = Duration.seconds(1.5)

    @Binding var account: AgentAccount
    let monitor: AgentUsageMonitor
    let onRemove: () -> Void
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: $account.isShown)
                    .help(account.isShown ? "Shown in the Sidebar" : "Hidden from the Sidebar")
                Text(account.harness.title)
                    .font(.system(size: 13, weight: .medium))
                Text(account.configDirectory ?? "~/.claude")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sameLogin = monitor.listSameLoginAccounts(as: account).first {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Same Account as \(sameLogin.configDirectory ?? "~/.claude")")
                }
                Spacer(minLength: 8)
                status
                SettingsIconButton(symbol: "minus.circle.fill", help: "Remove Account", action: onRemove)
            }
            signInCommand
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(SettingsSeparator())
    }

    @ViewBuilder
    private var status: some View {
        if let signedInAs = monitor.mapUsage[account.id]?.signedInAs {
            Label(signedInAs, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .lineLimit(1)
        } else if let error = monitor.mapErrors[account.id] {
            Label("Not Signed In", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help(error)
        } else if account.isShown {
            ProgressView()
                .controlSize(.mini)
        }
    }

    /// The command that signs the account in, with buttons to copy it and to check again once it ran.
    private var signInCommand: some View {
        let command = account.harness.signInCommand(configDirectory: account.configDirectory)
        return HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StageColors.idleTab, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            SettingsIconButton(symbol: isCopied ? "checkmark" : "doc.on.doc", help: "Copy Sign-In Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                isCopied = true
            }
            .task(id: isCopied) {
                guard isCopied, (try? await Task.sleep(for: Self.copiedFeedbackDuration)) != nil else {
                    return
                }
                isCopied = false
            }
            SettingsIconButton(symbol: "arrow.clockwise", help: "Check Again", action: monitor.refreshNow)
        }
    }
}
