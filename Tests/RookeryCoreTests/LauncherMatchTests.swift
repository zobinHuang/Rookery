import RookeryCore
import Testing

struct LauncherMatchTests {
    @Test func betterMatchesScoreHigher() throws {
        let exact = try #require(LauncherMatch.score(of: "safari", in: "Safari"))
        let prefix = try #require(LauncherMatch.score(of: "saf", in: "Safari"))
        let word = try #require(LauncherMatch.score(of: "studio", in: "Visual Studio Code"))
        let initials = try #require(LauncherMatch.score(of: "vsc", in: "Visual Studio Code"))
        let substring = try #require(LauncherMatch.score(of: "ari", in: "Safari"))
        let letters = try #require(LauncherMatch.score(of: "sfr", in: "Safari"))
        #expect(exact > prefix)
        #expect(prefix > word)
        #expect(word > initials)
        #expect(initials > substring)
        #expect(substring > letters)
    }

    @Test func camelCaseCountsAsWords() {
        #expect(LauncherMatch.score(of: "tp", in: "TablePlus") == LauncherMatch.scoreInitials)
        #expect(LauncherMatch.score(of: "plus", in: "TablePlus") == LauncherMatch.scoreWordPrefix)
    }

    @Test func caseAccentsAndScriptsMatchAsWritten() {
        #expect(LauncherMatch.score(of: "CAFE", in: "Café") == LauncherMatch.scoreExact)
        #expect(LauncherMatch.score(of: "微信", in: "微信") == LauncherMatch.scoreExact)
        #expect(LauncherMatch.score(of: "飞书", in: "Lark 飞书") == LauncherMatch.scoreWordPrefix)
    }

    @Test func aQueryWhoseLettersAreNotThereDoesNotMatch() {
        #expect(LauncherMatch.score(of: "xyz", in: "Safari") == nil)
        #expect(LauncherMatch.score(of: "  ", in: "Safari") == nil)
        #expect(LauncherMatch.score(of: "safarix", in: "Safari") == nil)
    }
}
