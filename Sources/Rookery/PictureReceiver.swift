import AppKit
import os
import WebKit

/// Plays a browser tab's video streamed over WebRTC on this machine, in a web view of its own: the system's
/// WebRTC answers the browser's offer, and the video it receives is decoded and drawn by the system, so the
/// app never handles a frame.
@MainActor
final class PictureReceiver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "picture")
    private static let messageHandlerName = "muxshots"
    /// A secure origin for the page, which WebRTC requires; nothing is loaded from it.
    private static let pageBaseUrl = URL(string: "https://localhost/")
    private static let page = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; height: 100%; overflow: hidden; background: #000; }
        video { width: 100%; height: 100%; object-fit: contain; }
        </style>
        </head>
        <body>
        <video autoplay playsinline muted></video>
        <script>
        const video = document.querySelector("video");
        const post = (message) => window.webkit.messageHandlers.muxshots.postMessage(message);
        let connection;
        video.addEventListener("resize", () => post({ type: "size", width: video.videoWidth, height: video.videoHeight }));
        video.addEventListener("playing", async () => {
            post({ type: "playing" });
            const stats = await connection.getStats();
            stats.forEach((report) => {
                if (report.type === "codec") { post({ type: "codec", mimeType: report.mimeType }); }
            });
            setTimeout(async () => {
                (await connection.getStats()).forEach((report) => {
                    if (report.type === "inbound-rtp") {
                        post({
                            type: "stats",
                            text: `packets ${report.packetsReceived} frames ${report.framesReceived} decoded ${report.framesDecoded} `
                                + `dropped ${report.framesDropped} decoder ${report.decoderImplementation} size ${report.frameWidth}x${report.frameHeight}`,
                        });
                    }
                });
            }, 3000);
        });
        async function answer(offer) {
            connection?.close();
            connection = new RTCPeerConnection();
            connection.ontrack = (event) => { video.srcObject = event.streams[0] ?? new MediaStream([event.track]); };
            connection.onconnectionstatechange = () => post({ type: "connection", state: connection.connectionState });
            await connection.setRemoteDescription({ type: "offer", sdp: offer });
            await connection.setLocalDescription(await connection.createAnswer());
            if (connection.iceGatheringState !== "complete") {
                await new Promise((resolve) => {
                    const timer = setTimeout(resolve, 2000);
                    connection.onicegatheringstatechange = () => {
                        if (connection.iceGatheringState === "complete") { clearTimeout(timer); resolve(); }
                    };
                });
            }
            return connection.localDescription.sdp;
        }
        </script>
        </body>
        </html>
        """

    /// The view the video plays in.
    let webView: WKWebView
    /// Called with the video's size in pixels once known, and whenever it changes.
    var onSize: ((CGSize) -> Void)?
    /// Called once the first frame plays.
    var onPlaying: (() -> Void)?
    /// Called when the connection fails, as when the browser's side went away.
    var onFailure: (() -> Void)?
    private var isLoaded = false
    private var listLoadWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: Self.messageHandlerName)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.loadHTMLString(Self.page, baseURL: Self.pageBaseUrl)
    }

    /// Stop playing and let the view go.
    func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.loadHTMLString("", baseURL: nil)
        onSize = nil
        onPlaying = nil
        onFailure = nil
    }

    /// Accept a browser's offer of its video.
    ///
    /// - Parameter offer: the offer's session description
    /// - Returns: the answer's session description, to send back to the browser
    /// - Throws: the page's error, as when the offer cannot be read
    func answer(_ offer: String) async throws -> String {
        if !isLoaded {
            await withCheckedContinuation { continuation in
                listLoadWaiters.append(continuation)
            }
        }
        let result = try await webView.callAsyncJavaScript(
            "return await answer(offer);",
            arguments: ["offer": offer],
            contentWorld: .page
        )
        return result as? String ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isLoaded else {
            return
        }
        isLoaded = true
        for waiter in listLoadWaiters {
            waiter.resume()
        }
        listLoadWaiters = []
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return
        }
        switch type {
        case "size":
            if let width = body["width"] as? Double, let height = body["height"] as? Double, width > 0, height > 0 {
                onSize?(CGSize(width: width, height: height))
            }
        case "playing":
            onPlaying?()
        case "stats":
            Self.logger.info("video \(body["text"] as? String ?? "?", privacy: .public)")
        case "codec":
            Self.logger.info("video codec \(body["mimeType"] as? String ?? "?", privacy: .public)")
        case "connection":
            Self.logger.info("video connection \(body["state"] as? String ?? "?", privacy: .public)")
            if let state = body["state"] as? String, state == "failed" || state == "closed" {
                onFailure?()
            }
        default:
            break
        }
    }
}
