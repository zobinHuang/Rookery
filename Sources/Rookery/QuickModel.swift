import Foundation
import RookeryCore
import RookeryPlatform

/// A short answer from the code agent Raven runs on, for the small writing Rookery does itself, as an
/// agent's role or a conversation's title: its smallest model, no tools, none of the user's settings, and
/// no session kept, run in a folder of its own.
enum QuickModel {
    private static let workspaceName = "identity"
    private static let claudeModel = "haiku"

    /// The answer to a prompt.
    ///
    /// - Parameters:
    ///   - prompt: what to ask
    ///   - engine: the code agent to ask, `claude` or `codex`
    /// - Returns: the answer as written
    /// - Throws: `HeadlessAgentError` when the agent cannot run
    static func answer(_ prompt: String, engine: String) async throws -> String {
        let workspace = DataDirectory.file(named: workspaceName)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let isCodex = engine == RavenConversation.engineCodex
        let listArguments = isCodex
            ? [
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "-c", "sandbox_mode=\"read-only\"",
                "-c", "approval_policy=\"never\"",
                prompt,
            ]
            : [
                "-p", prompt,
                "--model", claudeModel,
                "--tools", "",
                "--no-session-persistence",
                "--setting-sources", "project",
                "--strict-mcp-config",
                "--output-format", "text",
            ]
        let agent = HeadlessAgent(launch: HeadlessAgent.Launch(
            arguments: listArguments,
            workingDirectory: workspace,
            mapEnvironment: ["TMUX": nil, "TMUX_PANE": nil],
            executable: nil,
            program: isCodex ? .codex : .claude
        ))
        var output = Data()
        for try await chunk in agent.run() {
            output.append(chunk)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
