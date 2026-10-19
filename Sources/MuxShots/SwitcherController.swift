import AppKit
import Carbon.HIToolbox
import MuxShotsCore
import MuxShotsPlatform

/// The hold-to-choose group switcher: its shortcut opens it on the next group, further presses move the
/// selection, releasing the held modifiers switches and esc cancels. A quick tap switches without showing
/// anything, like Cmd-Tab.
@MainActor
final class SwitcherController {
    private static let revealDelay = Duration.milliseconds(140)
    private static let fadeOutDelay = Duration.milliseconds(200)
    private static let panelSize = CGSize(width: 1100, height: 320)

    private let workspaceController: WorkspaceController
    private let hotkeyCenter: HotkeyCenter
    private let model = SwitcherModel()
    private let panel: NSPanel
    private var isOpen = false
    private var listCancelHotkeys: [Hotkey] = []
    private var revealTask: Task<Void, Never>?

    init(workspaceController: WorkspaceController, hotkeyCenter: HotkeyCenter) {
        self.workspaceController = workspaceController
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

    /// Open the switcher on the group after the current one, or move the selection while it is open.
    ///
    /// - Parameters:
    ///   - step: 1 for the next entry, -1 for the previous one
    ///   - holdModifiers: the modifiers whose release chooses the selection
    func advance(by step: Int, holding holdModifiers: NSEvent.ModifierFlags) {
        guard isOpen else {
            open(step: step, holding: holdModifiers)
            return
        }
        let count = model.listEntries.count
        model.selectedIndex = ((model.selectedIndex + step) % count + count) % count
    }

    private func open(step: Int, holding holdModifiers: NSEvent.ModifierFlags) {
        let workspace = workspaceController.workspace
        guard !workspace.listGroups.isEmpty else {
            return
        }
        let currentGroupId = workspaceController.frontmostActiveGroup()?.groupId
        model.listEntries = workspace.listGroups.map { group in
            SwitcherEntry(
                groupId: group.groupId,
                title: group.name,
                listBundleIds: group.listMembersFrontToBack.map(\.application.bundleId),
                isActive: workspace.isActive(group.groupId)
            )
        } + [SwitcherEntry(groupId: nil, title: "All Windows", listBundleIds: [], isActive: false)]
        let activeIndex = model.listEntries.firstIndex { $0.groupId == currentGroupId } ?? model.listEntries.count - 1
        let count = model.listEntries.count
        model.selectedIndex = ((activeIndex + step) % count + count) % count
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
        guard isOpen, model.listEntries.indices.contains(model.selectedIndex) else {
            close()
            return
        }
        let groupId = model.listEntries[model.selectedIndex].groupId
        close()
        Task { [workspaceController] in
            await workspaceController.switchTo(groupId)
        }
    }

    private func close() {
        guard isOpen else {
            return
        }
        isOpen = false
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
