import AppKit
import Carbon.HIToolbox
import MuxShotsPlatform
import Observation

/// Captures the next key combination typed into the settings window.
@MainActor
@Observable
final class ShortcutRecorder {
    /// The setting being recorded, by name; nil while nothing is recorded.
    private(set) var recordingName: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let onBegin: () -> Void
    @ObservationIgnored private let onEnd: () -> Void

    /// - Parameters:
    ///   - onBegin: called as recording starts, to release the global shortcuts
    ///   - onEnd: called as recording ends, to register them again
    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    /// Record a shortcut: the next key pressed with at least one modifier, or esc to cancel.
    ///
    /// - Parameters:
    ///   - name: the setting being recorded
    ///   - onCapture: receives the recorded shortcut
    func record(_ name: String, onCapture: @escaping (Hotkey) -> Void) {
        cancel()
        recordingName = name
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                if keyCode == Int(kVK_Escape) && modifiers.isEmpty {
                    self.cancel()
                } else if !modifiers.subtracting(.shift).isEmpty {
                    self.cancel()
                    onCapture(Hotkey(keyCode: keyCode, modifiers: modifiers))
                }
            }
            return nil
        }
    }

    func cancel() {
        guard let monitor else {
            return
        }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        recordingName = nil
        onEnd()
    }
}
