import AppKit
import MapKit
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
    @State private var citySearch = WorldClockCitySearch()
    @State private var clockSearchError: String?
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
