import Foundation
import MapKit
import Observation

/// A city the world clock shows: the name it is shown by, and its time zone in the system's time zone
/// database, which macOS keeps current, daylight saving time included.
struct WorldClockCity: Codable, Hashable, Identifiable, Sendable {
    let name: String
    /// The time zone's identifier, such as "Asia/Shanghai".
    let timeZoneId: String

    var id: String {
        "\(name)|\(timeZoneId)"
    }
}

/// The cities the world clock can show.
enum WorldClock {
    private static let maximumTimeZoneResults = 30

    /// The cities shown before the user picks any: here, then Los Angeles and London.
    static var listDefaultCities: [WorldClockCity] {
        var listIds = [TimeZone.current.identifier]
        for identifier in ["America/Los_Angeles", "Europe/London"] where !listIds.contains(identifier) {
            listIds.append(identifier)
        }
        return listIds.map(city(forTimeZoneId:))
    }

    /// The city a time zone is named after, as "Los Angeles" for "America/Los_Angeles".
    static func city(forTimeZoneId timeZoneId: String) -> WorldClockCity {
        WorldClockCity(
            name: (timeZoneId.split(separator: "/").last.map(String.init) ?? timeZoneId)
                .replacingOccurrences(of: "_", with: " "),
            timeZoneId: timeZoneId
        )
    }

    /// The cities time zones are named after whose name or identifier contains a query, those whose name
    /// starts with it first. These are found at once and offline; any other city is found through
    /// `WorldClockCitySearch`.
    static func searchTimeZoneCities(matching query: String) -> [WorldClockCity] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return []
        }
        let listMatches = TimeZone.knownTimeZoneIdentifiers.map(city(forTimeZoneId:)).filter { city in
            city.name.localizedCaseInsensitiveContains(trimmedQuery)
                || city.timeZoneId.localizedCaseInsensitiveContains(trimmedQuery)
        }
        let listPrefixed = listMatches.filter { $0.name.lowercased().hasPrefix(trimmedQuery.lowercased()) }
        let listRest = listMatches.filter { !listPrefixed.contains($0) }
        return Array((listPrefixed + listRest).prefix(maximumTimeZoneResults))
    }
}

/// Any city in the world, found by name in any language through Apple Maps as the user types, and
/// resolved to its time zone when picked.
@MainActor
@Observable
final class WorldClockCitySearch: NSObject, MKLocalSearchCompleterDelegate {
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// The places matching the query so far.
    private(set) var listCompletions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.resultTypes = .address
        if #available(macOS 15.0, *) {
            completer.addressFilter = MKAddressFilter(including: [.locality, .administrativeArea])
        }
        completer.delegate = self
    }

    /// What the user has typed.
    var query: String = "" {
        didSet {
            let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
            if trimmedQuery.isEmpty {
                completer.cancel()
                listCompletions = []
            } else {
                completer.queryFragment = trimmedQuery
            }
        }
    }

    /// The city a picked place lies in, with its time zone.
    ///
    /// - Parameter completion: one of `listCompletions`
    /// - Returns: the city, or nil if Apple Maps knows no time zone for the place
    /// - Throws: the search's error, as when offline
    func city(for completion: MKLocalSearchCompletion) async throws -> WorldClockCity? {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let mapItem = response.mapItems.first, let timeZone = mapItem.timeZone else {
            return nil
        }
        let cityName = completion.title.split(separator: ",").first.map(String.init) ?? completion.title
        return WorldClockCity(name: cityName.trimmingCharacters(in: .whitespaces), timeZoneId: timeZone.identifier)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            listCompletions = self.completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            listCompletions = []
        }
    }
}
