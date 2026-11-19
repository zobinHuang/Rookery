import Foundation
import RookeryCore
import Testing

/// The files an agent writes or changes, shown as files rather than among its tool calls, from Claude
/// Code's transcripts and Codex's events alike.
struct TranscriptFileTests {
    @Test func aFileWrittenOrChangedShowsOnItsOwnBetweenTheToolCalls() {
        var reader = TranscriptReader()
        let lines = #"""
            {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/r/report.md","content":"hi"}},{"type":"tool_use","name":"Edit","input":{"file_path":"relative.txt"}},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/r/a.txt"}}]}}

            """#
        reader.append(Data(lines.utf8))
        #expect(reader.listEntries.map(\.filePath) == [nil, "/tmp/r/report.md", nil, nil])
        let listBlocks = TranscriptBlock.blocks(of: reader.listEntries)
        #expect(listBlocks.count == 3)
        if case .file(let entry) = listBlocks[1] {
            #expect(entry.filePath == "/tmp/r/report.md")
        } else {
            Issue.record("the written file is not a block of its own")
        }
    }

    @Test func codexFileChangesAndSearchesReadAsClaudeCodesTools() {
        let changed = CodexTranslation.of(Data(#"{"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[{"path":"/tmp/r/new.md","kind":"add"},{"path":"/tmp/r/old.md","kind":"update"},{"path":"/tmp/r/gone.md","kind":"delete"}],"status":"completed"}}"#.utf8))
        var reader = TranscriptReader()
        for line in changed.listLines {
            reader.append(line + Data("\n".utf8))
        }
        #expect(reader.listEntries.map(\.role) == [.tool("Write"), .tool("Edit")])
        #expect(reader.listEntries.map(\.filePath) == ["/tmp/r/new.md", "/tmp/r/old.md"])
        let searched = CodexTranslation.of(Data(#"{"type":"item.completed","item":{"id":"w1","type":"web_search","query":"","action":{"type":"search","query":"swift release"}}}"#.utf8))
        var searchReader = TranscriptReader()
        searchReader.append(searched.listLines[0] + Data("\n".utf8))
        #expect(searchReader.listEntries.map(\.text) == ["swift release"])
    }
}
