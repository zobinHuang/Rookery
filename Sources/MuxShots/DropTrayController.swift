import AppKit
import MuxShotsCore

/// The tray shown at the top of the screen while a window is dragged. It sits directly beneath the dragged
/// window, stays a pill until the cursor nears the top of the screen, then offers the groups to drop into
/// and, for a managed window, the way out.
@MainActor
final class DropTrayController {
    private static let panelHeight: CGFloat = 150
    private static let panelWidthLimit: CGFloat = 1100
    /// How close to the top of the screen the cursor must be to expand the tray.
    private static let expandDistance: CGFloat = 240
    private static let fadeOutDelay = Duration.milliseconds(260)
    private static let landedHold = Duration.milliseconds(220)

    private let model = TrayModel()
    private let panel: NSPanel
    private let ghostAnimator = DropGhostAnimator()
    private var screen: NSScreen?
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = TrayView.makeHostingView(model: model)
    }

    /// Show the tray, collapsed, on the screen under the cursor and just beneath the dragged window.
    ///
    /// - Parameters:
    ///   - listGroups: the groups to offer
    ///   - currentGroup: the group the dragged window is in, which is not offered
    ///   - draggedWindowId: the window being dragged
    ///   - cursorLocation: the cursor, in AppKit screen coordinates
    func show(
        listGroups: [WindowGroup],
        currentGroup: WindowGroup?,
        draggedWindowId: WindowId,
        near cursorLocation: CGPoint
    ) {
        hideTask?.cancel()
        model.listTiles = Self.tiles(for: listGroups, currentGroup: currentGroup)
        model.draggedGroupName = currentGroup?.name
        model.hoveredTarget = nil
        model.landedTarget = nil
        model.isExpanded = false

        screen = NSScreen.screens.first { NSMouseInRect(cursorLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let width = min(visibleFrame.width, Self.panelWidthLimit)
        panel.setFrame(
            CGRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.maxY - Self.panelHeight,
                width: width,
                height: Self.panelHeight
            ),
            display: false
        )
        panel.order(.below, relativeTo: Int(draggedWindowId.rawValue))
        model.isVisible = true
        update(cursorLocation: cursorLocation)
    }

    /// Follow the cursor: expand near the top of the screen and light up the target under it.
    func update(cursorLocation: CGPoint) {
        guard let screen, model.isVisible else {
            return
        }
        model.isExpanded = cursorLocation.y >= screen.visibleFrame.maxY - Self.expandDistance
        let hoveredTarget = model.isExpanded ? target(at: cursorLocation) : nil
        if hoveredTarget != model.hoveredTarget {
            model.hoveredTarget = hoveredTarget
            if hoveredTarget != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    /// The target under the cursor, if the tray is expanded.
    func target(at cursorLocation: CGPoint) -> DropTarget? {
        guard model.isVisible, model.isExpanded else {
            return nil
        }
        return model.listTiles.first { tile in
            screenFrame(of: tile.target)?.contains(cursorLocation) == true
        }?.target
    }

    /// Animate a dropped window into its target, then dismiss the tray.
    ///
    /// - Parameters:
    ///   - target: the target the window was dropped on
    ///   - landedGroupId: the group the window joined, or nil when it was released
    ///   - windowFrame: the dropped window's frame, in AppKit screen coordinates
    ///   - icon: the window's application icon
    ///   - listGroups: the groups after the drop, so the landing tile shows its new member
    func land(
        on target: DropTarget,
        landedGroupId: GroupId?,
        windowFrame: CGRect?,
        icon: NSImage?,
        listGroups: [WindowGroup]
    ) {
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self else {
                return
            }
            model.listTiles = Self.landingTiles(model.listTiles, listGroups: listGroups, landedGroupId: landedGroupId)
            model.landedTarget = landedGroupId.map { .group($0) }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            dismiss(after: Self.landedHold)
        }
        guard
            landedGroupId != nil,
            let windowFrame,
            let targetFrame = screenFrame(of: target),
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            finish()
            return
        }
        ghostAnimator.fly(from: windowFrame, to: targetFrame, icon: icon, completion: finish)
    }

    /// Fade the tray out.
    func dismiss(after delay: Duration = .zero) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else {
                return
            }
            model.isVisible = false
            model.hoveredTarget = nil
            try? await Task.sleep(for: Self.fadeOutDelay)
            guard !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
        }
    }

    private func screenFrame(of target: DropTarget) -> CGRect? {
        guard let frame = model.mapTileFrames[target] else {
            return nil
        }
        return CGRect(
            x: panel.frame.minX + frame.minX,
            y: panel.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// The tiles offered for a drag.
    private static func tiles(for listGroups: [WindowGroup], currentGroup: WindowGroup?) -> [TrayTile] {
        var listTiles = listGroups
            .filter { $0.groupId != currentGroup?.groupId }
            .map(tile(for:))
        listTiles.append(TrayTile(target: .newGroup, title: "New Group", listBundleIds: []))
        if currentGroup != nil {
            listTiles.append(TrayTile(target: .release, title: "Release", listBundleIds: []))
        }
        return listTiles
    }

    /// The tiles after a drop, in the same order: each group shows its new members, and the "New Group"
    /// tile becomes the group the drop created.
    private static func landingTiles(
        _ listPrevious: [TrayTile],
        listGroups: [WindowGroup],
        landedGroupId: GroupId?
    ) -> [TrayTile] {
        let mapGroups = Dictionary(uniqueKeysWithValues: listGroups.map { ($0.groupId, $0) })
        let setOfferedIds = Set(listPrevious.compactMap { tile -> GroupId? in
            if case .group(let groupId) = tile.target {
                return groupId
            }
            return nil
        })
        return listPrevious.map { previous in
            switch previous.target {
            case .group(let groupId):
                return mapGroups[groupId].map(tile(for:)) ?? previous
            case .newGroup:
                guard
                    let landedGroupId,
                    !setOfferedIds.contains(landedGroupId),
                    let group = mapGroups[landedGroupId]
                else {
                    return previous
                }
                return tile(for: group)
            case .release:
                return previous
            }
        }
    }

    private static func tile(for group: WindowGroup) -> TrayTile {
        TrayTile(
            target: .group(group.groupId),
            title: group.name,
            listBundleIds: group.listMembers.map(\.application.bundleId)
        )
    }
}
