import Foundation

/// An application installed on the Mac, as the launcher finds it: the name Finder shows, in the user's
/// language, the name its bundle gives when that differs, as WeChat for 微信, its bundle and its id.
public struct InstalledApplication: Hashable, Identifiable, Sendable {
    /// The folders applications are installed in, searched one level deep, and the system's own folders.
    private static let listFolderPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]
    /// Applications outside those folders the user reaches every day.
    private static let listExtraPaths = ["/System/Library/CoreServices/Finder.app"]
    private static let applicationExtension = "app"

    public let name: String
    /// The bundle's own name, when it differs from `name`; empty otherwise.
    public let alternateName: String
    public let url: URL
    public let bundleId: String?

    public var id: String {
        url.path
    }

    public init(name: String, alternateName: String, url: URL, bundleId: String?) {
        self.name = name
        self.alternateName = alternateName
        self.url = url
        self.bundleId = bundleId
    }

    /// Every application in the folders applications are installed in, by name, each once.
    ///
    /// - Returns: the applications
    public static func scan() -> [InstalledApplication] {
        let fileManager = FileManager.default
        var setSeenIds: Set<String> = []
        var listApplications: [InstalledApplication] = []
        var listURLs: [URL] = listExtraPaths.map { URL(filePath: $0) }
        for folderPath in listFolderPaths {
            let folder = URL(filePath: folderPath, directoryHint: .isDirectory)
            let listEntries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            listURLs += listEntries.filter { $0.pathExtension == applicationExtension }
        }
        for url in listURLs where fileManager.fileExists(atPath: url.path) {
            let bundle = Bundle(url: url)
            let bundleId = bundle?.bundleIdentifier
            let key = bundleId ?? url.path
            guard !setSeenIds.contains(key) else {
                continue
            }
            setSeenIds.insert(key)
            let shownName = fileManager.displayName(atPath: url.path).replacing(".\(applicationExtension)", with: "")
            let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ""
            listApplications.append(InstalledApplication(
                name: shownName,
                alternateName: bundleName.caseInsensitiveCompare(shownName) == .orderedSame ? "" : bundleName,
                url: url,
                bundleId: bundleId
            ))
        }
        return listApplications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
