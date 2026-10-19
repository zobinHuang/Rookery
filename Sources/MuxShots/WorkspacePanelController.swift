import AppKit
import MuxShotsCore

/// The panel listing groups and their windows. Dragging a window onto another group moves it; dragging it
/// out of the panel releases it.
@MainActor
final class WorkspacePanelController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private static let windowIdPasteboardType = NSPasteboard.PasteboardType("io.github.zobinhuang.muxshots.window-id")
    private static let initialSize = CGSize(width: 380, height: 460)
    private static let iconSize: CGFloat = 16
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("cell")

    private let controller: WorkspaceController
    private let panel: NSPanel
    private let outlineView = NSOutlineView()
    private var draggedWindowId: WindowId?

    init(controller: WorkspaceController) {
        self.controller = controller
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.title = "MuxShots"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let column = NSTableColumn(identifier: Self.cellIdentifier)
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([Self.windowIdPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.delete, forLocal: false)

        let releaseItem = NSMenuItem(title: "Release Window", action: #selector(releaseClickedWindow), keyEquivalent: "")
        releaseItem.target = self
        let menu = NSMenu()
        menu.addItem(releaseItem)
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        panel.contentView = scrollView
        panel.center()
    }

    /// Show the panel in front of other windows.
    func show() {
        reload()
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Redisplay the workspace, unless a row is being dragged.
    func reload() {
        guard draggedWindowId == nil else {
            return
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
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
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        guard let textField = cell.textField, let imageView = cell.imageView else {
            return cell
        }
        if let group = group(for: item) {
            textField.stringValue = group.name
            textField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            textField.isEditable = true
            imageView.image = nil
        } else if let window = managedWindow(for: item) {
            let title = window.title.isEmpty ? "Untitled" : window.title
            textField.stringValue = "\(window.application.name) — \(title)"
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.isEditable = false
            imageView.image = Self.icon(for: window.application)
        }
        return cell
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

    @objc private func releaseClickedWindow() {
        guard let window = managedWindow(for: outlineView.item(atRow: outlineView.clickedRow) as Any) else {
            return
        }
        controller.release(window.windowId)
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

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier
        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.delegate = self
        let stack = NSStackView(views: [imageView, textField])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func icon(for application: RunningApplication) -> NSImage? {
        guard
            let bundleId = application.bundleId,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
