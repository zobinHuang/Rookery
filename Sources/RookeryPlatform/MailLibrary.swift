import Foundation
import RookeryCore
import SQLite3

/// A failure to read Mail's local library.
public enum MailLibraryError: Error, CustomStringConvertible {
    /// No Mail library on this Mac, or none this process may see.
    case notFound(String)
    /// The process lacks Full Disk Access, which Mail's library needs.
    case noAccess(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .notFound(let reason): "no Mail library: \(reason)"
        case .noAccess(let reason): "Rookery needs Full Disk Access to read Mail: \(reason)"
        case .sqlite(let reason): "cannot read Mail's library: \(reason)"
        }
    }
}

/// Mail's local library: the index database (`Envelope Index`) of every message Mail synced, under
/// `~/Library/Mail/V<n>/MailData`, and the message files beside it. Opened read-only, so Mail keeps
/// syncing as before; Mail's schema is not documented, so callers check `tables()` against what they read.
public final class MailLibrary: @unchecked Sendable {
    // The connection is used from one task at a time, by the actor that owns the library.
    private static let indexName = "Envelope Index"
    private static let versionPrefix = "V"

    /// The library's directory, `~/Library/Mail/V<n>`.
    public let root: URL
    private let database: OpaquePointer

    /// The newest Mail library on this Mac.
    ///
    /// - Throws: `MailLibraryError.noAccess` without Full Disk Access, `.notFound` when there is none
    public static func locate() throws -> URL {
        let mail = URL.homeDirectory.appending(path: "Library/Mail", directoryHint: .isDirectory)
        let listNames: [String]
        do {
            listNames = try FileManager.default.contentsOfDirectory(atPath: mail.path)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw MailLibraryError.noAccess(error.localizedDescription)
        } catch {
            throw MailLibraryError.notFound(error.localizedDescription)
        }
        let listVersions = listNames.compactMap { name -> Int? in
            name.hasPrefix(versionPrefix) ? Int(name.dropFirst(versionPrefix.count)) : nil
        }
        guard let newest = listVersions.max() else {
            throw MailLibraryError.notFound("Mail has never synced an account here")
        }
        return mail.appending(path: "\(versionPrefix)\(newest)", directoryHint: .isDirectory)
    }

    /// Open the library read-only.
    ///
    /// - Parameter root: the library's directory, as `locate()` finds it
    /// - Throws: `MailLibraryError`
    public init(root: URL) throws {
        let indexURL = root.appending(path: "MailData").appending(path: Self.indexName)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(indexURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(handle)
            if status == SQLITE_CANTOPEN || status == SQLITE_PERM || status == SQLITE_AUTH {
                throw MailLibraryError.noAccess(reason)
            }
            throw MailLibraryError.sqlite(reason)
        }
        sqlite3_busy_timeout(handle, 2000)
        self.root = root
        database = handle
    }

    deinit {
        sqlite3_close(database)
    }

    /// Every table, with its columns and row count.
    ///
    /// - Throws: `MailLibraryError.sqlite`
    public func tables() throws -> [MailTableShape] {
        let listNames = try rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap { $0.first ?? nil }
        return try listNames.map { name in
            let listColumns = try rows("PRAGMA table_info(\"\(name)\")").compactMap { $0.count > 1 ? $0[1] : nil }
            let count = try rows("SELECT COUNT(*) FROM \"\(name)\"").first?.first.flatMap { $0 }.flatMap(Int.init) ?? 0
            return MailTableShape(name: name, listColumns: listColumns, rowCount: count)
        }
    }

    /// Run a query and read every row as text, a nil for each SQL NULL.
    ///
    /// - Parameters:
    ///   - sql: the query
    ///   - listBindings: values for its `?` placeholders, in order
    /// - Throws: `MailLibraryError.sqlite`
    public func rows(_ sql: String, _ listBindings: [String] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MailLibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in listBindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var listRows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw MailLibraryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            let columnCount = sqlite3_column_count(statement)
            listRows.append((0..<columnCount).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return listRows
    }
}
