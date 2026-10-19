import Foundation

/// The cities the world clock can show, named by their time zones in the system's time zone database,
/// which macOS keeps current, daylight saving time included.
enum WorldClock {
    private static let maximumSearchResults = 8

    /// The cities shown before the user picks any: here, then Los Angeles and London.
    static var listDefaultTimeZoneIds: [String] {
        var listIds = [TimeZone.current.identifier]
        for identifier in ["America/Los_Angeles", "Europe/London"] where !listIds.contains(identifier) {
            listIds.append(identifier)
        }
        return listIds
    }

    /// A time zone's city, as "Los Angeles" for "America/Los_Angeles".
    static func cityName(forTimeZoneId timeZoneId: String) -> String {
        (timeZoneId.split(separator: "/").last.map(String.init) ?? timeZoneId)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// The time zones whose city or identifier contains a query, closest names first.
    static func searchTimeZones(matching query: String) -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return []
        }
        let listMatches = TimeZone.knownTimeZoneIdentifiers.filter { timeZoneId in
            cityName(forTimeZoneId: timeZoneId).localizedCaseInsensitiveContains(trimmedQuery)
                || timeZoneId.localizedCaseInsensitiveContains(trimmedQuery)
        }
        let listPrefixed = listMatches.filter { cityName(forTimeZoneId: $0).lowercased().hasPrefix(trimmedQuery.lowercased()) }
        let listRest = listMatches.filter { !listPrefixed.contains($0) }
        return Array((listPrefixed + listRest).prefix(maximumSearchResults))
    }
}
