import AppKit
import os
import RookeryPlatform

/// Owns the application's long-lived controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "app")

    private let tracker = WindowTracker()
    private let preferences = Preferences()
    private let mixerController = MixerController()
    private lazy var agentUsageMonitor = AgentUsageMonitor(preferences: preferences)
    private lazy var fleetModel = FleetModel(preferences: preferences)
    private lazy var identityKeeper = AgentIdentityKeeper(fleetModel: fleetModel)
    private let editingFocusReleaser = EditingFocusReleaser()
    private var settingsWindowController: SettingsWindowController?
    /// Records a new shortcut in the settings, wherever they show, with the shortcuts suspended meanwhile.
    private lazy var shortcutRecorder = ShortcutRecorder(
        onBegin: { [weak self] in
            self?.shortcutController?.suspend()
        },
        onEnd: { [weak self] in
            self?.shortcutController?.resume()
        }
    )
    private var statusMenuController: StatusMenuController?
    private var applicationMonitor: ApplicationMonitor?
    private var workspaceController: WorkspaceController?
    private var workspacePanelController: WorkspacePanelController?
    private var controlServer: ControlServer?
    private var shortcutController: ShortcutController?
    private var launcherController: LauncherController?
    private var stageCoordinator: StageCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        preferences.onThemeChange = { [weak self] in
            self?.applyTheme()
        }
        preferences.onWorldClockChange = { [weak self] in
            self?.stageCoordinator?.refresh()
        }
        let controller = StatusMenuController(
            onAccessGranted: { [weak self] in
                self?.startManaging()
            },
            onShowWorkspace: { [weak self] in
                self?.workspacePanelController?.show()
            },
            workspaceProvider: { [weak self] in
                self?.workspaceController?.workspace
            },
            isStageOpenProvider: { [weak self] in
                self?.stageCoordinator?.isAnyOpen ?? false
            },
            onToggleStage: { [weak self] in
                self?.stageCoordinator?.toggleOnCursorDisplay()
            },
            onShowSettings: { [weak self] in
                self?.showSettings()
            },
            groupModifiersProvider: { [weak self] in
                self?.preferences.groupModifiers ?? Preferences.defaultGroupModifiers
            },
            onSwitch: { [weak self] groupId in
                guard let workspaceController = self?.workspaceController else {
                    return
                }
                Task {
                    await workspaceController.switchTo(groupId)
                }
            }
        )
        statusMenuController = controller
        controller.start()
        NSApplication.shared.mainMenu = makeMainMenu()
        applyMixerEnabled()
        preferences.onMixerEnabledChange = { [weak self] in
            self?.applyMixerEnabled()
        }
        agentUsageMonitor.start()
        fleetModel.start()
        identityKeeper.start()
        editingFocusReleaser.start()
        preferences.onAgentAccountsChange = { [weak self] in
            self?.agentUsageMonitor.accountsDidChange()
        }
        ChromeNativeHost.register()
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.requestAccess()
        }
    }

    /// Opening the app again, from Finder or `open`, opens the stage.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        stageCoordinator?.openOnCursorDisplay()
        return false
    }

    /// Put hidden and staged windows back before quitting, so no window is left off screen or on the stage.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard
            let workspaceController,
            !workspaceController.workspace.listHiddenWindows.isEmpty
                || !workspaceController.workspace.listStagedWindows.isEmpty
        else {
            return .terminateNow
        }
        Task {
            await workspaceController.restoreAllWindows()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusMenuController?.stop()
        applicationMonitor?.stop()
        workspaceController?.stop()
        shortcutController?.stop()
        launcherController?.stop()
        controlServer?.stop()
        mixerController.stop()
        agentUsageMonitor.stop()
        identityKeeper.stop()
        editingFocusReleaser.stop()
        fleetModel.stop()
    }

    /// The pages the window switcher offers beside the windows: the calendar, the mail and the settings, and
    /// once Rookery follows a roost the Rookmaster console and each live agent's page, those last active
    /// first.
    private static func switcherPages(of fleetModel: FleetModel) -> [SwitcherEntry] {
        let settings = SwitcherEntry(
            id: StagePage.settings.switcherId ?? "",
            title: "Settings",
            subtitle: "Rookery",
            listBundleIds: [],
            symbolName: .gear,
            isActive: false,
            tag: "Rookery"
        )
        let calendar = SwitcherEntry(
            id: StagePage.calendar.switcherId ?? "",
            title: "Calendar",
            subtitle: "every account's events",
            listBundleIds: [],
            symbolName: .calendar,
            isActive: false,
            tag: "Rookery"
        )
        let mail = SwitcherEntry(
            id: StagePage.mail.switcherId ?? "",
            title: "Mail",
            subtitle: "every account's mail",
            listBundleIds: [],
            symbolName: .mail,
            isActive: false,
            tag: "Rookery"
        )
        guard fleetModel.client() != nil else {
            return [calendar, mail, settings]
        }
        let rookmaster = SwitcherEntry(
            id: StagePage.rookmaster.switcherId ?? "",
            title: "Rookmaster",
            subtitle: "every agent, skill, playbook and memory",
            listBundleIds: [],
            symbolName: .rookmaster,
            isActive: false,
            tag: "Rookery"
        )
        let listAgents = fleetModel.fleet.listSessions.filter { $0.state != .ended }.map { agent in
            SwitcherEntry(
                id: StagePage.agent(agent.id).switcherId ?? "",
                title: agent.displayName,
                subtitle: agent.rookName.isEmpty ? agent.state.title : "\(agent.state.title) on \(agent.rookName)",
                listBundleIds: [],
                symbolName: .agent,
                isActive: false,
                tag: "Agent"
            )
        }
        return [calendar, mail, rookmaster] + listAgents + [settings]
    }

    /// Run the mixer while the settings turn it on; stopping it gives every application its sound back.
    private func applyMixerEnabled() {
        if preferences.isMixerEnabled {
            mixerController.start()
        } else {
            mixerController.stop()
        }
    }

    /// Draw every Rookery window in the chosen theme, or the system's when none is chosen, fading the
    /// stages from one to the other.
    private func applyTheme() {
        let appearance = preferences.theme.flatMap { NSAppearance(named: $0.appearanceName) }
        guard let stageCoordinator else {
            NSApplication.shared.appearance = appearance
            return
        }
        stageCoordinator.crossfadeTheme {
            NSApplication.shared.appearance = appearance
        }
    }

    /// The menu bar Rookery shows while it is the active application.
    private func makeMainMenu() -> NSMenu {
        let applicationMenu = NSMenu(title: "Rookery")
        applicationMenu.addItem(withTitle: "About Rookery", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        applicationMenu.addItem(withTitle: "New Rookery Window", action: #selector(newStage), keyEquivalent: "n").target = self
        applicationMenu.addItem(withTitle: "Open or Close Stage Here", action: #selector(toggleStage), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Close All Stages", action: #selector(closeAllStages), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Move Stage to Next Display", action: #selector(moveStageToNextDisplay), keyEquivalent: "").target = self
        applicationMenu.addItem(withTitle: "Show Managed Windows…", action: #selector(showPanel), keyEquivalent: "").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide Rookery", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "Quit Rookery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApplication.shared.windowsMenu = windowMenu

        let mainMenu = NSMenu()
        for submenu in [applicationMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    /// Show the settings in an open stage, or in their own window when no stage is open.
    @objc private func showSettings() {
        guard stageCoordinator?.show(.settings) != true else {
            return
        }
        settingsWindowController?.show()
    }

    @objc private func newStage() {
        stageCoordinator?.openStage()
    }

    @objc private func toggleStage() {
        stageCoordinator?.toggleOnCursorDisplay()
    }

    @objc private func closeAllStages() {
        stageCoordinator?.closeAll()
    }

    @objc private func moveStageToNextDisplay() {
        stageCoordinator?.moveStageUnderCursorToNextDisplay()
    }

    @objc private func showPanel() {
        workspacePanelController?.show()
    }

    /// Start managing windows, once Accessibility access is granted.
    private func startManaging() {
        guard workspaceController == nil else {
            return
        }
        let monitor = ApplicationMonitor(tracker: tracker)
        applicationMonitor = monitor
        monitor.start()

        let workspace = WorkspaceController(tracker: tracker, preferences: preferences)
        let panel = workspace.makePanel()
        let stages = workspace.makeStageCoordinator(
            mixerController: mixerController,
            agentUsageMonitor: agentUsageMonitor,
            fleetModel: fleetModel,
            shortcutRecorder: shortcutRecorder
        )
        stageCoordinator = stages
        workspace.pageEntries = { [fleetModel] in
            Self.switcherPages(of: fleetModel)
        }
        workspace.onOpenPage = { [weak stages] page in
            stages?.show(page)
        }
        workspace.shownPage = { [weak stages] in
            stages?.shownPage
        }
        workspace.onChange = { [weak panel, weak stages] in
            panel?.reload()
            stages?.refresh()
        }
        workspace.onSwitchTarget = { [weak stages] groupId, windowId in
            stages?.noteSwitchTarget(groupId, frontWindow: windowId)
        }
        workspace.onWindowTitleChange = { [weak panel, weak stages] windowId in
            panel?.updateTitle(of: windowId)
            stages?.refreshWindowTitle(windowId)
        }
        workspace.pictureProcessIds = { [weak mixerController] in
            mixerController?.browserTabs.setPictureProcessIds ?? []
        }
        mixerController.browserTabs.pictures.onChange = { [weak workspace] in
            workspace?.picturesDidChange()
        }
        workspaceController = workspace
        workspacePanelController = panel
        workspace.start()
        let launcher = LauncherController(fleetModel: fleetModel, workspaceController: workspace, preferences: preferences)
        launcherController = launcher
        let shortcuts = ShortcutController(workspaceController: workspace, preferences: preferences, stages: stages, launcher: launcher)
        shortcutController = shortcuts
        shortcuts.start()
        settingsWindowController = SettingsWindowController(
            preferences: preferences,
            recorder: shortcutRecorder,
            agentUsageMonitor: agentUsageMonitor,
            fleetModel: fleetModel
        )
        stages.openOnCursorDisplay()

        do {
            let server = try ControlServer(
                tracker: tracker,
                workspaceController: workspace,
                stages: stages,
                mixerController: mixerController,
                agentUsageMonitor: agentUsageMonitor,
                mailService: fleetModel.mailService,
                raven: fleetModel.raven
            )
            controlServer = server
            server.start()
        } catch {
            Self.logger.error("cannot start control server: \(error)")
        }
    }
}
