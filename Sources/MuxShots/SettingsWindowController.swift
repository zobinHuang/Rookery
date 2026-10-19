import AppKit

/// The settings window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let recorder: ShortcutRecorder

    init(preferences: Preferences, shortcutController: ShortcutController, agentUsageMonitor: AgentUsageMonitor) {
        recorder = ShortcutRecorder(
            onBegin: { [weak shortcutController] in
                shortcutController?.suspend()
            },
            onEnd: { [weak shortcutController] in
                shortcutController?.resume()
            }
        )
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "MuxShots Settings"
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
