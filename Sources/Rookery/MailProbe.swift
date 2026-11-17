import Foundation
import RookeryControl
import RookeryCore
import RookeryPlatform

/// What the app can read of Mail and the calendars, as `rookeryctl mail probe` reports it: the library's
/// shape, a few mailboxes' URLs and message files' paths, the accounts and the calendars. It reads no
/// message's content, and asks for calendar access and for control of Mail the first time.
enum MailProbe {
    private static let mailboxSampleLimit = 40
    private static let messagePathSampleLimit = 12

    static func run() async -> MailProbeReport {
        var report = MailProbeReport()
        do {
            let root = try MailLibrary.locate()
            report.libraryPath = root.path
            let library = try MailLibrary(root: root)
            report.listTables = try library.tables()
            report.listMailboxURLs = (try? library.rows("SELECT url FROM mailboxes LIMIT \(mailboxSampleLimit)"))?
                .compactMap { $0.first ?? nil } ?? []
            report.listMessagePaths = messagePaths(under: root)
        } catch {
            report.listProblems.append(String(describing: error))
        }
        do {
            report.listAccounts = try await MainActor.run { try MailScripting.accounts() }
        } catch {
            report.listProblems.append(String(describing: error))
        }
        let calendars = CalendarLibrary()
        _ = await calendars.requestAccess()
        report.calendarAuthorization = CalendarLibrary.authorization
        do {
            report.listCalendars = try calendars.calendars()
        } catch {
            report.listProblems.append(String(describing: error))
        }
        return report
    }

    /// Some message files' paths, relative to the library, found by walking it until enough turn up.
    private static func messagePaths(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var listPaths: [String] = []
        while let url = enumerator.nextObject() as? URL, listPaths.count < messagePathSampleLimit {
            if url.lastPathComponent.hasSuffix(".emlx") {
                listPaths.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return listPaths
    }
}
