import Foundation
import RookeryCore
import Testing
@testable import RookeryPlatform

struct MailScriptingTests {
    @Test func aMessageIsFoundByAScriptThatCompiles() throws {
        let place = try #require(MailMessagePlace(messageId: 33131, mailboxURL: "imap://E6C13C17-677F/%5BGmail%5D/All%20Mail"))
        let source = """
            tell application "Mail"
                \(MailScripting.find(place, into: "theMessage"))
                if theMessage is missing value then return "none"
                return (id of theMessage) as text
            end tell
            """
        #expect(source.contains("«class mssg» id 33131 of mailbox \"[Gmail]/All Mail\""))
        #expect(source.contains("account id \"E6C13C17-677F\""))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "find.applescript")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compiler.arguments = ["-o", directory.appending(path: "find.scpt").path, file.path]
        compiler.standardError = Pipe()
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
    }
}
