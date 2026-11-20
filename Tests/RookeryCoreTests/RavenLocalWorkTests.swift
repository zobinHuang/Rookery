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

    @Test func chromeActionsThatOnlyLookPassAndTheRestAreNamedForTheUser() {
        let screenshot = RavenApprovalRequest(id: "a", conversationId: "c", toolName: "mcp__claude-in-chrome__computer", inputJSON: #"{"action":"screenshot","tabId":1}"#)
        let click = RavenApprovalRequest(id: "b", conversationId: "c", toolName: "mcp__claude-in-chrome__computer", inputJSON: #"{"action":"left_click","coordinate":[412,96],"tabId":1}"#)
        let typing = RavenApprovalRequest(id: "d", conversationId: "c", toolName: "mcp__claude-in-chrome__computer", inputJSON: #"{"action":"type","text":"FP8 attention","tabId":1}"#)
        let open = RavenApprovalRequest(id: "e", conversationId: "c", toolName: "mcp__claude-in-chrome__navigate", inputJSON: #"{"url":"https://example.com/dash","tabId":1}"#)
        let read = RavenApprovalRequest(id: "f", conversationId: "c", toolName: "mcp__claude-in-chrome__get_page_text", inputJSON: #"{"tabId":1}"#)
        #expect(screenshot.isReadOnly)
        #expect(read.isReadOnly)
        #expect(!click.isReadOnly)
        #expect(click.verb == "Click in Chrome")
        #expect(click.summary == "left click at 412, 96")
        #expect(typing.verb == "Type in Chrome")
        #expect(typing.summary == "FP8 attention")
        #expect(open.verb == "Open a page in Chrome")
        #expect(open.summary == "https://example.com/dash")
        #expect(!RavenApprovalRequest(id: "g", conversationId: "c", toolName: "Bash", inputJSON: "{}").isReadOnly)
    }

    @Test func aCommandThatReachesAgentsAroundRoostIsToldApart() throws {
        func bash(_ command: String) -> RavenApprovalRequest {
            let inputJSON = String(decoding: try! JSONEncoder().encode(JSONValue.object(["command": .string(command)])), as: UTF8.self)
            return RavenApprovalRequest(id: "b", conversationId: "c", toolName: "Bash", inputJSON: inputJSON)
        }
        for command in [
            "ps -t s003 -o pid,command",
            "ls /tmp && tmux send-keys -t main:2 Enter",
            "sudo /opt/homebrew/bin/tmux capture-pane -p",
            "PATH=/usr/bin pgrep -fl claude | head",
            "echo $(lsof -p 42)",
            "~/.local/bin/rook-agent set %1 idle",
        ] {
            #expect(bash(command).reachesAgentsAroundRoost, "\(command)")
        }
        for command in [
            "git commit -m 'fix ps output in tmux docs'",
            "npm run build",
            "grep -rn kill src",
            "rook-client agent status",
        ] {
            #expect(!bash(command).reachesAgentsAroundRoost, "\(command)")
        }
        let denied = try JSONDecoder().decode(JSONValue.self, from: Data(bash("ps aux").agentReachDecisionText.utf8))
        #expect(denied["behavior"]?.stringValue == "deny")
        #expect(denied["message"]?.stringValue?.contains("rook-client agent status") == true)
        #expect(!RavenApprovalRequest(id: "w", conversationId: "c", toolName: "Write", inputJSON: #"{"file_path":"/tmp/ps"}"#).reachesAgentsAroundRoost)
    }
}
