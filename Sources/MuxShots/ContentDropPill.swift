import AppKit
import SwiftUI

/// The pill that drops down at the top of a stage's content area while a window is dragged over it. The
/// content area itself takes no window; only a drop on the pill adds the window to the stage's active group,
/// so a window merely dragged across the stage is left alone.
@MainActor
final class ContentDropPill {
    /// The pill's size, and the room around it in its panel for its shadow and its growth while hovered.
    static let pillSize = CGSize(width: 300, height: 64)
    private static let panelMargin: CGFloat = 28
    /// How far below the top of the content area the pill hangs.
    private static let topInset: CGFloat = 20
    private static let fadeOutDelay = Duration.milliseconds(280)
    private static let landedHold = Duration.milliseconds(320)

    private let model = ContentDropPillModel()
    private let panel: NSPanel
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
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ContentDropPillView(model: model))
    }

    /// Whether the pill is up.
    var isShowing: Bool {
        model.isVisible
    }

    /// The pill's frame, in AppKit screen coordinates, while it is up.
    var frame: CGRect? {
        guard model.isVisible else {
            return nil
        }
        return panel.frame.insetBy(dx: Self.panelMargin, dy: Self.panelMargin)
    }

    /// Drop the pill down at the top of a content area, or move it there if it is up already.
    ///
    /// - Parameters:
    ///   - contentFrame: the content area, in AppKit screen coordinates
    ///   - groupName: the active group a drop adds to, or nil if a drop starts a group
    func show(over contentFrame: CGRect, groupName: String?) {
        hideTask?.cancel()
        hideTask = nil
        let panelFrame = CGRect(
            x: contentFrame.midX - Self.pillSize.width / 2 - Self.panelMargin,
            y: contentFrame.maxY - Self.topInset - Self.pillSize.height - Self.panelMargin,
            width: Self.pillSize.width + Self.panelMargin * 2,
            height: Self.pillSize.height + Self.panelMargin * 2
        )
        if panel.frame != panelFrame {
            panel.setFrame(panelFrame, display: false)
        }
        if model.groupName != groupName {
            model.groupName = groupName
        }
        if model.isLanded {
            model.isLanded = false
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if !model.isVisible {
            model.isVisible = true
        }
    }

    /// Light the pill up while the cursor is over it.
    var isHovered: Bool {
        get {
            model.isHovered
        }
        set {
            guard newValue != model.isHovered else {
                return
            }
            model.isHovered = newValue
            if newValue {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    /// Show that a window was taken, then lift the pill away.
    func land() {
        model.isLanded = true
        dismiss(after: Self.landedHold)
    }

    /// Lift the pill away.
    func dismiss() {
        dismiss(after: .zero)
    }

    private func dismiss(after delay: Duration) {
        guard model.isVisible else {
            return
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else {
                return
            }
            model.isVisible = false
            model.isHovered = false
            try? await Task.sleep(for: Self.fadeOutDelay)
            guard !Task.isCancelled else {
                return
            }
            panel.orderOut(nil)
            hideTask = nil
        }
    }
}

/// The state the content drop pill renders.
@MainActor
@Observable
final class ContentDropPillModel {
    var isVisible = false
    var isHovered = false
    /// Whether a window was just dropped on the pill, which then shows it was taken.
    var isLanded = false
    /// The active group a drop adds to, or nil if a drop starts a group.
    var groupName: String?
}

/// The content drop pill: Liquid Glass at rest, filled with the accent color while a window is over it.
struct ContentDropPillView: View {
    private static let appearAnimation = Animation.spring(response: 0.34, dampingFraction: 0.8)
    private static let hoverAnimation = Animation.spring(response: 0.26, dampingFraction: 0.64)
    private static let hiddenOffset: CGFloat = -18
    private static let cornerRadius: CGFloat = 20

    let model: ContentDropPillModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isLit ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: ContentDropPill.pillSize.width, height: ContentDropPill.pillSize.height)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.accentColor.gradient)
                .opacity(isLit ? 1 : 0)
        }
        .modifier(TraySurface(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .opacity(isLit ? 0 : 1)
        }
        .shadow(color: isLit ? Color.accentColor.opacity(0.45) : .black.opacity(0.16), radius: isLit ? 16 : 12, y: 6)
        .scaleEffect(model.isLanded ? 1.1 : (model.isHovered ? 1.06 : 1))
        .animation(Self.hoverAnimation, value: model.isHovered)
        .animation(Self.hoverAnimation, value: model.isLanded)
        .opacity(model.isVisible ? 1 : 0)
        .scaleEffect(model.isVisible ? 1 : 0.92, anchor: .top)
        .offset(y: model.isVisible ? 0 : Self.hiddenOffset)
        .animation(Self.appearAnimation, value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isLit: Bool {
        model.isHovered || model.isLanded
    }

    private var symbolName: String {
        if model.isLanded {
            return "checkmark.circle.fill"
        }
        return model.isHovered ? "arrow.down.circle.fill" : "plus.rectangle.on.rectangle"
    }

    private var title: String {
        if model.isLanded {
            return "Added"
        }
        return model.groupName.map { "Add to \($0)" } ?? "Start a Group"
    }

    private var subtitle: String {
        if model.isLanded {
            return model.groupName.map { "Opened as a tab in \($0)" } ?? "Opened in a new group"
        }
        return model.isHovered ? "Release to manage this window" : "Drop the window here to manage it"
    }
}
