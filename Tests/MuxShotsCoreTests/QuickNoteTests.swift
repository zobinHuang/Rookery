import Foundation
import MuxShotsCore
import Testing

struct QuickNoteTests {
    static let start = Date(timeIntervalSince1970: 1_000)
    static let later = Date(timeIntervalSince1970: 2_000)

    @Test func addingPutsTheNewestNoteFirst() {
        var notes = QuickNoteList()
        notes.add(text: "first", at: Self.start)
        notes.add(text: "second", at: Self.later)

        #expect(notes.listNotes.map(\.text) == ["second", "first"])
    }

    @Test func updatingTrimsTheTextAndKeepsThePlace() {
        var notes = QuickNoteList()
        let firstId = notes.add(text: "first", at: Self.start)
        notes.add(text: "second", at: Self.start)

        let isChanged = notes.update(firstId, text: "  call back \n", at: Self.later)

        #expect(isChanged)
        #expect(notes.listNotes.map(\.text) == ["second", "call back"])
        #expect(notes.listNotes[1].modifiedAt == Self.later)
    }

    @Test func updatingToTheSameTextChangesNothing() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "same", at: Self.start)

        let isChanged = notes.update(noteId, text: "same ", at: Self.later)

        #expect(!isChanged)
        #expect(notes.listNotes[0].modifiedAt == Self.start)
    }

    @Test func blankingANoteDeletesIt() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "", at: Self.start)

        let isChanged = notes.update(noteId, text: " \n ", at: Self.later)

        #expect(isChanged)
        #expect(notes.listNotes.isEmpty)
    }

    @Test func removingAnUnknownNoteReportsNothing() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "keep", at: Self.start)

        let isUnknownRemoved = notes.remove(NoteId.make())
        let isKnownRemoved = notes.remove(noteId)

        #expect(!isUnknownRemoved)
        #expect(isKnownRemoved)
        #expect(notes.listNotes.isEmpty)
    }

    @Test func movingPlacesANoteBeforeTheTargetOrLast() {
        var notes = QuickNoteList()
        let cId = notes.add(text: "c", at: Self.start)
        let bId = notes.add(text: "b", at: Self.start)
        let aId = notes.add(text: "a", at: Self.start)

        let isMovedDown = notes.move(aId, before: cId)
        #expect(isMovedDown)
        #expect(notes.listNotes.map(\.text) == ["b", "a", "c"])

        let isMovedLast = notes.move(bId, before: nil)
        #expect(isMovedLast)
        #expect(notes.listNotes.map(\.text) == ["a", "c", "b"])
    }

    @Test func movingANoteOntoItsOwnPlaceChangesNothing() {
        var notes = QuickNoteList()
        let bId = notes.add(text: "b", at: Self.start)
        let aId = notes.add(text: "a", at: Self.start)

        let isMovedOntoItself = notes.move(aId, before: aId)
        let isMovedBeforeNext = notes.move(aId, before: bId)
        let isLastMovedLast = notes.move(bId, before: nil)

        #expect(!isMovedOntoItself)
        #expect(!isMovedBeforeNext)
        #expect(!isLastMovedLast)
        #expect(notes.listNotes.map(\.text) == ["a", "b"])
    }

    @Test func notesSurviveEncoding() throws {
        var notes = QuickNoteList()
        notes.add(text: "milk\neggs", at: Self.start)

        let decoded = try JSONDecoder().decode(QuickNoteList.self, from: JSONEncoder().encode(notes))
        #expect(decoded == notes)
    }
}
