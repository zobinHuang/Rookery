import Foundation
import RookeryCore
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

    static let link = NoteLink(
        windowId: WindowId(rawValue: 42),
        groupId: GroupId(rawValue: "work"),
        name: "Inbox",
        bundleId: "com.apple.mail"
    )

    static let otherLink = NoteLink(
        windowId: WindowId(rawValue: 43),
        groupId: GroupId(rawValue: "work"),
        name: "Terminal",
        bundleId: "com.apple.Terminal"
    )

    @Test func linkingAddsTabsInOrderOnce() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "reply", at: Self.start)

        let isAdded = notes.addLink(Self.link, to: noteId, at: Self.later)
        notes.addLink(Self.otherLink, to: noteId, at: Self.later)
        let isAddedAgain = notes.addLink(Self.link, to: noteId, at: Self.later)

        #expect(isAdded)
        #expect(!isAddedAgain)
        #expect(notes.listNotes[0].listLinks == [Self.link, Self.otherLink])
        #expect(notes.listNotes[0].modifiedAt == Self.later)
    }

    @Test func aLinkedNoteSurvivesBlankText() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "", listLinks: [Self.link], at: Self.start)

        notes.update(noteId, text: " ", at: Self.later)

        #expect(notes.listNotes.map(\.text) == [""])
    }

    @Test func removingOneLinkKeepsTheOthers() {
        var notes = QuickNoteList()
        let noteId = notes.add(text: "", listLinks: [Self.link, Self.otherLink], at: Self.start)

        let isRemoved = notes.removeLink(to: Self.link.windowId, from: noteId, at: Self.later)
        let isRemovedAgain = notes.removeLink(to: Self.link.windowId, from: noteId, at: Self.later)

        #expect(isRemoved)
        #expect(!isRemovedAgain)
        #expect(notes.listNotes[0].listLinks == [Self.otherLink])
    }

    @Test func unlinkingABlankNoteDeletesIt() {
        var notes = QuickNoteList()
        let blankId = notes.add(text: "", listLinks: [Self.link, Self.otherLink], at: Self.start)
        let textId = notes.add(text: "keep", listLinks: [Self.link], at: Self.start)

        notes.removeLink(to: nil, from: blankId, at: Self.later)
        notes.removeLink(to: nil, from: textId, at: Self.later)

        #expect(notes.listNotes.map(\.noteId) == [textId])
        #expect(notes.listNotes[0].listLinks.isEmpty)
    }

    @Test func notesSavedBeforeLinksStillLoad() throws {
        let json = #"{"listNotes":[{"noteId":"a","text":"old","modifiedAt":0}]}"#

        let decoded = try JSONDecoder().decode(QuickNoteList.self, from: Data(json.utf8))

        #expect(decoded.listNotes.map(\.text) == ["old"])
        #expect(decoded.listNotes[0].listLinks.isEmpty)
    }

    @Test func aNoteSavedWithOneLinkLoadsIt() throws {
        let json = #"""
            {"listNotes":[{"noteId":"a","text":"","modifiedAt":0,
            "link":{"windowId":42,"groupId":"work","name":"Inbox","bundleId":"com.apple.mail"}}]}
            """#

        let decoded = try JSONDecoder().decode(QuickNoteList.self, from: Data(json.utf8))

        #expect(decoded.listNotes[0].listLinks == [Self.link])
    }
}
