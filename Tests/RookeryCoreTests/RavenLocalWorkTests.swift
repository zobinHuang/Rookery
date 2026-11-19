import Foundation
import RookeryCore
import Testing

/// Raven working on the user's Mac: what it asks to do, where, and what the user may name with @.
struct RavenLocalWorkTests {
    @Test func anApprovalNamesTheActionAndAnswersAsClaudeCodeReadsIt() throws {
        let request = RavenApprovalRequest(id: "t1", conversationId: "c1", toolName: "Bash", inputJSON: #"{"command":"npm run build","description":"Build"}"#)
        #expect(request.summary == "npm run build")
        #expect(request.verb == "Run a command")
        let allowed = try JSONDecoder().decode(JSONValue.self, from: Data(request.decisionText(isAllowed: true).utf8))
        #expect(allowed["behavior"]?.stringValue == "allow")
        #expect(allowed["updatedInput"]?["command"]?.stringValue == "npm run build")
        let denied = try JSONDecoder().decode(JSONValue.self, from: Data(request.decisionText(isAllowed: false).utf8))
        #expect(denied["behavior"]?.stringValue == "deny")
    }

    @Test func aConversationKeptBeforeLocalWorkAsksFirstInTheDefaultFolder() throws {
        let json = #"{"listConversations":[{"id":"c1","title":"t","createdAt":0,"lastAt":0,"turnCount":1,"costUSD":0}]}"#
        var conversations = try JSONDecoder().decode(RavenConversations.self, from: Data(json.utf8))
        #expect(conversations.conversation("c1")?.localAccess == .ask)
        #expect(conversations.conversation("c1")?.folderURL == RavenLocalWork.defaultFolderURL)
        conversations.changeLocalAccess(to: .allowed, in: "c1")
        conversations.chooseFolder("/tmp/work", for: "c1")
        let saved = try JSONDecoder().decode(RavenConversations.self, from: JSONEncoder().encode(conversations))
        #expect(saved.conversation("c1")?.localAccess == .allowed)
        #expect(saved.conversation("c1")?.folderURL.path == "/tmp/work")
    }

    @Test func filesAreOfferedFromTheConversationsFolderOrAnAbsolutePath() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "raven-mentions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Reports"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "report draft.md"))
        try Data().write(to: folder.appending(path: ".hidden"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let listMatches = Mentions.fileSuggestions(for: "rep", in: folder)
        #expect(listMatches.map(\.name) == ["report draft.md", "Reports"])
        #expect(listMatches.first?.token == "@\"\(folder.standardizedFileURL.path)/report draft.md\"")
        #expect(Mentions.complete("see @Rep", with: listMatches[1]) == "see @\(folder.standardizedFileURL.path)/Reports/")
        #expect(Mentions.fileSuggestions(for: folder.path + "/.h", in: URL(fileURLWithPath: "/")).map(\.name) == [".hidden"])
    }
}
