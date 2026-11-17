import Foundation

/// How well a name answers what the user typed in the launcher, from an exact match down to its letters in
/// order: the name itself, its start, a word's start, the initials of its words (`vsc` for Visual Studio
/// Code, camel case counted as words), anywhere in it, then the letters in order with others between.
/// Case and accents do not count, so a name in any script matches as written.
public enum LauncherMatch {
    public static let scoreExact = 1000
    public static let scoreNamePrefix = 900
    public static let scoreWordPrefix = 800
    public static let scoreInitials = 700
    public static let scoreSubstring = 500
    public static let scoreLetters = 300
    /// How much each letter the query skips past lowers a match by its letters in order.
    private static let letterGapCost = 4
    /// How much each letter of the name past the query lowers a match at its start.
    private static let lengthCost = 1

    /// The score of a name for a query, higher for a better match; nil when it does not match.
    ///
    /// - Parameters:
    ///   - query: what the user typed
    ///   - name: the name to match
    /// - Returns: the score, or nil
    public static func score(of query: String, in name: String) -> Int? {
        let needle = folded(query).trimmingCharacters(in: .whitespaces)
        let haystack = folded(name)
        guard !needle.isEmpty, !haystack.isEmpty else {
            return nil
        }
        if haystack == needle {
            return scoreExact
        }
        if haystack.hasPrefix(needle) {
            return scoreNamePrefix - (haystack.count - needle.count) * lengthCost
        }
        let listWords = words(of: name).map(folded)
        if listWords.contains(where: { $0.hasPrefix(needle) }) {
            return scoreWordPrefix
        }
        let initials = String(listWords.compactMap(\.first))
        if initials.count > 1, initials.hasPrefix(needle) {
            return scoreInitials
        }
        if haystack.contains(needle) {
            return scoreSubstring
        }
        guard let gaps = gapsOfLetters(needle, in: haystack) else {
            return nil
        }
        return max(scoreLetters - gaps * letterGapCost, 1)
    }

    /// A name's words: split at spaces and punctuation, and where a lowercase letter meets an uppercase one.
    static func words(of name: String) -> [String] {
        var listWords: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character.isWhitespace || character.isPunctuation || character.isSymbol {
                if !current.isEmpty {
                    listWords.append(current)
                }
                current = ""
            } else if character.isUppercase, let previous, previous.isLowercase {
                listWords.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty {
            listWords.append(current)
        }
        return listWords
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// How many letters of the name fall between the query's letters when each is found in order, or nil
    /// when they are not all there.
    private static func gapsOfLetters(_ needle: String, in haystack: String) -> Int? {
        var gaps = 0
        var index = haystack.startIndex
        var isStarted = false
        for letter in needle where !letter.isWhitespace {
            guard let found = haystack[index...].firstIndex(of: letter) else {
                return nil
            }
            if isStarted {
                gaps += haystack.distance(from: index, to: found)
            }
            isStarted = true
            index = haystack.index(after: found)
        }
        return gaps
    }
}
