import RookeryCore
import Testing

/// The sayings the launcher shows beside Raven.
struct RavenMaximsTests {
    /// The most characters a saying keeps, so it fits the launcher's row in two lines at most.
    private static let lengthLimit = 80

    @Test func everySayingIsShortAndNamedForWhoSaidIt() {
        #expect(RavenMaxims.listMaxims.count >= 30)
        for maxim in RavenMaxims.listMaxims {
            #expect(maxim.text.count <= Self.lengthLimit, "\(maxim.text)")
            #expect(!maxim.author.isEmpty)
        }
        #expect(Set(RavenMaxims.listMaxims.map(\.text)).count == RavenMaxims.listMaxims.count)
    }

    @Test func aSayingIsPickedFromTheList() {
        var generator = SystemRandomNumberGenerator()
        #expect(RavenMaxims.listMaxims.contains(RavenMaxims.random(using: &generator)))
    }
}
