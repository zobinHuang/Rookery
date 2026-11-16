import RookeryCore
import Testing

struct RecentPlacesTests {
    /// The user is at X, which no switch ever noted, and switches X to Y to Z: X is next after Y.
    @Test func keepsTheWindowTheUserLeftNextWhenItWasNeverNoted() {
        var places = RecentPlaces()
        let listOffered = ["A", "B", "X", "Y", "Z"]
        var current = "X"
        for target in ["Y", "Z"] {
            places.note(current)
            #expect(places.ordered(listOffered, current: current).first == current)
            places.note(target)
            current = target
        }
        places.note(current)
        #expect(places.ordered(listOffered, current: current) == ["Z", "Y", "X", "A", "B"])
    }

    @Test func listsTheCurrentPlaceFirstEvenIfNeverNoted() {
        var places = RecentPlaces()
        places.note("A")
        #expect(places.ordered(["A", "B", "C"], current: "C") == ["C", "A", "B"])
    }

    @Test func movesANotedPlaceToTheFrontOnce() {
        var places = RecentPlaces()
        places.note("A")
        places.note("B")
        places.note("A")
        #expect(places.listIds == ["A", "B"])
    }

    @Test func forgetsPlacesThatAreGone() {
        var places = RecentPlaces()
        places.note("A")
        places.note("B")
        places.prune(keeping: ["A"])
        #expect(places.listIds == ["A"])
    }
}
