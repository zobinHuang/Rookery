import AppKit
import MapKit
import RookeryCore
import RookeryPlatform
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
    /// The widest the page's one column of cards gets, so rows stay easy to scan on a wide stage.
    /// The widest the settings run, so a line stays readable on a wide stage.
    private static let contentMaxWidth: CGFloat = 1100
    private static let pagePadding: CGFloat = 44
    private static let narrowPadding: CGFloat = 24
    private static let railWidth: CGFloat = 210
    private static let compactRailWidth: CGFloat = 54
    /// The least width that names the sections in the rail rather than showing their icons alone.
    private static let railThreshold: CGFloat = 760
    /// The width of a row's name, the column its control starts after.
    static let labelWidth: CGFloat = 240
    private static let fieldWidth: CGFloat = 200
    /// The corner radius of a card of settings.

    @Bindable var preferences: Preferences
    let recorder: ShortcutRecorder
    let agentUsageMonitor: AgentUsageMonitor
    let fleetModel: FleetModel
    /// Closes the settings, for the close button; nil in the settings window, which has its own.
    var onClose: (() -> Void)?
    /// What the Mail and Calendars section shows in place of asking the Mac, for rendering the page offscreen
    /// without scripting Mail.
    var shownMailAccess: MailAccess?
    @State private var isLaunchingAtLogin = LoginItem.isEnabled
    @State private var citySearch = WorldClockCitySearch()
    @State private var clockSearchError: String?
    @State private var loginItemError: String?
    @State private var roostAddressDraft = ""
    @State private var roostTokenDraft = ""
    @State private var roostTestResult: String?
    @State private var isTestingRoost = false
    @State private var roostError: String?
    @State private var mailAccess: MailAccess?
    @State private var isRailCompact = false
    @State private var selectedPane = SettingsPane.general
    @Namespace private var railNamespace
    @State private var mailError: String?
    /// The calendars Rookery may use that take events, offered as the default calendar.
    @State private var listWritableCalendars: [CalendarSummary] = []
    @State private var isPickingCalendar = false

    /// An AppKit view hosting the settings, for the settings window.
    static func makeHostingView(
        preferences: Preferences,
        recorder: ShortcutRecorder,
        agentUsageMonitor: AgentUsageMonitor,
        fleetModel: FleetModel
    ) -> NSView {
        NSHostingView(rootView: SettingsView(
            preferences: preferences,
            recorder: recorder,
            agentUsageMonitor: agentUsageMonitor,
            fleetModel: fleetModel
        )
            .frame(width: 560, height: 680))
    }

    var body: some View {
        let railThreshold = Self.railThreshold
        return HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(StageColors.separator)
                .frame(width: 1)
            page
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < railThreshold
        } action: { isNarrow in
            isRailCompact = isNarrow
        }
        .background(onClose == nil ? StageColors.window : .clear)
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .environment(\.chosenTheme, preferences.theme)
        .environment(\.people, fleetModel.people)
        .buttonStyle(StageButtonStyle())
    }

    /// The sections down the left, the one shown lit; on a narrow stage, their icons alone.
    private var rail: some View {
        VStack(alignment: isRailCompact ? .center : .leading, spacing: 2) {
            if !isRailCompact {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
            }
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                railItem(pane)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, isRailCompact ? 20 : 26)
        .padding(.horizontal, isRailCompact ? 8 : 10)
        .frame(width: isRailCompact ? Self.compactRailWidth : Self.railWidth)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: selectedPane)
    }

    private func railItem(_ pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 9) {
                RookeryIconView(pane.symbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
                    .frame(width: 18)
                if !isRailCompact {
                    Text(pane.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.selectedRow)
                        .strokeBorder(StageColors.contrastActiveBorder)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "pane", in: railNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isRailCompact ? pane.title : "")
    }

    /// The section chosen in the rail, alone.
    private var page: some View {
        ScrollView {
            paneContent
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, isRailCompact ? Self.narrowPadding : Self.pagePadding)
                .padding(.top, isRailCompact ? 20 : 26)
                .padding(.bottom, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selectedPane)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: selectedPane)
        .scrollIndicators(.automatic)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                SettingsCloseButton(action: onClose)
                    .padding(.top, 22)
                    .padding(.trailing, 24)
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general: general
        case .roost: roost
        case .mail: mailSettings
        case .calendars: calendarSettings
        case .people: PeopleSettingsSection(people: fleetModel.people)
        case .codeAgents: codeAgents
        case .worldClock: worldClock
        case .screenSaver: screenSaver
        case .dragging: dragging
        case .shortcuts: shortcuts
        }
    }

    private var general: some View {
        SettingsSection(pane: .general) {
            SettingsRow(title: "Open at Login") {
                Toggle("", isOn: $isLaunchingAtLogin)
                    .onChange(of: isLaunchingAtLogin) { _, isEnabled in
                        applyLoginItem(isEnabled)
                    }
            }
            if let loginItemError {
                SettingsMessage(text: loginItemError)
            }
            SettingsRow(title: "Appearance", detail: "Auto follows the Mac's light or dark look") {
                ThemePicker(theme: $preferences.theme)
            }
            SettingsRow(title: "Mixer", detail: "Sound by application and by browser tab") {
                Toggle("", isOn: $preferences.isMixerEnabled)
            }
        }
    }

    private var screenSaver: some View {
        SettingsSection(pane: .screenSaver) {
            SettingsRow(title: "Text") {
                TextField(Preferences.defaultScreenSaverText, text: $preferences.screenSaverText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.fieldWidth)
            }
            SettingsRow(title: "Text Size", detail: "\(Int(preferences.screenSaverTextSize)) pt") {
                Slider(value: $preferences.screenSaverTextSize, in: Preferences.screenSaverTextSizeRange)
                    .frame(width: Self.fieldWidth)
            }
        }
    }

    private var dragging: some View {
        SettingsSection(pane: .dragging) {
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
        SettingsSection(pane: .worldClock) {
            clockCities
        }
    }

    private var codeAgents: some View {
        SettingsSection(pane: .codeAgents) {
            ForEach($preferences.listAgentAccounts) { $account in
                AgentAccountRow(account: $account, monitor: agentUsageMonitor) {
                    preferences.listAgentAccounts.removeAll { $0.id == account.id }
                }
            }
            SettingsActionRow(title: "Add Account…", symbol: .plus, action: addAgentAccount)
        }
    }

    private var roost: some View {
        SettingsSection(pane: .roost) {
            SettingsRow(title: "Address") {
                TextField("roost.example.com:8787", text: $roostAddressDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.fieldWidth)
            }
            SettingsRow(title: "Token", detail: "kept on this Mac, for you alone") {
                SecureField("roost token", text: $roostTokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.fieldWidth)
            }
            SettingsRow(title: "Status", detail: roostStatus) {
                HStack(spacing: 8) {
                    Button {
                        testRoost()
                    } label: {
                        if isTestingRoost {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text("Test")
                        }
                    }
                    .disabled(roostAddressDraft.isEmpty || isTestingRoost)
                    Button("Connect") {
                        connectRoost()
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .disabled(roostAddressDraft.isEmpty || roostTokenDraft.isEmpty)
                }
            }
            if let roostTestResult {
                RookeryLabel(roostTestResult, icon: .bubble)
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .modifier(SettingsSeparator())
            }
            if let roostError {
                SettingsMessage(text: roostError)
            }
            SettingsRow(title: "Log Times", detail: "in Rookmaster's log") {
                StageSegmentedControl(selection: $preferences.logClock, listOptions: LogClock.allCases, title: \.title)
            }
        }
        .onAppear {
            roostAddressDraft = preferences.roostAddress
            roostTokenDraft = fleetModel.token
        }
    }

    private static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    private static let calendarsAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    /// What Rookery may read of the Mac's mail: whether it can read Mail's library, whether Mail runs to
    /// fetch new mail, and each account, personal or work, which Raven may read or not.
    private var mailSettings: some View {
        SettingsSection(pane: .mail) {
            if let access = mailAccess {
                SettingsRow(title: "Mail Library", detail: access.hasFullDiskAccess ? "readable" : "needs Full Disk Access") {
                    accessControl(isGranted: access.hasFullDiskAccess) {
                        openSystemSettings(Self.fullDiskAccessURL)
                    }
                }
                SettingsRow(title: "Mail", detail: access.isMailRunning ? "running, so new mail arrives" : "not running; new mail waits until it is") {
                    if !access.isMailRunning {
                        Button("Open Mail") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MailService.mailBundleId) {
                                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                    }
                }
                ForEach(access.listMailAccounts, id: \.id) { account in
                    mailAccountRow(account, settings: access.settings)
                }
                if let problem = access.mailProblem {
                    SettingsMessage(text: problem)
                }
            } else {
                SettingsRow(title: "Reading", detail: "what Rookery may read…") {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            if let mailError {
                SettingsMessage(text: mailError)
            }
        }
        .task {
            await reloadMail()
        }
    }

    /// What Rookery may read of the Mac's calendars: whether it may, each account's calendars, which Raven
    /// may read and propose changes to or not, and the calendar new events go on when none is named.
    private var calendarSettings: some View {
        SettingsSection(pane: .calendars) {
            if let access = mailAccess {
                SettingsRow(title: "Calendars", detail: access.calendarAuthorization == "full" ? "readable" : "needs access") {
                    accessControl(isGranted: access.calendarAuthorization == "full") {
                        if access.calendarAuthorization == "not_determined" {
                            Task {
                                _ = await fleetModel.mailService.requestCalendarAccess()
                                await reloadMail()
                            }
                        } else {
                            openSystemSettings(Self.calendarsAccessURL)
                        }
                    }
                }
                SettingsRow(title: "Default Calendar") {
                    defaultCalendarMenu(settings: access.settings)
                }
                ForEach(access.listCalendarAccounts, id: \.self) { name in
                    SettingsRow(title: name, detail: "calendars") {
                        Toggle("Raven may read", isOn: Binding(
                            get: { access.settings.isCalendarAccountAllowed(name) },
                            set: { isAllowed in
                                updateMailSettings { settings in
                                    if isAllowed {
                                        settings.setHiddenCalendarAccounts.remove(name)
                                    } else {
                                        settings.setHiddenCalendarAccounts.insert(name)
                                    }
                                }
                            }
                        ))
                        .help("Whether Raven may read these calendars and propose changes to them")
                    }
                }
            } else {
                SettingsRow(title: "Reading", detail: "what Rookery may read…") {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    /// The default calendar, which opens a list of the calendars that take events, by account, each with
    /// its color, to choose another.
    private func defaultCalendarMenu(settings: MailAccountSettings) -> some View {
        let chosen = listWritableCalendars.first { $0.id == settings.defaultCalendarId }
        return Button {
            isPickingCalendar.toggle()
        } label: {
            HStack(spacing: 6) {
                if let chosen {
                    Circle()
                        .fill(AccountColor.calendar(chosen.colorHex))
                        .frame(width: 8, height: 8)
                    Text(chosen.title)
                    Text(chosen.accountTitle)
                        .foregroundStyle(StageColors.tertiaryText)
                } else {
                    Text("None")
                        .foregroundStyle(StageColors.secondaryText)
                }
                RookeryIconView(.chevronDown)
                    .foregroundStyle(StageColors.tertiaryText)
            }
            .lineLimit(1)
        }
        .fixedSize()
        .help("The calendar Raven adds an event to when you name none")
        .popover(isPresented: $isPickingCalendar, arrowEdge: .bottom) {
            calendarChoices(chosenId: settings.defaultCalendarId)
        }
    }

    private func calendarChoices(chosenId: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            calendarChoice(title: "None", account: nil, colorHex: nil, isChosen: chosenId == nil) {
                updateMailSettings { $0.defaultCalendarId = nil }
            }
            ForEach(Array(Set(listWritableCalendars.map(\.accountTitle))).sorted(), id: \.self) { account in
                Text(account)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(StageColors.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(listWritableCalendars.filter { $0.accountTitle == account }, id: \.id) { calendar in
                    calendarChoice(title: calendar.title, account: account, colorHex: calendar.colorHex, isChosen: calendar.id == chosenId) {
                        updateMailSettings { $0.defaultCalendarId = calendar.id }
                    }
                }
            }
        }
        .padding(8)
        .frame(minWidth: 240)
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .environment(\.chosenTheme, preferences.theme)
    }

    private func calendarChoice(title: String, account: String?, colorHex: String?, isChosen: Bool, choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            isPickingCalendar = false
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(colorHex.map { AnyShapeStyle(AccountColor.calendar($0)) } ?? AnyShapeStyle(StageColor.clear))
                    .overlay {
                        Circle()
                            .strokeBorder(colorHex == nil ? AnyShapeStyle(StageColors.tertiaryText) : AnyShapeStyle(StageColor.clear))
                    }
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 12)
                if isChosen {
                    RookeryIconView(.check)
                        .foregroundStyle(StageColors.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarChoiceStyle())
        .help(account.map { "\(title), \($0)" } ?? "No default calendar")
    }

    private func mailAccountRow(_ account: MailScriptAccount, settings: MailAccountSettings) -> some View {
        let address = account.listAddresses.first ?? account.name
        return SettingsRow(title: address, detail: account.isEnabled ? account.name : "\(account.name), off in Mail") {
            HStack(spacing: 10) {
                StageSegmentedControl(
                    selection: Binding(
                        get: { settings.kind(of: address).isEmpty ? MailAccountSettings.kindPersonal : settings.kind(of: address) },
                        set: { kind in
                            updateMailSettings { $0.mapKinds[address.lowercased()] = kind }
                        }
                    ),
                    listOptions: [MailAccountSettings.kindPersonal, MailAccountSettings.kindWork],
                    title: { $0 == MailAccountSettings.kindWork ? "Work" : "Personal" },
                    isSmall: true
                )
                Toggle("Raven may read", isOn: Binding(
                    get: { settings.isMailAllowed(address) },
                    set: { isAllowed in
                        updateMailSettings { settings in
                            if isAllowed {
                                settings.setHiddenMail.remove(address.lowercased())
                            } else {
                                settings.setHiddenMail.insert(address.lowercased())
                            }
                        }
                    }
                ))
                .help("Whether Raven may read this account's mail and draft from it")
            }
        }
    }

    private func accessControl(isGranted: Bool, onGrant: @escaping () -> Void) -> some View {
        Group {
            if isGranted {
                RookeryIconView(.check)
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: onGrant)
            }
        }
    }

    private func openSystemSettings(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadMail() async {
        listWritableCalendars = ((try? await fleetModel.mailSource.allowedCalendars()) ?? []).filter(\.isWritable)
        if let shownMailAccess {
            mailAccess = shownMailAccess
            return
        }
        mailAccess = await fleetModel.mailService.access()
    }

    private func updateMailSettings(_ change: (inout MailAccountSettings) -> Void) {
        guard var access = mailAccess else {
            return
        }
        change(&access.settings)
        mailAccess = access
        let settings = access.settings
        Task {
            do {
                try await fleetModel.mailService.save(settings)
                mailError = nil
            } catch {
                mailError = "Could not keep the account settings: \(error.localizedDescription)"
            }
        }
    }

    private var roostStatus: String {
        switch fleetModel.connection {
        case .notConfigured: "Not connected"
        case .connecting: "Connecting…"
        case .online: "Online\(fleetModel.serverVersion.map { ", roost \($0)" } ?? "")"
        case .offline(let reason): "Offline: \(reason)"
        }
    }

    private func testRoost() {
        isTestingRoost = true
        roostTestResult = nil
        Task {
            roostTestResult = await fleetModel.test(address: roostAddressDraft, token: roostTokenDraft)
            isTestingRoost = false
        }
    }

    private func connectRoost() {
        do {
            try fleetModel.connect(address: roostAddressDraft, token: roostTokenDraft)
            roostError = nil
        } catch {
            roostError = FleetModel.describe(error)
        }
    }

    private var shortcuts: some View {
        SettingsSection(pane: .shortcuts) {
            SettingsRow(title: "Switch to Group") {
                Picker("", selection: groupModifiersBinding) {
                    ForEach(Self.listGroupModifierChoices, id: \.rawValue) { modifiers in
                        Text("\(Hotkey.symbols(for: modifiers))1 … \(Hotkey.symbols(for: modifiers))9")
                            .tag(modifiers.rawValue)
                    }
                }
                .fixedSize()
            }
            recorderRow("Launcher", hotkey: preferences.launcherHotkey) { preferences.launcherHotkey = $0 }
            recorderRow("Open or Close Stage", hotkey: preferences.stageHotkey) { preferences.stageHotkey = $0 }
            recorderRow("Fold or Open Right Sidebar", hotkey: preferences.rightSidebarHotkey) { preferences.rightSidebarHotkey = $0 }
            recorderRow("Show All Windows", hotkey: preferences.showAllHotkey) { preferences.showAllHotkey = $0 }
            recorderRow("Group Switcher", hotkey: preferences.switcherHotkey) { preferences.switcherHotkey = $0 }
            recorderRow("Next Window in Group", hotkey: preferences.cycleHotkey) { preferences.cycleHotkey = $0 }
            recorderRow("Previous Tab", hotkey: preferences.previousTabHotkey) { preferences.previousTabHotkey = $0 }
            recorderRow("Next Tab", hotkey: preferences.nextTabHotkey) { preferences.nextTabHotkey = $0 }
            SettingsActionRow(title: "Restore Default Shortcuts", symbol: .undo) {
                preferences.restoreDefaultShortcuts()
            }
        }
    }

    @ViewBuilder
    private var clockCities: some View {
        ForEach(preferences.listClockCities) { city in
            SettingsRow(title: city.name, detail: city.timeZoneId) {
                SettingsIconButton(symbol: .minus, help: "Remove \(city.name)") {
                    preferences.listClockCities.removeAll { $0 == city }
                }
            }
        }
        HStack(spacing: 8) {
            RookeryIconView(.search)
                .foregroundStyle(StageColors.secondaryText)
            TextField("Add City or Time Zone", text: $citySearch.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .frame(minHeight: 40)
        .modifier(SettingsSeparator())
        ForEach(WorldClock.searchTimeZoneCities(matching: citySearch.query).filter {
            !preferences.listClockCities.contains($0)
        }) { city in
            SettingsResultRow(title: city.name, detail: city.timeZoneId, symbol: .plus) {
                addClockCity(city)
            }
        }
        ForEach(listTimeZoneResults) { city in
            SettingsResultRow(title: city.name, detail: city.timeZoneId, symbol: .clock) {
                addClockCity(city)
            }
        }
        ForEach(Array(citySearch.listCompletions.enumerated()), id: \.offset) { _, completion in
            SettingsResultRow(title: completion.title, detail: completion.subtitle, symbol: .pin) {
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
            showAccountAlert("Rookery can't read \(name)'s limits yet", detail: "\(path) belongs to \(name).")
            return
        case .unknown:
            showAccountAlert(
                "This isn't a code agent's configuration directory",
                detail: "Rookery reads \(AgentHarness.allCases.map(\.title).joined(separator: ", ")); \(path) holds none of them."
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
            .buttonStyle(StageButtonStyle())
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

/// One of the settings' sections, shown alone when chosen in the rail: its name large over its rows, with
/// nothing boxing them in.
private struct SettingsSection<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RookeryIconView(pane.symbol, scale: 1.25)
                    .foregroundStyle(StageColors.secondaryText)
                Text(pane.title)
                    .font(.system(size: 19, weight: .bold))
                Spacer(minLength: 0)
            }
            Text(pane.summary)
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .padding(.top, 4)
                .padding(.bottom, 14)
            VStack(spacing: 0) {
                content
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: SettingsSeparator.height)
            }
        }
    }
}

/// The sections of the settings, in the order they run and the rail lists them.
enum SettingsPane: String, CaseIterable {
    case general
    case roost
    case mail
    case calendars
    case people
    case codeAgents
    case worldClock
    case screenSaver
    case dragging
    case shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .roost: "Roost"
        case .mail: "Mail"
        case .calendars: "Calendars"
        case .people: "People"
        case .codeAgents: "Code Agents"
        case .worldClock: "World Clock"
        case .screenSaver: "Screen Saver"
        case .dragging: "Dragging"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: RookeryIcon {
        switch self {
        case .general: .gear
        case .roost: .agent
        case .mail: .mail
        case .calendars: .calendar
        case .people: .person
        case .codeAgents: .gauge
        case .worldClock: .globe
        case .screenSaver: .screenSaver
        case .dragging: .hand
        case .shortcuts: .command
        }
    }

    /// What the section is for, in a line under its name.
    var summary: String {
        switch self {
        case .general: "How Rookery starts and looks, and whether it takes over sound."
        case .roost: "The server your agents report to, which Rookmaster and Raven read."
        case .mail: "What Rookery and Raven may read of the Mac's mail."
        case .calendars: "What Rookery and Raven may read of the Mac's calendars, and where new events go."
        case .people: "The people you write to and meet, to name them with @ and to know them in mail and calendars."
        case .codeAgents: "The accounts whose plan limits Token HP shows."
        case .worldClock: "The cities the footbar keeps the time of."
        case .screenSaver: "What the screen saver says."
        case .dragging: "How windows join the stage when dragged."
        case .shortcuts: "The keys that work Rookery from anywhere."
        }
    }
}

/// A setting: its name, with what it is or shows under it, in a column of their own, and its control
/// after that column, starting where every row's does. A hairline above parts it from the row before.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                label
                    .frame(width: SettingsView.labelWidth, alignment: .leading)
                control
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                label
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .frame(minHeight: 46)
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
        }
    }
}

/// A row that does something when clicked, in the accent color, lit while the pointer is over it.
private struct SettingsActionRow: View {
    let title: String
    let symbol: RookeryIcon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RookeryIconView(symbol)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .opacity(isHovered ? 0.75 : 1)
            .frame(minHeight: 40)
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
    let symbol: RookeryIcon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RookeryIconView(symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
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
    let symbol: RookeryIcon
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RookeryIconView(symbol)
                .foregroundStyle(isHovered ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.tertiaryText))
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
        RookeryLabel(text, icon: .warning)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            RookeryIconView(.close)
                .foregroundStyle(isHovered ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
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
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sameLogin = monitor.listSameLoginAccounts(as: account).first {
                    RookeryIconView(.link)
                        .foregroundStyle(StageColors.secondaryText)
                        .help("Same Account as \(sameLogin.configDirectory ?? "~/.claude")")
                }
                Spacer(minLength: 8)
                status
                SettingsIconButton(symbol: .minus, help: "Remove Account", action: onRemove)
            }
            signInCommand
        }
        .padding(.vertical, 11)
        .modifier(SettingsSeparator())
    }

    @ViewBuilder
    private var status: some View {
        if let signedInAs = monitor.mapUsage[account.id]?.signedInAs {
            RookeryLabel(signedInAs, icon: .check)
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .lineLimit(1)
        } else if let error = monitor.mapErrors[account.id] {
            RookeryLabel("Not Signed In", icon: .warning)
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
                .foregroundStyle(StageColors.secondaryText)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StageColors.idleTab, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            SettingsIconButton(symbol: isCopied ? .check : .copy, help: "Copy Sign-In Command") {
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
            SettingsIconButton(symbol: .refresh, help: "Check Again", action: monitor.refreshNow)
        }
    }
}

/// A row of the default calendar's list: lit under the pointer, as a menu's items are.
private struct CalendarChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalendarChoiceBody(configuration: configuration)
    }
}

private struct CalendarChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                isHovered || configuration.isPressed ? AnyShapeStyle(StageColors.hoveredRow) : AnyShapeStyle(StageColor.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { isHovered = $0 }
    }
}

/// The people the user sets down: each with their mark, name and addresses, opened in place to change
/// them, and a row to add one.
private struct PeopleSettingsSection: View {
    let people: PeopleStore

    @State private var editingId: String?
    /// The person just added, removed again if the user cancels before saving.
    @State private var newPersonId: String?

    var body: some View {
        SettingsSection(pane: .people) {
            ForEach(people.listPeople) { person in
                if editingId == person.id {
                    PersonEditor(people: people, person: person, isNew: newPersonId == person.id) {
                        editingId = nil
                        newPersonId = nil
                    }
                    .modifier(SettingsSeparator())
                    .transition(.opacity)
                } else {
                    personRow(person)
                }
            }
            if people.listPeople.isEmpty {
                SettingsRow(title: "No one yet", detail: "add the people you write to, to @ them with Raven") {
                    EmptyView()
                }
            }
            SettingsActionRow(title: "Add Person…", symbol: .plus) {
                let person = Person(name: "New Person", listAddresses: [])
                people.put(person)
                newPersonId = person.id
                editingId = person.id
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: editingId)
    }

    private func personRow(_ person: Person) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                PersonMark(person: person, size: 28)
                Text(person.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: SettingsView.labelWidth, alignment: .leading)
            Text(person.listAddresses.isEmpty ? "No addresses" : person.listAddresses.joined(separator: ", "))
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Edit") {
                editingId = person.id
            }
        }
        .padding(.vertical, 8)
        .modifier(SettingsSeparator())
    }
}

/// A person opened to change: their name, their addresses, one per row with one to add, and their photo;
/// saved, cancelled or the person removed.
private struct PersonEditor: View {
    let people: PeopleStore
    let person: Person
    let isNew: Bool
    let onDone: () -> Void

    @State private var name = ""
    @State private var listAddresses: [String] = []
    @State private var newAddress = ""
    @State private var problem: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PersonMark(person: people.book.person(withId: person.id) ?? person, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                    HStack(spacing: 8) {
                        Button("Choose Photo…", action: choosePhoto)
                        if people.book.person(withId: person.id)?.hasPhoto == true {
                            Button("Remove Photo") {
                                people.removePhoto(of: person.id)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Addresses")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StageColors.tertiaryText)
                ForEach(listAddresses, id: \.self) { address in
                    HStack(spacing: 8) {
                        Text(address)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            listAddresses.removeAll { $0 == address }
                        } label: {
                            RookeryIconView(.close)
                                .foregroundStyle(StageColors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this address")
                    }
                }
                TextField("Add an address and press Return", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addAddress)
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Delete", role: .destructive) {
                    people.remove(person.id)
                    onDone()
                }
                Spacer(minLength: 0)
                Button("Cancel") {
                    if isNew {
                        people.remove(person.id)
                    }
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(StageColors.hoveredRow.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 10)
        .onAppear {
            name = isNew ? "" : person.name
            listAddresses = person.listAddresses
            isNameFocused = true
        }
    }

    private func addAddress() {
        let address = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return
        }
        guard address.contains("@"), !address.contains(" ") else {
            problem = "\(address) is not a mail address"
            return
        }
        if !listAddresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            listAddresses.append(address)
        }
        newAddress = ""
        problem = nil
    }

    private func save() {
        addAddress()
        var changed = people.book.person(withId: person.id) ?? person
        changed.name = name.trimmingCharacters(in: .whitespaces)
        changed.listAddresses = listAddresses
        people.put(changed)
        onDone()
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo of \(name.isEmpty ? "this person" : name)"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            MainActor.assumeIsolated {
                do {
                    try people.takePhoto(from: url, for: person.id)
                    problem = nil
                } catch {
                    problem = String(describing: error)
                }
            }
        }
    }
}

