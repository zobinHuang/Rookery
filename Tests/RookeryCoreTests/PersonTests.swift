import RookeryCore
import Testing

struct PersonTests {
    private static let alex = Person(id: "a", name: "Alex Chen", listAddresses: ["alex@work.com", "Alex@Home.org"])
    private static let al = Person(id: "b", name: "Al", listAddresses: ["al@x.com"])
    private static let book = PeopleBook(listPeople: [alex, al])

    @Test func anAddressFindsItsPersonInAnyCase() {
        #expect(Self.book.person(withAddress: "ALEX@home.org") == Self.alex)
        #expect(Self.book.person(withAddress: "nobody@x.com") == nil)
    }

    @Test func aMentionIsTheNameAsOneWordAndALongerNameIsNotTakenForAShorterOne() {
        #expect(Self.alex.mentionToken == "@Alex-Chen")
        let text = "ask @Alex-Chen and @Al, then @alex-chen again"
        #expect(Self.book.people(mentionedIn: text) == [Self.alex, Self.al])
        #expect(Self.book.mentionRanges(in: text).map { String(text[$0.range]) } == ["@Alex-Chen", "@Al", "@alex-chen"])
        #expect(Self.book.people(mentionedIn: "mail @Alexander") == [])
    }

    @Test func suggestionsMatchNameOrAddressNamesStartingWithItFirst() {
        #expect(Self.book.suggestions(for: "al", limit: 5) == [Self.al, Self.alex])
        #expect(Self.book.suggestions(for: "home", limit: 5) == [Self.alex])
        #expect(Self.book.suggestions(for: "alex-ch", limit: 5) == [Self.alex])
    }

    @Test func choosingAPersonWritesTheirMention() {
        #expect(Mentions.complete("tell @ale", with: Self.alex) == "tell @Alex-Chen ")
        #expect(Person.initials(of: "zhuobin.huang@x.com") == "ZH")
    }
}
