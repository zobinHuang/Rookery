import AppKit

/// Application icons by bundle identifier, looked up once per bundle.
@MainActor
enum ApplicationIcon {
    private static var mapIcons: [String: NSImage] = [:]

    /// The icon of an installed application, or nil if no application has the bundle identifier.
    static func icon(forBundleId bundleId: String?) -> NSImage? {
        guard let bundleId else {
            return nil
        }
        if let cached = mapIcons[bundleId] {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        mapIcons[bundleId] = icon
        return icon
    }
}
