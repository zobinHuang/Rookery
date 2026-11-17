import Foundation

/// Someone the user writes to and meets, as they set them down in the settings: a name, the addresses
/// their mail comes from, and whether they gave a photo. Raven is told a person's addresses when the user
/// names them with `@`, and the mail and the calendars show the person wherever one of their addresses is.
public struct Person: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var listAddresses: [String]
    public var hasPhoto: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, listAddresses: [String], hasPhoto: Bool = false) {
        self.id = id
        self.name = name
        self.listAddresses = listAddresses
        self.hasPhoto = hasPhoto
    }

    /// How a mention names the person in text: `@` and the name, its spaces made hyphens so the mention
    /// reads as one word.
    public var mentionToken: String {
        "@" + name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    /// The person's initials, for the round mark that stands for them without a photo.
    public var initials: String {
        Self.initials(of: name)
    }

    /// The initials of a name: the first letters of its first two words, or of an address's name.
    public static func initials(of name: String) -> String {
        let listWords = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" || $0 == "-" }).prefix(2)
        let initials = listWords.compactMap(\.first).map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "?" : initials
    }
}

/// Everyone the user set down, with the person each address belongs to, and the people a text names.
public struct PeopleBook: Codable, Equatable, Sendable {
    public static let fileName = "people.json"

    public private(set) var listPeople: [Person]

    public init(listPeople: [Person] = []) {
        self.listPeople = listPeople
    }

    /// The person an address belongs to, in any case.
    public func person(withAddress address: String) -> Person? {
        let lowered = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else {
            return nil
        }
        return listPeople.first { person in
            person.listAddresses.contains { $0.lowercased() == lowered }
        }
    }

    public func person(withId personId: String) -> Person? {
        listPeople.first { $0.id == personId }
    }

    /// The people a text names with their mentions, each once, in the order first named.
    public func people(mentionedIn text: String) -> [Person] {
        var listFound: [Person] = []
        for range in mentionRanges(in: text).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if !listFound.contains(range.person) {
                listFound.append(range.person)
            }
        }
        return listFound
    }

    /// Where a text names people, longest names first so one name inside another is not taken for it.
    public func mentionRanges(in text: String) -> [MentionRange] {
        var listRanges: [MentionRange] = []
        for person in listPeople.sorted(by: { $0.mentionToken.count > $1.mentionToken.count }) {
            var searchStart = text.startIndex
            while let found = text.range(of: person.mentionToken, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let isWholeWord = found.upperBound == text.endIndex || !(text[found.upperBound].isLetter || text[found.upperBound].isNumber)
                let isTaken = listRanges.contains { $0.range.overlaps(found) }
                if isWholeWord && !isTaken {
                    listRanges.append(MentionRange(range: found, person: person))
                }
                searchStart = found.upperBound
            }
        }
        return listRanges.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The people whose name or address matches what follows an `@`, those whose name starts with it first.
    public func suggestions(for query: String, limit: Int) -> [Person] {
        let lowered = query.lowercased().replacingOccurrences(of: "-", with: " ")
        let listMatches = listPeople.filter { person in
            lowered.isEmpty
                || person.name.lowercased().contains(lowered)
                || person.listAddresses.contains { $0.lowercased().contains(lowered) }
        }
        return Array(listMatches.sorted { first, second in
            let isFirstPrefix = first.name.lowercased().hasPrefix(lowered)
            let isSecondPrefix = second.name.lowercased().hasPrefix(lowered)
            if isFirstPrefix != isSecondPrefix {
                return isFirstPrefix
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }.prefix(limit))
    }

    /// Add a person or put in place the one with the same id, names in order.
    public mutating func put(_ person: Person) {
        listPeople.removeAll { $0.id == person.id }
        listPeople.append(person)
        listPeople.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public mutating func remove(_ personId: String) {
        listPeople.removeAll { $0.id == personId }
    }
}

/// Where a text names a person with their mention.
public struct MentionRange: Equatable, Sendable {
    public let range: Range<String.Index>
    public let person: Person
}
