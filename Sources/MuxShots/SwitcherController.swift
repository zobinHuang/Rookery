import AppKit
import Carbon.HIToolbox
import MuxShotsCore
import MuxShotsPlatform

/// A hold-to-choose switcher, for groups or windows: its shortcut opens it on the next entry, further presses
/// move the selection, releasing the held modifiers chooses and esc cancels. A quick tap chooses without
/// showing anything, like Cmd-Tab.
@MainActor
final class SwitcherController {
    private static let revealDelay = Duration.milliseconds(140)
    private static let fadeOutDelay = Duration.milliseconds(200)
    private static let panelSize = CGSize(width: 1100, height: 320)

    private let hotkeyCenter: HotkeyCenter
    private let model = SwitcherModel()
    private let panel: NSPanel
    private var isOpen = false
    private var listCancelHotkeys: [Hotkey] = []
    private var onCommit: (@MainActor (SwitcherEntry) -> Void)?
    private var revealTask: Task<Void, Never>?

    init(hotkeyCenter: HotkeyCenter) {
        self.hotkeyCenter = hotkeyCenter
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = SwitcherView.makeHostingView(model: model)
    }

    /// Open the switcher on the entry after the current one, or move the selection while it is open.
    ///
    /// - Parameters:
    ///   - step: 1 for the next entry, -1 for the previous one
    ///   - holdModifiers: the modifiers whose release chooses the selection
    ///   - request: what to offer, asked for only when the switcher opens; nil to stay closed
    func advance(by step: Int, holding holdModifiers: NSEvent.ModifierFlags, request: () -> SwitcherRequest?) {
        guard isOpen else {
            guard let request = request(), !request.listEntries.isEmpty else {
                return
            }
            open(request, step: step, holding: holdModifiers)
            return
        }
        let count = model.listEntries.count
        model.selectedIndex = ((model.selectedIndex + step) % count + count) % count
    }

    /// Whether the switcher is open.
    var isShowing: Bool {
        isOpen
    }

    private func open(_ request: SwitcherRequest, step: Int, holding holdModifiers: NSEvent.ModifierFlags) {
        model.listEntries = request.listEntries
        model.holdSymbols = Hotkey.symbols(for: holdModifiers)
        let count = request.listEntries.count
        model.selectedIndex = ((request.currentIndex + step) % count + count) % count
        onCommit = request.onCommit
        isOpen = true

        listCancelHotkeys = [
            Hotkey(keyCode: kVK_Escape, modifiers: []),
            Hotkey(keyCode: kVK_Escape, modifiers: holdModifiers),
        ]
        for hotkey in listCancelHotkeys {
            hotkeyCenter.register(hotkey) { [weak self] in
                self?.close()
            }
        }
        hotkeyCenter.whenReleased(holdModifiers) { [weak self] in
            self?.commit()
        }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDelay)
            guard let self, !Task.isCancelled, isOpen else {
                return
            }
            reveal()
        }
    }

    private func reveal() {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }
        panel.setFrame(
            CGRect(
                x: visibleFrame.midX - Self.panelSize.width / 2,
                y: visibleFrame.midY - Self.panelSize.height / 2,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: false
        )
        panel.orderFrontRegardless()
        model.isVisible = true
    }

    private func commit() {
        guard isOpen, model.listEntries.indices.contains(model.selectedIndex), let onCommit else {
            close()
            return
        }
        let entry = model.listEntries[model.selectedIndex]
        close()
        onCommit(entry)
    }

    private func close() {
        guard isOpen else {
            return
        }
        isOpen = false
        onCommit = nil
        revealTask?.cancel()
        hotkeyCenter.stopWatchingModifiers()
        for hotkey in listCancelHotkeys {
            hotkeyCenter.unregister(hotkey)
        }
        listCancelHotkeys.removeAll()
        model.isVisible = false
        Task { [panel] in
            try? await Task.sleep(for: Self.fadeOutDelay)
            panel.orderOut(nil)
        }
    }
}
