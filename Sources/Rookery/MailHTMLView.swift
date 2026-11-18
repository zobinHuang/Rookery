import AppKit
import os
import RookeryCore
import SwiftUI
import WebKit

/// A message's HTML shown as its sender formatted it, safely: no script of the message's runs, nothing is
/// fetched from the network unless the user lets this message load its images, and a link opens in the
/// browser rather than here. A message laid out wider than the view is scaled down to fit it, as Mail
/// does. Given a way to report its height, it takes the height its content needs, measured again as the
/// view's width changes and as late images and fonts land, and leaves scrolling to the view around it.
struct MailHTMLView: NSViewRepresentable {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    private static let remoteRuleIdentifier = "rookery-block-remote"
    private static let remoteRule = #"[{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}}]"#
    /// One store for every message shown, kept in memory only: each store of its own would start a
    /// network process of its own for every message opened.
    @MainActor private static let dataStore = WKWebsiteDataStore.nonPersistent()
    /// The rule that blocks remote content, compiled once.
    @MainActor private static var remoteRuleList: WKContentRuleList?

    let html: String
    /// Whether the message may fetch its images and other remote content.
    let isRemoteAllowed: Bool
    /// Whether the earlier mail the message quotes is taken away, leaving its own words.
    var isQuoteTrimmed = false
    /// Told whether anything quoted was taken away, once the message is laid out.
    var onQuoteTrimmed: ((Bool) -> Void)?
    /// Told the height the message's content needs once it is laid out; nil to scroll inside the view.
    var onHeight: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = Self.dataStore
        let view = MailWebView(frame: .zero, configuration: configuration)
        view.isScrollingOuter = onHeight != nil
        view.navigationDelegate = context.coordinator
        let coordinator = context.coordinator
        view.onWidthChange = { [weak view] in
            guard let view else {
                return
            }
            coordinator.measureSoon(view)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard
            coordinator.loadedHTML != html
            || coordinator.isRemoteAllowed != isRemoteAllowed
            || coordinator.isQuoteTrimmed != isQuoteTrimmed
        else {
            return
        }
        coordinator.loadedHTML = html
        coordinator.isRemoteAllowed = isRemoteAllowed
        context.coordinator.onHeight = onHeight
        context.coordinator.isQuoteTrimmed = isQuoteTrimmed
        context.coordinator.onQuoteTrimmed = onQuoteTrimmed
        view.configuration.userContentController.removeAllContentRuleLists()
        guard !isRemoteAllowed else {
            view.loadHTMLString(Self.framed(html), baseURL: nil)
            return
        }
        if let list = Self.remoteRuleList {
            view.configuration.userContentController.add(list)
            view.loadHTMLString(Self.framed(html), baseURL: nil)
            return
        }
        let html = html
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: Self.remoteRuleIdentifier,
            encodedContentRuleList: Self.remoteRule
        ) { list, error in
            MainActor.assumeIsolated {
                guard let list else {
                    Self.logger.error("cannot block remote content: \(String(describing: error), privacy: .public)")
                    view.loadHTMLString("<p>Rookery could not show this message safely.</p>", baseURL: nil)
                    return
                }
                Self.remoteRuleList = list
                view.configuration.userContentController.add(list)
                view.loadHTMLString(Self.framed(html), baseURL: nil)
            }
        }
    }

    /// The id of the mark after the message's last line, which its height is measured to.
    private static let endMarkId = "rookery-end"

    /// The message on a white page with a readable default type, as mail clients show it, and a mark after
    /// its last line.
    private static func framed(_ html: String) -> String {
        """
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <style>html { background: #fff; } body { font: 14px -apple-system, sans-serif; color: #1d1d1f; margin: 0; padding: 16px; word-wrap: break-word; } img { max-width: 100%; height: auto; } #\(endMarkId) { clear: both; height: 0; margin: 0; padding: 0; }</style>
        \(html)
        <div id="\(endMarkId)"></div>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The page's height: down to the mark after the message's last line, past its last margin, and the
        /// page's padding below it, read while the document is held to no height for an instant, since a page
        /// without a doctype stretches anything a hundred percent tall to the view, which would keep the
        /// message from ever growing shorter.
        private static let heightScript = """
            const body = document.body;
            if (!body) { return 0; }
            let end = document.getElementById("\(endMarkId)");
            if (!end) {
                end = document.createElement("div");
                end.id = "\(endMarkId)";
                body.appendChild(end);
            }
            const root = document.documentElement;
            const heldHeight = root.style.height;
            root.style.height = "1px";
            const bottom = end.getBoundingClientRect().bottom;
            root.style.height = heldHeight;
            return Math.ceil(bottom + window.scrollY + parseFloat(getComputedStyle(body).paddingBottom || "0"));
            """
        /// How wide the page lays out against how wide the view is, in the page's own pixels: the furthest
        /// any element reaches, its own content counted where a box of the message's clips it, and the
        /// page's padding beyond it.
        private static let widthScript = """
            const root = document.documentElement;
            const body = document.body;
            if (!root || !body) { return [0, 0]; }
            const padding = parseFloat(getComputedStyle(body).paddingRight || "0");
            let reach = Math.max(root.scrollWidth, body.scrollWidth);
            for (const node of [...body.querySelectorAll("*")].slice(0, 4000)) {
                const rect = node.getBoundingClientRect();
                reach = Math.max(reach, rect.right + window.scrollX + padding, rect.left + window.scrollX + node.scrollWidth + padding);
            }
            return [Math.ceil(reach), window.innerWidth];
            """
        /// How many times the scale is narrowed in one fitting, since a message laid out at a new scale can
        /// reach a little further than it did.
        private static let fitAttempts = 3
        /// The most a message is scaled down to fit; narrower than this it scrolls sideways.
        private static let smallestZoom: CGFloat = 0.5
        /// When the message is measured again after loading, for images and fonts that land late.
        private static let listRemeasureDelays: [Duration] = [.milliseconds(600), .seconds(2)]
        private static let widthChangeDelay = Duration.milliseconds(150)
        /// How often, and how many times, the page is asked whether it laid out at its new scale.
        private static let zoomSettleInterval = Duration.milliseconds(30)
        private static let zoomSettleAttempts = 40

        /// What the page was last loaded with, to load it again only when one changes.
        var loadedHTML: String?
        var isRemoteAllowed = false
        var onHeight: ((CGFloat) -> Void)?
        var isQuoteTrimmed = false
        var onQuoteTrimmed: ((Bool) -> Void)?
        private var isLoaded = false
        private var measureTask: Task<Void, Never>?

        isolated deinit {
            measureTask?.cancel()
        }

        /// Take away the quoted mail when asked, then fit the message to the view and read how tall it is,
        /// now and again a little later, by scripts of Rookery's own: the message's own scripts stay off.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let isQuoteTrimmed = isQuoteTrimmed
            let onQuoteTrimmed = onQuoteTrimmed
            isLoaded = false
            measureTask?.cancel()
            measureTask = Task { @MainActor [weak self] in
                if isQuoteTrimmed {
                    let isTrimmed = try? await webView.callAsyncJavaScript(MailQuote.trimScript, contentWorld: .defaultClient)
                    onQuoteTrimmed?((isTrimmed as? Bool) ?? false)
                }
                self?.isLoaded = true
                await self?.measure(webView, isRefit: true)
                for delay in Self.listRemeasureDelays {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.measure(webView, isRefit: false)
                }
            }
        }

        /// Fit and measure the message again once the view's width settles.
        func measureSoon(_ webView: WKWebView) {
            guard isLoaded else {
                return
            }
            measureTask?.cancel()
            measureTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.widthChangeDelay)
                guard !Task.isCancelled else {
                    return
                }
                await self?.measure(webView, isRefit: true)
            }
        }

        /// Scale the message down when it lays out wider than the view, then report its height in the
        /// view's points: fitted afresh from full size when it loads or the view's width changes, else only
        /// scaled down further if something late made it wider.
        private func measure(_ webView: WKWebView, isRefit: Bool) async {
            if isRefit, webView.pageZoom != 1 {
                webView.pageZoom = 1
                await settle(webView)
            }
            for _ in 0..<Self.fitAttempts {
                guard
                    let listWidths = try? await webView.callAsyncJavaScript(Self.widthScript, contentWorld: .defaultClient) as? [Double],
                    listWidths.count == 2,
                    listWidths[1] > 0,
                    listWidths[0] > listWidths[1] + 1,
                    webView.pageZoom > Self.smallestZoom
                else {
                    break
                }
                webView.pageZoom = max(Self.smallestZoom, webView.pageZoom * CGFloat(listWidths[1] / listWidths[0]))
                await settle(webView)
            }
            guard !Task.isCancelled else {
                return
            }
            guard let onHeight else {
                return
            }
            let height = try? await webView.callAsyncJavaScript(Self.heightScript, contentWorld: .defaultClient)
            if let height = height as? Double {
                onHeight(CGFloat(height) * webView.pageZoom)
            }
        }

        /// Wait until the page lays out at the view's scale: its width in its own pixels the view's width
        /// over the scale.
        private func settle(_ webView: WKWebView) async {
            for _ in 0..<Self.zoomSettleAttempts {
                let expected = Double(webView.bounds.width / webView.pageZoom)
                if
                    let width = try? await webView.callAsyncJavaScript("return window.innerWidth;", contentWorld: .defaultClient) as? Double,
                    abs(width - expected) < 2
                {
                    return
                }
                try? await Task.sleep(for: Self.zoomSettleInterval)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

/// The web view of a message that takes its content's height: scrolling over it scrolls the view around it.
final class MailWebView: WKWebView {
    var isScrollingOuter = false
    /// Told when the view's width changes, for the message to be fitted and measured again.
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let isWidthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if isWidthChanged {
            onWidthChange?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if isScrollingOuter {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

