import AppKit
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
    @State private var isLaunchingAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    /// An AppKit view hosting the settings.
    static func makeHostingView(preferences: Preferences, recorder: ShortcutRecorder) -> NSView {
        NSHostingView(rootView: SettingsView(preferences: preferences, recorder: recorder))
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
                Picker("Show group 1–9", selection: groupModifiersBinding) {
                    ForEach(Self.listGroupModifierChoices, id: \.rawValue) { modifiers in
                        Text("\(Hotkey.symbols(for: modifiers))1 … \(Hotkey.symbols(for: modifiers))9")
                            .tag(modifiers.rawValue)
                    }
                }
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
