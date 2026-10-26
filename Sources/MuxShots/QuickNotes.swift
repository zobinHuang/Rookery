import Foundation
import MuxShotsCore
import Observation
import os

/// The quick notes every stage's sidebar shows, saved beside the workspace whenever one changes.
@MainActor
@Observable
final class QuickNotes {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.muxshots", category: "notes")
    nonisolated private static let directoryName = "MuxShots"
    nonisolated private static let fileName = "notes.json"

    /// Where the notes are kept: beside the workspace.
    nonisolated static var defaultFileUrl: URL {
        URL.applicationSupportDirectory
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    private let fileUrl: URL
    private var notes: QuickNoteList

    /// Load the saved notes; none on first launch or when the file cannot be read.
    ///
    /// - Parameter fileUrl: the file the notes are read from and saved to
    init(fileUrl: URL = defaultFileUrl) {
        self.fileUrl = fileUrl
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            notes = FileManager.default.fileExists(atPath: fileUrl.path)
                ? try decoder.decode(QuickNoteList.self, from: Data(contentsOf: fileUrl))
                : QuickNoteList()
        } catch {
            Self.logger.error("cannot read the notes: \(error, privacy: .public)")
            notes = QuickNoteList()
        }
    }

    /// The notes in the user's order.
    var listNotes: [QuickNote] {
        notes.listNotes
    }

    /// Start a new, blank note at the top; it is deleted unless text is written into it or it leads to a tab.
    ///
    /// - Parameter link: the tab the note leads to, if any
    /// - Returns: the new note's identifier
    func add(linkedTo link: NoteLink? = nil) -> NoteId {
        let noteId = notes.add(text: "", link: link, at: Date())
        if link != nil {
            save()
        }
        return noteId
    }

    /// Change a note's text, deleting the note when the text is blank.
    func update(_ noteId: NoteId, text: String) {
        if notes.update(noteId, text: text, at: Date()) {
            save()
        }
    }

    /// Make a note lead to a tab, or to none with nil.
    func link(_ noteId: NoteId, to link: NoteLink?) {
        if notes.link(noteId, to: link, at: Date()) {
            save()
        }
    }

    /// Move a note to just before another, or to the end with nil.
    func move(_ noteId: NoteId, before targetNoteId: NoteId?) {
        if notes.move(noteId, before: targetNoteId) {
            save()
        }
    }

    func remove(_ noteId: NoteId) {
        if notes.remove(noteId) {
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileUrl.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(notes).write(to: fileUrl, options: .atomic)
        } catch {
            Self.logger.error("cannot save the notes: \(error, privacy: .public)")
        }
    }
}
