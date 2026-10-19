import AppKit
import MuxShotsPlatform
import os

/// Owns the application's long-lived controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "app")

    private let tracker = WindowTracker()
    private let preferences = Preferences()
    private var settingsWindowController: SettingsWindowController?
    private var statusMenuController: StatusMenuController?
    private var applicationMonitor: ApplicationMonitor?
    private var workspaceController: WorkspaceController?
    private var workspacePanelController: WorkspacePanelController?
    private var controlServer: ControlServer?
    private var shortcutController: ShortcutController?
    private var stageController: StageController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                self?.stageController?.isOpen ?? false
            },
            onToggleStage: { [weak self] in
                self?.stageController?.toggle()
            },
            onShowSettings: { [weak self] in
                self?.settingsWindowController?.show()
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
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.requestAccess()
        }
    }

    /// Opening the app again, from Finder or `open`, opens the stage.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if stageController?.isOpen == false {
            stageController?.open()
        }
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
        controlServer?.stop()
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
        let stage = workspace.makeStage()
        stageController = stage
        workspace.onChange = { [weak panel, weak stage] in
            panel?.reload()
            stage?.refresh()
        }
        workspaceController = workspace
        workspacePanelController = panel
        workspace.start()
        let shortcuts = ShortcutController(workspaceController: workspace, preferences: preferences, stage: stage)
        shortcutController = shortcuts
        shortcuts.start()
        settingsWindowController = SettingsWindowController(preferences: preferences, shortcutController: shortcuts)

        do {
            let server = try ControlServer(tracker: tracker, workspaceController: workspace, stage: stage)
            controlServer = server
            server.start()
        } catch {
            Self.logger.error("cannot start control server: \(error)")
        }
    }
}
