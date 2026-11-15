import Foundation
import os

/// The registration that lets Chrome start MuxShots' native messaging host for the MuxShots extension: a
/// manifest in Chrome's per-user host directory pointing at the host inside this app.
enum ChromeNativeHost {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "chrome")
    /// The host's name, which the extension connects to.
    private static let hostName = "io.github.zobinhuang.muxshots"
    private static let executableName = "muxshots-chrome-host"
    /// The extension's id, fixed by the public key in its manifest.
    private static let extensionId = "lgpadonpeijgfofmlgpgncedeflfifdp"
    private static let chromeDirectory = URL.applicationSupportDirectory.appending(path: "Google/Chrome", directoryHint: .isDirectory)

    /// Register the host with Chrome, if Chrome is set up for this user and the registration is not current.
    static func register() {
        let hostDirectory = chromeDirectory.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
        let manifestUrl = hostDirectory.appending(path: "\(hostName).json", directoryHint: .notDirectory)
        let executableUrl = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(executableName)", directoryHint: .notDirectory)
        guard
            FileManager.default.fileExists(atPath: chromeDirectory.path),
            FileManager.default.isExecutableFile(atPath: executableUrl.path)
        else {
            return
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "MuxShots mixer",
            "path": executableUrl.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionId)/"],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            guard (try? Data(contentsOf: manifestUrl)) != data else {
                return
            }
            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
            try data.write(to: manifestUrl, options: .atomic)
        } catch {
            logger.error("cannot register the Chrome host: \(error)")
        }
    }
}
