import Foundation

/// The stable identifier of a quick note.
public struct NoteId: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new identifier no other note has.
    public static func make() -> NoteId {
        NoteId(rawValue: UUID().uuidString)
    }

    public var description: String {
        rawValue
    }
}

/// A short note kept in the sidebar.
public struct QuickNote: Codable, Equatable, Sendable, Identifiable {
    public let noteId: NoteId
    public var text: String
    /// When the text last changed.
    public var modifiedAt: Date

    public init(noteId: NoteId, text: String, modifiedAt: Date) {
        self.noteId = noteId
        self.text = text
        self.modifiedAt = modifiedAt
    }

    public var id: NoteId {
        noteId
    }
}

/// The sidebar's quick notes in the order the user keeps them, each new note at the top. A note whose text
/// is left blank is deleted, so there are never empty notes to tidy up.
public struct QuickNoteList: Codable, Equatable, Sendable {
    public private(set) var listNotes: [QuickNote]

    public init(listNotes: [QuickNote] = []) {
        self.listNotes = listNotes
    }

    /// Add a note at the top.
    ///
    /// - Parameters:
    ///   - text: the note's text, which may be blank while it is first written
    ///   - date: when it was written
    /// - Returns: the new note's identifier
    @discardableResult
    public mutating func add(text: String, at date: Date) -> NoteId {
        let noteId = NoteId.make()
        listNotes.insert(QuickNote(noteId: noteId, text: text, modifiedAt: date), at: 0)
        return noteId
    }

    /// Change a note's text in place, or delete the note when the text is blank.
    ///
    /// - Parameters:
    ///   - noteId: the note
    ///   - text: its new text
    ///   - date: when it was changed
    /// - Returns: whether anything changed
    @discardableResult
    public mutating func update(_ noteId: NoteId, text: String, at date: Date) -> Bool {
        guard let noteIndex = listNotes.firstIndex(where: { $0.noteId == noteId }) else {
            return false
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            listNotes.remove(at: noteIndex)
            return true
        }
        guard listNotes[noteIndex].text != trimmedText else {
            return false
        }
        listNotes[noteIndex].text = trimmedText
        listNotes[noteIndex].modifiedAt = date
        return true
    }

    /// Move a note to just before another, or to the end with nil.
    ///
    /// - Returns: whether the order changed
    @discardableResult
    public mutating func move(_ noteId: NoteId, before targetNoteId: NoteId?) -> Bool {
        guard
            noteId != targetNoteId,
            let sourceIndex = listNotes.firstIndex(where: { $0.noteId == noteId })
        else {
            return false
        }
        let listOldIds = listNotes.map(\.noteId)
        let note = listNotes.remove(at: sourceIndex)
        let targetIndex = targetNoteId.flatMap { targetNoteId in
            listNotes.firstIndex { $0.noteId == targetNoteId }
        } ?? listNotes.endIndex
        listNotes.insert(note, at: targetIndex)
        return listNotes.map(\.noteId) != listOldIds
    }

    /// Delete a note.
    ///
    /// - Returns: whether the note was there
    @discardableResult
    public mutating func remove(_ noteId: NoteId) -> Bool {
        let countBefore = listNotes.count
        listNotes.removeAll { $0.noteId == noteId }
        return listNotes.count != countBefore
    }
}
