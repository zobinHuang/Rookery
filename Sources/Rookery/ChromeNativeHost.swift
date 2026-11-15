import Foundation
import os

/// The registration that lets Chrome start Rookery's native messaging host for the Rookery extension: a
/// manifest in Chrome's per-user host directory pointing at the host inside this app.
enum ChromeNativeHost {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "chrome")
    /// The host's name, which the extension connects to.
    private static let hostName = "io.github.zobinhuang.rookery"
    /// The host's name while the app was called MuxShots, whose registration points at an app now gone.
    private static let legacyHostName = "io.github.zobinhuang.muxshots"
    private static let executableName = "rookery-chrome-host"
    /// The extension's id, fixed by the public key in its manifest.
    private static let extensionId = "lgpadonpeijgfofmlgpgncedeflfifdp"
    private static let chromeDirectory = URL.applicationSupportDirectory.appending(path: "Google/Chrome", directoryHint: .isDirectory)

    /// Register the host with Chrome, if Chrome is set up for this user and the registration is not current,
    /// and drop the registration left from when the app was called MuxShots.
    static func register() {
        let hostDirectory = chromeDirectory.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
        let manifestUrl = hostDirectory.appending(path: "\(hostName).json", directoryHint: .notDirectory)
        let legacyManifestUrl = hostDirectory.appending(path: "\(legacyHostName).json", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: legacyManifestUrl.path) {
            do {
                try FileManager.default.removeItem(at: legacyManifestUrl)
            } catch {
                logger.error("cannot remove the Chrome host registered as MuxShots: \(error)")
            }
        }
        let executableUrl = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(executableName)", directoryHint: .notDirectory)
        guard
            FileManager.default.fileExists(atPath: chromeDirectory.path),
            FileManager.default.isExecutableFile(atPath: executableUrl.path)
        else {
            return
        }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Rookery mixer",
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
