import AppKit
import ObjectiveC
import SwiftUI

/// A part of a view laid out in a hosting view of its own, so that what changes inside it, as a
/// conversation growing line by line or scrolling, lays out only the part and never the whole window around
/// it, whose layout is far dearer. The window gives it a size and asks nothing more of it; the part gets the
/// theme, the people, the text colors and the button style the window's root sets, which a hosting view of
/// its own would not inherit.
struct LayoutIsland<Content: View>: NSViewRepresentable {
    @Environment(\.chosenTheme) private var chosenTheme
    @Environment(\.people) private var people

    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> LayoutIslandView {
        LayoutIslandView(hosting: NSHostingView(rootView: island()))
    }

    func updateNSView(_ view: LayoutIslandView, context: Context) {
        view.hosting.rootView = island()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayoutIslandView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private func island() -> AnyView {
        AnyView(
            content()
                .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
                .environment(\.chosenTheme, chosenTheme)
                .environment(\.people, people)
                .buttonStyle(StageButtonStyle())
        )
    }
}

/// The view a `LayoutIsland` gives the window: its hosting view inside, filling it, and nothing of what
/// changes inside reported to the window as a change of its size.
final class LayoutIslandView: NSView {
    private static let metricsSelector = NSSelectorFromString("_layoutMetricsInvalidatedForHostedView")
    /// The host classes whose layout metrics an island's changes no longer invalidate.
    @MainActor private static var setQuietHosts: Set<ObjectIdentifier> = []

    let hosting: NSHostingView<AnyView>

    init(hosting: NSHostingView<AnyView>) {
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview {
            Self.quietHost(type(of: superview))
        }
    }

    override func layout() {
        super.layout()
        if hosting.frame != bounds {
            hosting.frame = bounds
        }
    }

    /// Keep the window's own hosting view from laying the whole window out again whenever something
    /// inside an island changes, as on every frame a conversation scrolls: SwiftUI's host of the island
    /// takes AppKit's notice that a subview's constraints need updating to mean the island's size may have
    /// changed, when its size is the one SwiftUI gives it, whatever happens inside. The notice itself still
    /// goes up the views, so the hosting view inside keeps updating as it should. Only the host class of an
    /// island changes, and only for hosts of an island; where it has no such method, nothing does.
    private static func quietHost(_ hostClass: AnyClass) {
        let key = ObjectIdentifier(hostClass)
        guard !setQuietHosts.contains(key), let method = class_getInstanceMethod(hostClass, metricsSelector) else {
            return
        }
        setQuietHosts.insert(key)
        typealias Metrics = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Metrics.self)
        let selector = metricsSelector
        let replacement: @convention(block) (AnyObject) -> Void = { host in
            let isIsland = (host as? NSView)?.subviews.contains { $0 is LayoutIslandView } ?? false
            if !isIsland {
                original(host, selector)
            }
        }
        class_replaceMethod(hostClass, metricsSelector, imp_implementationWithBlock(replacement), method_getTypeEncoding(method))
    }
}
