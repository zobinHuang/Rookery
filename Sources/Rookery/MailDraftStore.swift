import Foundation
import Observation
import os
import RookeryCore

/// The mails being written in Rookery, Raven's drafts among them, kept in the data directory, readable only
/// by the user since they hold mail: read once, written soon after each change, as the user types.
@MainActor
@Observable
final class MailDraftStore {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    /// How long after the last change the drafts are written.
    private static let saveDelay: Duration = .milliseconds(600)
    private static let fileMode = 0o600

    private(set) var box = MailDraftBox()
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directory: URL = DataDirectory.url) {
        fileURL = directory.appending(path: MailDraftBox.fileName)
        load()
    }

    var listDrafts: [MailReplyDraft] {
        box.listDrafts
    }

    func draft(_ draftId: String) -> MailReplyDraft? {
        box.draft(draftId)
    }

    /// Keep a draft, unless one from the same proposal is kept already.
    ///
    /// - Returns: whether it was added
    @discardableResult
    func add(_ draft: MailReplyDraft) -> Bool {
        let isAdded = box.add(draft)
        if isAdded {
            saveSoon()
        }
        return isAdded
    }

    func update(_ draft: MailReplyDraft) {
        box.update(draft)
        saveSoon()
    }

    func remove(_ draftId: String) {
        box.remove(draftId)
        saveSoon()
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else {
                return
            }
            self?.save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }
        do {
            box = try JSONDecoder().decode(MailDraftBox.self, from: data)
        } catch {
            Self.logger.error("cannot read the mail drafts: \(error, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(box).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("cannot keep the mail drafts: \(error, privacy: .public)")
        }
    }
}
