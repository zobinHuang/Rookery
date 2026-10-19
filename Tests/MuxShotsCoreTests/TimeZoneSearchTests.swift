import Foundation
import MuxShotsCore
import Testing

struct TimeZoneSearchTests {
    @Test func findsUtcByItsNames() {
        for query in ["UTC", "utc", "GMT", "Z", "UTC+0"] {
            #expect(TimeZoneSearch.listMatches(for: query).first == TimeZoneMatch(name: "UTC", timeZoneId: "UTC"))
        }
    }

    @Test func findsFixedOffsetsFromUtc() throws {
        let plusEight = try #require(TimeZoneSearch.listMatches(for: "UTC+8").first)
        let minusFiveThirty = try #require(TimeZoneSearch.listMatches(for: "gmt-5:30").first)

        #expect(plusEight.name == "UTC+8")
        #expect(TimeZone(identifier: plusEight.timeZoneId)?.secondsFromGMT() == 8 * 3600)
        #expect(minusFiveThirty.name == "UTC-5:30")
        #expect(TimeZone(identifier: minusFiveThirty.timeZoneId)?.secondsFromGMT() == -(5 * 3600 + 30 * 60))
    }

    @Test func findsZonesByAbbreviationAndName() {
        #expect(TimeZoneSearch.listMatches(for: "PST").contains { $0.name == "Pacific Time" })
        #expect(TimeZoneSearch.listMatches(for: "pacific").contains { $0.name == "Pacific Time" })
    }

    @Test func ignoresWhatNamesNoZone() {
        #expect(TimeZoneSearch.listMatches(for: "UTC+99").isEmpty)
        #expect(TimeZoneSearch.listMatches(for: " ").isEmpty)
    }
}
