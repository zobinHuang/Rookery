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
        complete(text, withToken: token(for: resource))
    }

    /// The text with the mention being typed replaced by a person's, and a space after it.
    public static func complete(_ text: String, with person: Person) -> String {
        complete(text, withToken: person.mentionToken)
    }

    /// The text with the mention being typed replaced by a file's, and a space after it; a folder's path
    /// ends in `/` and takes no space, so its contents are offered next.
    public static func complete(_ text: String, with file: MentionedFile) -> String {
        let completed = complete(text, withToken: file.token)
        return file.isFolder ? String(completed.dropLast()) : completed
    }

    /// The files and folders a query could mean: what is in the folder its path leads to, relative to a
    /// conversation's folder or from `/` or `~`, whose name holds what follows its last `/`, those it
    /// starts first, hidden ones only when asked for with a `.`.
    ///
    /// - Parameters:
    ///   - query: what follows the `@`
    ///   - folder: the folder a relative path starts from
    public static func fileSuggestions(for query: String, in folder: URL) -> [MentionedFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded = query.hasPrefix("~") ? home.path + query.dropFirst() : query
        let slashIndex = expanded.lastIndex(of: "/")
        let directoryPart = slashIndex.map { String(expanded[...$0]) } ?? ""
        let namePart = slashIndex.map { String(expanded[expanded.index(after: $0)...]) } ?? expanded
        let directory = directoryPart.hasPrefix("/")
            ? URL(fileURLWithPath: directoryPart, isDirectory: true)
            : folder.appending(path: directoryPart, directoryHint: .isDirectory)
        guard let listNames = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let lowered = namePart.lowercased()
        let listMatches = listNames.filter { name in
            (namePart.hasPrefix(".") || !name.hasPrefix("."))
                && (lowered.isEmpty || name.lowercased().contains(lowered))
        }.sorted { first, second in
            let isFirstPrefix = first.lowercased().hasPrefix(lowered)
            let isSecondPrefix = second.lowercased().hasPrefix(lowered)
            if isFirstPrefix != isSecondPrefix {
                return isFirstPrefix
            }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
        return listMatches.prefix(suggestionLimit).map { name in
            let url = directory.appending(path: name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return MentionedFile(path: url.standardizedFileURL.path, isFolder: isDirectory.boolValue)
        }
    }

    private static func complete(_ text: String, withToken token: String) -> String {
        guard let markerIndex = text.lastIndex(of: marker) else {
            return text
        }
        return String(text[..<markerIndex]) + token + " "
    }
}

/// A file or folder on this Mac named in a request to Raven.
public struct MentionedFile: Equatable, Hashable, Sendable {
    /// Its absolute path.
    public let path: String
    public let isFolder: Bool

    public init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
    }

    /// Its name, the last part of its path.
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// The mention that names it in the text: `@` and its path, a folder's ending in `/`, quoted when it
    /// holds a space.
    public var token: String {
        let shown = isFolder ? path + "/" : path
        return shown.contains(where: \.isWhitespace) ? "@\"\(shown)\"" : "@\(shown)"
    }
}

/// What a mention in a request to Raven can name: a person the user set down, or a resource roost manages.
public enum MentionTarget: Identifiable, Sendable {
    case person(Person)
    case resource(FleetResource)
    case file(MentionedFile)

    public var id: String {
        switch self {
        case .person(let person): "person:\(person.id)"
        case .resource(let resource): "\(resource.kind):\(resource.id)"
        case .file(let file): "file:\(file.path)"
        }
    }

    /// The people, the files and the resources a mention being typed could mean: the people first, unless
    /// it names a kind or a path, then the files where a folder is given and something is typed, then the resources, up to the
    /// limit together.
    ///
    /// - Parameters:
    ///   - query: what follows the `@`
    ///   - book: the people the user set down
    ///   - listResources: roost's resources
    ///   - folder: the folder a relative path starts from; nil to offer no files
    public static func suggestions(
        for query: String,
        people book: PeopleBook,
        resources listResources: [FleetResource],
        folder: URL? = nil
    ) -> [MentionTarget] {
        let isPath = query.hasPrefix("/") || query.hasPrefix("~")
        let listPeople = query.contains("/") || isPath ? [] : book.suggestions(for: query, limit: Mentions.suggestionLimit)
        let listFiles = query.isEmpty ? [] : folder.map { Mentions.fileSuggestions(for: query, in: $0) } ?? []
        let listMatchedResources = isPath ? [] : Mentions.suggestions(for: query, among: listResources)
        let listTargets = listPeople.map(MentionTarget.person)
            + listFiles.map(MentionTarget.file)
            + listMatchedResources.map(MentionTarget.resource)
        return Array(listTargets.prefix(Mentions.suggestionLimit))
    }
}

