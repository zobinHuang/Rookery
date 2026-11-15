import Foundation
import os
import RookeryCore

/// Carries over what the app saved while it was called MuxShots, once, before anything reads it: the
/// settings, kept under the old bundle identifier, and the data directory with the workspace and the quick
/// notes. Neither is taken when Rookery already has its own; the old settings are left in place.
enum MuxShotsMigration {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "app")
    private static let legacyBundleId = "io.github.zobinhuang.muxshots"
    private static let legacyDirectoryName = "MuxShots"

    /// Carry the settings and the data directory over, where Rookery has none yet.
    static func run() {
        moveDataDirectory()
        copySettings()
    }

    private static func moveDataDirectory() {
        let fileManager = FileManager.default
        let legacyUrl = URL.applicationSupportDirectory.appending(path: legacyDirectoryName, directoryHint: .isDirectory)
        guard
            fileManager.fileExists(atPath: legacyUrl.path)
            && !fileManager.fileExists(atPath: DataDirectory.url.path)
        else {
            return
        }
        do {
            try fileManager.moveItem(at: legacyUrl, to: DataDirectory.url)
            logger.info("moved the data directory over from \(legacyDirectoryName, privacy: .public)")
        } catch {
            logger.error("cannot move the data directory over from \(legacyDirectoryName, privacy: .public): \(error)")
        }
    }

    private static func copySettings() {
        guard
            let bundleId = Bundle.main.bundleIdentifier,
            bundleId != legacyBundleId,
            UserDefaults.standard.persistentDomain(forName: bundleId)?.isEmpty ?? true,
            let mapLegacySettings = UserDefaults.standard.persistentDomain(forName: legacyBundleId),
            !mapLegacySettings.isEmpty
        else {
            return
        }
        UserDefaults.standard.setPersistentDomain(mapLegacySettings, forName: bundleId)
        logger.info("copied \(mapLegacySettings.count) settings over from \(legacyBundleId, privacy: .public)")
    }
}
