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

/// A tab a note leads to: clicking the note switches to the tab's group and brings the tab to the front.
public struct NoteLink: Codable, Equatable, Sendable {
    /// The tab's window.
    public let windowId: WindowId
    /// The group the tab was in when it was linked, shown instead once the tab has closed.
    public let groupId: GroupId
    /// The tab's name when it was linked, shown once the tab has closed.
    public let name: String
    /// The application of the tab's window.
    public let bundleId: String?

    public init(windowId: WindowId, groupId: GroupId, name: String, bundleId: String?) {
        self.windowId = windowId
        self.groupId = groupId
        self.name = name
        self.bundleId = bundleId
    }
}

/// A short note kept in the sidebar.
public struct QuickNote: Codable, Equatable, Sendable, Identifiable {
    public let noteId: NoteId
    public var text: String
    /// When the text or the link last changed.
    public var modifiedAt: Date
    /// The tab the note leads to; nil for a note that is only text.
    public var link: NoteLink?

    public init(noteId: NoteId, text: String, modifiedAt: Date, link: NoteLink? = nil) {
        self.noteId = noteId
        self.text = text
        self.modifiedAt = modifiedAt
        self.link = link
    }

    public var id: NoteId {
        noteId
    }
}

/// The sidebar's quick notes in the order the user keeps them, each new note at the top. A note whose text
/// is left blank is deleted unless it links to a tab, so there are never empty notes to tidy up.
public struct QuickNoteList: Codable, Equatable, Sendable {
    public private(set) var listNotes: [QuickNote]

    public init(listNotes: [QuickNote] = []) {
        self.listNotes = listNotes
    }

    /// Add a note at the top.
    ///
    /// - Parameters:
    ///   - text: the note's text, which may be blank while it is first written
    ///   - link: the tab the note leads to, if any
    ///   - date: when it was written
    /// - Returns: the new note's identifier
    @discardableResult
    public mutating func add(text: String, link: NoteLink? = nil, at date: Date) -> NoteId {
        let noteId = NoteId.make()
        listNotes.insert(QuickNote(noteId: noteId, text: text, modifiedAt: date, link: link), at: 0)
        return noteId
    }

    /// Change a note's text in place, or delete the note when the text is blank and it links to no tab.
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
        guard
            !trimmedText.isEmpty
            || listNotes[noteIndex].link != nil
        else {
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

    /// Make a note lead to a tab, or to none with nil; a note left with neither text nor a link is deleted.
    ///
    /// - Parameters:
    ///   - noteId: the note
    ///   - link: the tab it leads to from now on
    ///   - date: when it was changed
    /// - Returns: whether anything changed
    @discardableResult
    public mutating func link(_ noteId: NoteId, to link: NoteLink?, at date: Date) -> Bool {
        guard
            let noteIndex = listNotes.firstIndex(where: { $0.noteId == noteId }),
            listNotes[noteIndex].link != link
        else {
            return false
        }
        guard
            link != nil
            || !listNotes[noteIndex].text.isEmpty
        else {
            listNotes.remove(at: noteIndex)
            return true
        }
        listNotes[noteIndex].link = link
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
