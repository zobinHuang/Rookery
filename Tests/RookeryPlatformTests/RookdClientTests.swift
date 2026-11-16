import RookeryPlatform
import Testing

struct RookdEndpointTests {
    @Test func takesAddressesAsPeopleTypeThem() throws {
        #expect(try RookdEndpoint(address: "studio.local:8787", token: "t").baseURL.absoluteString == "http://studio.local:8787")
        #expect(try RookdEndpoint(address: " https://rookd.example.com/v1/ ", token: "t").baseURL.absoluteString == "https://rookd.example.com")
    }

    @Test func refusesWhatIsNotAWebAddress() {
        #expect(throws: RookdError.self) {
            try RookdEndpoint(address: "ftp://example.com", token: "t")
        }
        #expect(throws: RookdError.self) {
            try RookdEndpoint(address: "", token: "t")
        }
    }
}
