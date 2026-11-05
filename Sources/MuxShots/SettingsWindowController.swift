import AppKit

/// The settings window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let recorder: ShortcutRecorder

    init(preferences: Preferences, recorder: ShortcutRecorder, agentUsageMonitor: AgentUsageMonitor) {
        self.recorder = recorder
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "MuxShots Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = SettingsView.makeHostingView(
            preferences: preferences,
            recorder: recorder,
            agentUsageMonitor: agentUsageMonitor
        )
        window.center()
    }

    func show() {
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }
}
