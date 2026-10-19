import AppKit
import MuxShotsCore

/// The tray that appears at the top of the screen while a window is dragged, offering the groups to drop it
/// into and, for a managed window, the way out.
@MainActor
final class DropTrayController {
    private static let topMargin: CGFloat = 12
    private static let contentInset: CGFloat = 10
    private static let targetSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 16

    private let panel: NSPanel
    private let stackView = NSStackView()
    private var listTargetViews: [DropTargetView] = []

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true

        stackView.orientation = .horizontal
        stackView.spacing = Self.targetSpacing
        stackView.edgeInsets = NSEdgeInsets(
            top: Self.contentInset,
            left: Self.contentInset,
            bottom: Self.contentInset,
            right: Self.contentInset
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: background.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Show the tray on the screen under the cursor.
    ///
    /// - Parameters:
    ///   - listGroups: the groups to offer
    ///   - currentGroupId: the group the dragged window is in, which is not offered
    ///   - cursorLocation: the cursor, in AppKit screen coordinates
    func show(listGroups: [WindowGroup], currentGroupId: GroupId?, near cursorLocation: CGPoint) {
        for view in listTargetViews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        listTargetViews = listGroups
            .filter { $0.groupId != currentGroupId }
            .map { group in
                DropTargetView(
                    target: .group(group.groupId),
                    title: group.name,
                    subtitle: group.listMembers.count == 1 ? "1 window" : "\(group.listMembers.count) windows"
                )
            }
        listTargetViews.append(DropTargetView(target: .newGroup, title: "+ New Group", subtitle: nil))
        if currentGroupId != nil {
            listTargetViews.append(DropTargetView(target: .release, title: "Release", subtitle: "stop managing"))
        }
        for view in listTargetViews {
            stackView.addArrangedSubview(view)
        }

        let screen = NSScreen.screens.first { NSMouseInRect(cursorLocation, $0.frame, false) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }
        let size = stackView.fittingSize
        panel.setFrame(
            CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - Self.topMargin,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

    /// Light up the target under the cursor.
    func highlight(at cursorLocation: CGPoint) {
        let hoveredTarget = target(at: cursorLocation)
        for view in listTargetViews {
            view.isHighlighted = view.target == hoveredTarget
        }
    }

    /// The target under the cursor, if the tray is showing.
    func target(at cursorLocation: CGPoint) -> DropTarget? {
        guard panel.isVisible else {
            return nil
        }
        return listTargetViews.first { view in
            panel.convertToScreen(view.convert(view.bounds, to: nil)).contains(cursorLocation)
        }?.target
    }

    func hide() {
        panel.orderOut(nil)
    }
}
