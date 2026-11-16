/// The places the user went to, most recent first, by the window switcher's ids: windows and Rookery's
/// pages. The switcher lists where the user is first, then the rest as they were last used, then those
/// never used in the order offered.
public struct RecentPlaces: Equatable, Sendable {
    public private(set) var listIds: [String] = []

    public init() {}

    /// Note that the user is at a place now.
    public mutating func note(_ placeId: String) {
        listIds.removeAll { $0 == placeId }
        listIds.insert(placeId, at: 0)
    }

    /// The places offered, in the order to list them: the current one, then the others as last used, then
    /// those never used as offered.
    ///
    /// - Parameters:
    ///   - listOffered: the places there are now
    ///   - currentId: where the user is, if anywhere offered
    public func ordered(_ listOffered: [String], current currentId: String?) -> [String] {
        let setOffered = Set(listOffered)
        var listOrdered: [String] = []
        if let currentId, setOffered.contains(currentId) {
            listOrdered.append(currentId)
        }
        for placeId in listIds where setOffered.contains(placeId) && !listOrdered.contains(placeId) {
            listOrdered.append(placeId)
        }
        let setListed = Set(listOrdered)
        return listOrdered + listOffered.filter { !setListed.contains($0) }
    }

    /// Forget the places that are gone.
    public mutating func prune(keeping setOffered: Set<String>) {
        listIds.removeAll { !setOffered.contains($0) }
    }
}
