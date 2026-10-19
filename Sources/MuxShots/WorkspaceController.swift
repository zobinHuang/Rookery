import AppKit
import MuxShotsCore
import MuxShotsPlatform
import os

/// Owns the workspace: turns drops on the tray and edits in the panel into managed windows and groups,
/// keeps the tracker following exactly the managed windows, and persists the result.
@MainActor
final class WorkspaceController: WindowDragMonitorDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "workspace")
    /// Lets the dragged application finish its own drag before the window is moved back.
    private static let settleDelay = Duration.milliseconds(120)

    private(set) var workspace: Workspace
    private let tracker: WindowTracker
    private let dragMonitor = WindowDragMonitor()
    private let tray = DropTrayController()
    private var changeTask: Task<Void, Never>?

    /// Called after every change to the workspace, including title updates.
    var onChange: (() -> Void)?

    init(tracker: WindowTracker) {
        self.tracker = tracker
        do {
            workspace = try WorkspaceStore.load()
        } catch {
            Self.logger.error("cannot load the saved workspace, starting empty: \(error, privacy: .public)")
            workspace = Workspace()
        }
    }

    /// Resume managing the saved windows that still exist and start watching window drags.
    func start() {
        for window in workspace.listManagedWindows where liveApplication(of: window) == nil {
            workspace.release(window.windowId)
        }
        save()
        let listRestored = workspace.listManagedWindows.compactMap { window in
            liveApplication(of: window).map { (window.windowId, $0) }
        }
        changeTask = Task { [tracker] in
            await tracker.start()
            for (windowId, application) in listRestored {
                await tracker.manage(windowId, of: application)
            }
            for await change in await tracker.changes() {
                handle(change)
            }
        }
        dragMonitor.delegate = self
        dragMonitor.start()
    }

    /// Stop watching drags and save the latest titles.
    func stop() {
        dragMonitor.stop()
        changeTask?.cancel()
        save()
    }

    /// Manage a window in a group, moving it out of any group it was in.
    ///
    /// - Parameters:
    ///   - windowId: the window
    ///   - processId: the process that owns the window
    ///   - groupId: the destination group, or nil for a new group
    func adopt(_ windowId: WindowId, processId: pid_t, into groupId: GroupId?) {
        if let existing = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) {
            workspace.adopt(existing, into: groupId)
            didChange()
            return
        }
        guard let application = ApplicationMonitor.application(processId: processId) else {
            return
        }
        workspace.adopt(ManagedWindow(windowId: windowId, application: application, title: ""), into: groupId)
        didChange()
        Task { [tracker] in
            await tracker.manage(windowId, of: application)
        }
    }

    /// Move a managed window to another group.
    func move(_ windowId: WindowId, to groupId: GroupId) {
        guard let window = workspace.listManagedWindows.first(where: { $0.windowId == windowId }) else {
            return
        }
        workspace.adopt(window, into: groupId)
        didChange()
    }

    /// Stop managing a window.
    func release(_ windowId: WindowId) {
        guard workspace.release(windowId) else {
            return
        }
        didChange()
        Task { [tracker] in
            await tracker.release(windowId)
        }
    }

    func rename(_ groupId: GroupId, to name: String) {
        workspace.rename(groupId, to: name)
        didChange()
    }

    func windowDragBegan(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        tray.show(
            listGroups: workspace.listGroups,
            currentGroupId: workspace.group(containing: drag.windowId)?.groupId,
            near: cursorLocation
        )
        tray.highlight(at: cursorLocation)
    }

    func windowDragMoved(_ drag: WindowDrag, to cursorLocation: CGPoint) {
        tray.highlight(at: cursorLocation)
    }

    func windowDragEnded(_ drag: WindowDrag, at cursorLocation: CGPoint) {
        let target = tray.target(at: cursorLocation)
        tray.hide()
        guard let target else {
            return
        }
        switch target {
        case .group(let groupId):
            adopt(drag.windowId, processId: drag.processId, into: groupId)
        case .newGroup:
            adopt(drag.windowId, processId: drag.processId, into: nil)
        case .release:
            break
        }
        let isRelease = target == .release
        Task { [tracker] in
            try? await Task.sleep(for: Self.settleDelay)
            await tracker.applyFrame(drag.startFrame, to: drag.windowId)
            if isRelease {
                self.release(drag.windowId)
            }
        }
    }

    private func handle(_ change: WindowChange) {
        switch change {
        case .added(let window), .updated(let window):
            workspace.updateTitle(of: window.windowId, to: window.title)
            onChange?()
        case .removed(let windowId):
            if workspace.release(windowId) {
                didChange()
            }
        }
    }

    /// The running application that owns a saved window, or nil if the window is gone or its identifier now
    /// belongs to another application's window.
    private func liveApplication(of window: ManagedWindow) -> RunningApplication? {
        guard
            let serverWindow = WindowServer.window(withId: window.windowId),
            let application = ApplicationMonitor.application(processId: serverWindow.processId),
            application.bundleId == window.application.bundleId
        else {
            return nil
        }
        return application
    }

    private func didChange() {
        save()
        onChange?()
    }

    private func save() {
        do {
            try WorkspaceStore.save(workspace)
        } catch {
            Self.logger.error("cannot save the workspace: \(error, privacy: .public)")
        }
    }
}
