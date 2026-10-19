import Foundation

/// A time zone a search found, as the world clock would show it.
public struct TimeZoneMatch: Equatable, Sendable {
    /// What the clock calls the zone, as "UTC+8" or "Pacific Time".
    public let name: String
    /// The zone's identifier, which `TimeZone(identifier:)` takes.
    public let timeZoneId: String

    public init(name: String, timeZoneId: String) {
        self.name = name
        self.timeZoneId = timeZoneId
    }
}

/// Finding time zones by what people type for them rather than by a city: a fixed offset from UTC, as
/// "UTC", "UTC+8" or "GMT-5:30"; an abbreviation, as "PST" or "CET"; or a zone's name, as "Pacific".
public enum TimeZoneSearch {
    private static let listOffsetPrefixes = ["UTC", "GMT"]
    private static let utcName = "UTC"
    private static let utcIdentifier = "UTC"
    /// The widest offset any zone has, in hours.
    private static let maximumOffsetHours = 14
    private static let maximumResults = 12
    /// The locale names are shown in, so the same zone reads the same everywhere.
    private static let nameLocale = Locale(identifier: "en_US")
    /// Every zone with a name, worked out once as searches need them.
    private static let listNamedZones = TimeZone.knownTimeZoneIdentifiers.compactMap(match(forIdentifier:))

    /// The time zones a query names, the exact ones first.
    ///
    /// - Parameter query: what the user typed
    /// - Returns: the zones, at most a dozen
    public static func listMatches(for query: String) -> [TimeZoneMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return []
        }
        var listMatches: [TimeZoneMatch] = []
        if let offsetMatch = offsetMatch(for: trimmed) {
            listMatches.append(offsetMatch)
        }
        listMatches += abbreviationMatches(for: trimmed) + nameMatches(for: trimmed)
        var setSeen = Set<String>()
        return Array(listMatches.filter { setSeen.insert($0.name).inserted }.prefix(maximumResults))
    }

    /// A fixed offset from UTC: "UTC", "GMT", "Z", "UTC+8", "GMT-05", "UTC+5:30" or a bare "+8".
    private static func offsetMatch(for query: String) -> TimeZoneMatch? {
        var rest = query.uppercased()
        if rest == "Z" {
            return TimeZoneMatch(name: utcName, timeZoneId: utcIdentifier)
        }
        if let prefix = listOffsetPrefixes.first(where: rest.hasPrefix) {
            rest = String(rest.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                return TimeZoneMatch(name: utcName, timeZoneId: utcIdentifier)
            }
        }
        guard let sign = rest.first, sign == "+" || sign == "-" else {
            return nil
        }
        let listParts = rest.dropFirst().split(separator: ":", maxSplits: 1)
        guard
            let hoursText = listParts.first,
            let hours = Int(hoursText),
            hours <= maximumOffsetHours,
            let minutes = listParts.count > 1 ? Int(listParts[1]) : 0,
            (0..<60).contains(minutes)
        else {
            return nil
        }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        guard seconds != 0 else {
            return TimeZoneMatch(name: utcName, timeZoneId: utcIdentifier)
        }
        guard let timeZone = TimeZone(secondsFromGMT: seconds) else {
            return nil
        }
        let name = minutes == 0 ? "\(utcName)\(sign)\(hours)" : String(format: "%@%@%d:%02d", utcName, String(sign), hours, minutes)
        return TimeZoneMatch(name: name, timeZoneId: timeZone.identifier)
    }

    /// Zones whose abbreviation starts with the query, as "PST" for Pacific Time.
    private static func abbreviationMatches(for query: String) -> [TimeZoneMatch] {
        let upper = query.uppercased()
        return TimeZone.abbreviationDictionary
            .filter { $0.key.hasPrefix(upper) }
            .sorted { lhs, rhs in (lhs.key == upper ? 0 : 1, lhs.key) < (rhs.key == upper ? 0 : 1, rhs.key) }
            .compactMap { _, identifier in match(forIdentifier: identifier) }
    }

    /// Zones whose name holds the query, as "Pacific" for Pacific Time.
    private static func nameMatches(for query: String) -> [TimeZoneMatch] {
        listNamedZones
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name < $1.name }
    }

    private static func match(forIdentifier identifier: String) -> TimeZoneMatch? {
        guard
            let timeZone = TimeZone(identifier: identifier),
            let name = timeZone.localizedName(for: .generic, locale: nameLocale)
        else {
            return nil
        }
        return TimeZoneMatch(name: name, timeZoneId: identifier)
    }
}
