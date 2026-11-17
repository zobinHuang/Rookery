import AppKit
import os
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

    let html: String
    /// Whether the message may fetch its images and other remote content.
    let isRemoteAllowed: Bool
    /// Told the height the message's content needs once it is laid out; nil to scroll inside the view.
    var onHeight: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = MailWebView(frame: .zero, configuration: configuration)
        view.isScrollingOuter = onHeight != nil
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(isRemoteAllowed)\(html.hashValue)"
        guard context.coordinator.loadedKey != key else {
            return
        }
        context.coordinator.loadedKey = key
        context.coordinator.onHeight = onHeight
        let html = html
        let isRemoteAllowed = isRemoteAllowed
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: Self.remoteRuleIdentifier,
            encodedContentRuleList: Self.remoteRule
        ) { list, error in
            MainActor.assumeIsolated {
                view.configuration.userContentController.removeAllContentRuleLists()
                if !isRemoteAllowed {
                    guard let list else {
                        Self.logger.error("cannot block remote content: \(String(describing: error), privacy: .public)")
                        view.loadHTMLString("<p>Rookery could not show this message safely.</p>", baseURL: nil)
                        return
                    }
                    view.configuration.userContentController.add(list)
                }
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
        private static let heightScript = "return Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"

        var loadedKey = ""
        var onHeight: ((CGFloat) -> Void)?

        /// Read how tall the laid out message is, by a script of Rookery's own: the message's own scripts
        /// stay off.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let onHeight else {
                return
            }
            Task { @MainActor in
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

