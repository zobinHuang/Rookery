import AppKit
import os
import SwiftUI
import WebKit

/// A message's HTML shown as its sender formatted it, safely: no script runs, nothing is fetched from the
/// network unless the user lets this message load its images, and a link opens in the browser rather than
/// here.
struct MailHTMLView: NSViewRepresentable {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    private static let remoteRuleIdentifier = "rookery-block-remote"
    private static let remoteRule = #"[{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}}]"#

    let html: String
    /// Whether the message may fetch its images and other remote content.
    let isRemoteAllowed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(isRemoteAllowed)\(html.hashValue)"
        guard context.coordinator.loadedKey != key else {
            return
        }
        context.coordinator.loadedKey = key
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
        var loadedKey = ""

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
