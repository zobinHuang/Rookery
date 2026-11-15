import AppKit
import RookeryCore

/// The panel listing groups and their windows. Dragging a row onto another group moves it; dragging it out
/// of the panel releases it. While the panel is open it is also where dragged windows are dropped.
@MainActor
final class WorkspacePanelController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
    DropSurface
{
    private static let windowIdPasteboardType = NSPasteboard.PasteboardType("io.github.zobinhuang.rookery.window-id")
    private static let initialSize = CGSize(width: 360, height: 480)
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("content")
    private static let topContentInset: CGFloat = 28

    private let controller: WorkspaceController
    private let panel: NSPanel
    private let outlineView = NSOutlineView()
    private let emptyStateView = WorkspaceEmptyStateView.makeHostingView()
    private let ghostAnimator: DropGhostAnimator
    private var dropFeedback: PanelDropFeedback?
    private var draggedWindowId: WindowId?
    /// The group of the window being dragged over the panel, which is not a target.
    private var windowDragGroupId: GroupId?
    private var hoveredTarget: DropTarget?
    /// Whether a window drag is over the panel, during which the list holds still until the drop lands.
    private var isReceivingWindow = false

    init(controller: WorkspaceController, ghostAnimator: DropGhostAnimator) {
        self.controller = controller
        self.ghostAnimator = ghostAnimator
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.title = "MuxShots"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 280, height: 260)

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(renameClickedGroup)
        outlineView.registerForDraggedTypes([Self.windowIdPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.delete, forLocal: false)

        let releaseItem = NSMenuItem(title: "Release Window", action: #selector(releaseClickedWindow), keyEquivalent: "")
        releaseItem.target = self
        let switchItem = NSMenuItem(title: "Switch to Group", action: #selector(switchToClickedGroup), keyEquivalent: "")
        switchItem.target = self
        let renameItem = NSMenuItem(title: "Rename Group", action: #selector(renameClickedGroup), keyEquivalent: "")
        renameItem.target = self
        let menu = NSMenu()
        menu.addItem(switchItem)
        menu.addItem(renameItem)
        menu.addItem(releaseItem)
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.topContentInset, left: 0, bottom: 8, right: 0)

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        for view in [scrollView, emptyStateView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                view.topAnchor.constraint(equalTo: background.topAnchor),
                view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
        }
        panel.contentView = background
        dropFeedback = PanelDropFeedback(container: background, scrollView: scrollView, outlineView: outlineView)
        panel.center()
    }

    /// Whether the panel is open, and so receives dragged windows instead of the tray.
    var isShowing: Bool {
        panel.isVisible
    }

    /// Bring the panel up just beneath the dragged window.
    func beginWindowDrag(
        listGroups: [WindowGroup],
        currentGroup: WindowGroup?,
        draggedWindowId: WindowId,
        at cursorLocation: CGPoint
    ) {
        windowDragGroupId = currentGroup?.groupId
        hoveredTarget = nil
        isReceivingWindow = true
        panel.order(.below, relativeTo: Int(draggedWindowId.rawValue))
        dropFeedback?.begin()
        updateWindowDrag(at: cursorLocation)
    }

    func updateWindowDrag(at cursorLocation: CGPoint) {
        let target = target(at: cursorLocation)
        if target != hoveredTarget, case .group = target {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        hoveredTarget = target
        let isInside = panel.frame.contains(cursorLocation)
        let isMove = windowDragGroupId != nil
        let message: String? = switch target {
        case .group(let groupId):
            controller.workspace.listGroups.first { $0.groupId == groupId }
                .map { isMove ? "Drop to move to \($0.name)" : "Drop to add to \($0.name)" }
        case .newGroup:
            "Drop to start a new group"
        case .release, nil:
            isInside ? "Drop on a group or on New Group" : nil
        }
        let cardRect: CGRect? = if case .group(let groupId) = target {
            rowsRect(of: groupId)
        } else {
            nil
        }
        dropFeedback?.show(isInside: isInside, message: message, cardRect: cardRect, isZoneHovered: target == .newGroup)
    }

    func target(at cursorLocation: CGPoint) -> DropTarget? {
        guard panel.isVisible, panel.frame.contains(cursorLocation) else {
            return nil
        }
        if dropFeedback?.zoneScreenFrame?.contains(cursorLocation) == true || controller.workspace.listGroups.isEmpty {
            return .newGroup
        }
        let point = outlineView.convert(panel.convertPoint(fromScreen: cursorLocation), from: nil)
        let row = outlineView.row(at: point)
        guard
            row >= 0,
            let item = outlineView.item(atRow: row),
            let group = group(for: item) ?? groupContaining(item),
            group.groupId != windowDragGroupId
        else {
            return nil
        }
        return .group(group.groupId)
    }

    func land(
        on target: DropTarget,
        landedGroupId: GroupId?,
        windowFrame: CGRect?,
        icon: NSImage?,
        listGroups: [WindowGroup]
    ) {
        let targetFrame = target == .newGroup ? dropFeedback?.zoneScreenFrame : dropFeedback?.cardScreenFrame
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else {
                return
            }
            windowDragGroupId = nil
            hoveredTarget = nil
            isReceivingWindow = false
            reload()
            dropFeedback?.end(flashing: landedGroupId.flatMap(rowsRect(of:)))
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        guard
            landedGroupId != nil,
            let windowFrame,
            let targetFrame,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            finish()
            return
        }
        ghostAnimator.fly(from: windowFrame, to: targetFrame, icon: icon, completion: finish)
    }

    func cancelWindowDrag() {
        windowDragGroupId = nil
        hoveredTarget = nil
        isReceivingWindow = false
        dropFeedback?.end(flashing: nil)
        reload()
    }

    /// Show the panel in front of other windows.
    func show() {
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
        reload()
    }

    /// Redisplay the workspace, unless a row or a window is being dragged.
    func reload() {
        guard
            panel.isVisible,
            draggedWindowId == nil,
            !isReceivingWindow
        else {
            return
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        emptyStateView.isHidden = !controller.workspace.listGroups.isEmpty
    }

    /// Refresh a changed window title without rebuilding the rest of the list.
    func updateTitle(of windowId: WindowId) {
        guard
            panel.isVisible,
            draggedWindowId == nil,
            !isReceivingWindow
        else {
            return
        }
        let row = outlineView.row(forItem: NSNumber(value: windowId.rawValue))
        guard row >= 0 else {
            return
        }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    // Items are group identifiers as `NSString` and window identifiers as `NSNumber`.

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return controller.workspace.listGroups.count
        }
        return group(for: item)?.listMembers.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return controller.workspace.listGroups[index].groupId.rawValue as NSString
        }
        let windowId = group(for: item)?.listMembers[index].windowId.rawValue ?? 0
        return NSNumber(value: windowId)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        group(for: item) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = group(for: item) {
            let cell = outlineView.makeView(withIdentifier: GroupCellView.identifier, owner: self) as? GroupCellView
                ?? GroupCellView(nameDelegate: self)
            cell.show(group, isActive: controller.workspace.isActive(group.groupId))
            return cell
        }
        guard let window = managedWindow(for: item) else {
            return nil
        }
        let cell = outlineView.makeView(withIdentifier: WindowCellView.identifier, owner: self) as? WindowCellView
            ?? WindowCellView(frame: .zero)
        cell.show(window)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        group(for: item) == nil ? WindowCellView.rowHeight : GroupCellView.rowHeight
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else {
            return
        }
        let row = outlineView.row(for: textField)
        guard row >= 0, let group = group(for: outlineView.item(atRow: row) as Any) else {
            return
        }
        controller.rename(group.groupId, to: textField.stringValue)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let window = managedWindow(for: item) else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(window.windowId.rawValue), forType: Self.windowIdPasteboardType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        draggedWindowId = draggedItems.first.flatMap(managedWindow(for:))?.windowId
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let windowId = draggedWindowId
        draggedWindowId = nil
        if let windowId, operation != .move, !panel.frame.contains(screenPoint) {
            controller.release(windowId)
        } else {
            reload()
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let item, let group = group(for: item) ?? groupContaining(item) else {
            return []
        }
        outlineView.setDropItem(group.groupId.rawValue as NSString, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard
            let item,
            let group = group(for: item),
            let rawId = info.draggingPasteboard.string(forType: Self.windowIdPasteboardType).flatMap(UInt32.init)
        else {
            return false
        }
        controller.move(WindowId(rawValue: rawId), to: group.groupId)
        return true
    }

    @objc private func switchToClickedGroup() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row), let group = group(for: item) ?? groupContaining(item) else {
            return
        }
        Task { [controller] in
            await controller.switchTo(group.groupId)
        }
    }

    @objc private func renameClickedGroup() {
        let row = outlineView.clickedRow
        guard
            row >= 0,
            group(for: outlineView.item(atRow: row) as Any) != nil,
            let nameField = (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField
        else {
            return
        }
        panel.makeFirstResponder(nameField)
    }

    @objc private func releaseClickedWindow() {
        guard let window = managedWindow(for: outlineView.item(atRow: outlineView.clickedRow) as Any) else {
            return
        }
        controller.release(window.windowId)
    }

    /// The rows of a group, its header and its windows, in the list's coordinates.
    private func rowsRect(of groupId: GroupId) -> CGRect? {
        var rowsRect: CGRect?
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) else {
                continue
            }
            let rowGroupId = group(for: item)?.groupId ?? groupContaining(item)?.groupId
            if rowGroupId == groupId {
                rowsRect = rowsRect?.union(outlineView.rect(ofRow: row)) ?? outlineView.rect(ofRow: row)
            }
        }
        return rowsRect
    }

    private func group(for item: Any) -> WindowGroup? {
        guard let rawId = item as? String else {
            return nil
        }
        return controller.workspace.listGroups.first { $0.groupId.rawValue == rawId }
    }

    private func groupContaining(_ item: Any) -> WindowGroup? {
        managedWindow(for: item).flatMap { controller.workspace.group(containing: $0.windowId) }
    }

    private func managedWindow(for item: Any) -> ManagedWindow? {
        guard let number = item as? NSNumber else {
            return nil
        }
        return controller.workspace.listManagedWindows.first { $0.windowId.rawValue == number.uint32Value }
    }
}
