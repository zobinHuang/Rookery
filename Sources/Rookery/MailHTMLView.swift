import AppKit
import os
import RookeryCore
import SwiftUI
import WebKit

/// A message's HTML shown as its sender formatted it, safely: no script of the message's runs, nothing is
/// fetched from the network unless the user lets this message load its images, and a link opens in the
/// browser rather than here. Given a way to report its height, it takes the height its content needs and
/// leaves scrolling to the view around it.
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

    /// The message on a white page with a readable default type, as mail clients show it.
    private static func framed(_ html: String) -> String {
        """
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <style>html { background: #fff; } body { font: 14px -apple-system, sans-serif; color: #1d1d1f; margin: 16px; word-wrap: break-word; } img { max-width: 100%; height: auto; }</style>
        \(html)
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private static let heightScript = """
            const body = document.body;
            if (!body) { return 0; }
            const range = document.createRange();
            range.selectNodeContents(body);
            const bottom = Math.max(range.getBoundingClientRect().bottom, ...[...body.children].map(child => child.getBoundingClientRect().bottom));
            return Math.ceil(bottom + window.scrollY + parseFloat(getComputedStyle(body).marginBottom || "0"));
            """

        /// What the page was last loaded with, to load it again only when one changes.
        var loadedHTML: String?
        var isRemoteAllowed = false
        var onHeight: ((CGFloat) -> Void)?
        var isQuoteTrimmed = false
        var onQuoteTrimmed: ((Bool) -> Void)?

        /// Take away the quoted mail when asked and read how tall the laid out message is, by scripts of
        /// Rookery's own: the message's own scripts stay off.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let isQuoteTrimmed = isQuoteTrimmed
            let onQuoteTrimmed = onQuoteTrimmed
            let onHeight = onHeight
            Task { @MainActor in
                if isQuoteTrimmed {
                    let isTrimmed = try? await webView.callAsyncJavaScript(MailQuote.trimScript, contentWorld: .defaultClient)
                    onQuoteTrimmed?((isTrimmed as? Bool) ?? false)
                }
                guard let onHeight else {
                    return
                }
                let height = try? await webView.callAsyncJavaScript(Self.heightScript, contentWorld: .defaultClient)
                if let height = height as? Double {
                    onHeight(CGFloat(height))
                }
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

    override func scrollWheel(with event: NSEvent) {
        if isScrollingOuter {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

