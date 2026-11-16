import RookeryPlatform
import Testing

struct RoostEndpointTests {
    @Test func takesAddressesAsPeopleTypeThem() throws {
        #expect(try RoostEndpoint(address: "studio.local:8787", token: "t").baseURL.absoluteString == "http://studio.local:8787")
        #expect(try RoostEndpoint(address: " https://roost.example.com/v1/ ", token: "t").baseURL.absoluteString == "https://roost.example.com")
    }

    @Test func refusesWhatIsNotAWebAddress() {
        #expect(throws: RoostError.self) {
            try RoostEndpoint(address: "ftp://example.com", token: "t")
        }
        #expect(throws: RoostError.self) {
            try RoostEndpoint(address: "", token: "t")
        }
    }
}
