import AppKit
import ApplicationServices

/// The process's Accessibility (TCC) trust, which every window query and action depends on.
public enum AccessibilityPermission {
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"
    private static let settingsPaneUrl = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    /// Whether the user has granted this process Accessibility access.
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask the system to show its Accessibility prompt, which also adds this app to the list in System Settings.
    ///
    /// - Returns: whether access is already granted
    @discardableResult
    public static func requestAccess() -> Bool {
        let options = [promptOptionKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Accessibility pane of System Settings.
    @MainActor
    public static func openSystemSettings() {
        guard let url = settingsPaneUrl else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
