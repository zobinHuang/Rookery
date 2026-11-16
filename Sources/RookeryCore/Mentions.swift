import Foundation

/// The `@kind/name` mentions in a request to Raven: the one being typed, the resources
/// it could complete to, and the mention a choice writes into the text.
public enum Mentions {
    /// The most suggestions offered at once.
    public static let suggestionLimit = 8
    private static let marker: Character = "@"

    /// What follows the `@` being typed at the end of the text, or nil when no mention is being typed.
    public static func activeQuery(in text: String) -> String? {
        guard let markerIndex = text.lastIndex(of: marker) else {
            return nil
        }
        let query = text[text.index(after: markerIndex)...]
        let isAtWordStart = markerIndex == text.startIndex || text[text.index(before: markerIndex)].isWhitespace
        guard isAtWordStart, !query.contains(where: \.isWhitespace) else {
            return nil
        }
        return String(query)
    }

    /// The resources a query could mean, those whose name starts with it first, then those last used.
    ///
    /// - Parameters:
    ///   - query: what follows the `@`, which may name the kind as `kind/`
    ///   - listResources: the resources to choose from
    public static func suggestions(for query: String, among listResources: [FleetResource]) -> [FleetResource] {
        let lowered = query.lowercased()
        let parts = lowered.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let kindFilter = parts.count == 2 ? String(parts[0]) : nil
        let nameQuery = parts.count == 2 ? String(parts[1]) : lowered
        let listMatches = listResources.filter { resource in
            if let kindFilter, !resource.kind.hasPrefix(kindFilter) {
                return false
            }
            return nameQuery.isEmpty
                || resource.name.lowercased().contains(nameQuery)
                || resource.id.lowercased().contains(nameQuery)
        }
        return Array(listMatches.sorted { first, second in
            let isFirstPrefix = first.name.lowercased().hasPrefix(nameQuery)
            let isSecondPrefix = second.name.lowercased().hasPrefix(nameQuery)
            if isFirstPrefix != isSecondPrefix {
                return isFirstPrefix
            }
            return first.lastUsedAt > second.lastUsedAt
        }.prefix(suggestionLimit))
    }

    /// The mention that names a resource in the text.
    public static func token(for resource: FleetResource) -> String {
        "@\(resource.kind)/\(resource.name.replacingOccurrences(of: " ", with: "-"))"
    }

    /// The text with the mention being typed replaced by a resource's, and a space after it.
    public static func complete(_ text: String, with resource: FleetResource) -> String {
        guard let markerIndex = text.lastIndex(of: marker) else {
            return text
        }
        return String(text[..<markerIndex]) + token(for: resource) + " "
    }
}
