import AppKit
import RookeryCore
import SwiftUI

/// An action Raven waits to take on this Mac, as a card under the conversation: what it would do, the
/// command or the file and what goes in it, and the user's answer: this once, every time in this
/// conversation, or not.
struct RavenApprovalCard: View {
    private static let cornerRadius: CGFloat = 12
    /// The most lines of a command or a file's content the card shows.
    private static let previewLineLimit = 8

    let request: RavenApprovalRequest
    let onChoose: (RavenApprovalChoice) -> Void

    private var isCodexTurn: Bool {
        request.toolName == RavenApprovalRequest.codexTurnTool
    }

    private var icon: RookeryIcon {
        switch request.toolName {
        case "Bash": .terminal
        case "Write", "Edit", "MultiEdit", "NotebookEdit": .draft
        case RavenApprovalRequest.codexTurnTool: .lock
        default: request.chromeTool == nil ? .tool : .globe
        }
    }

    /// What goes in a file written or changed, or the command's own words of what it does.
    private var preview: String? {
        let input = request.input
        let text = input["content"]?.stringValue
            ?? input["new_string"]?.stringValue
            ?? input["new_source"]?.stringValue
        guard let text, !text.isEmpty else {
            return nil
        }
        let listLines = text.components(separatedBy: .newlines)
        let shown = listLines.prefix(Self.previewLineLimit).joined(separator: "\n")
        return listLines.count > Self.previewLineLimit ? shown + "\n…" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RookeryIconView(icon)
                    .foregroundStyle(Color.accentColor)
                Text(isCodexTurn ? "Raven on Codex asks to work on this Mac" : "Raven asks to \(request.verb.prefix(1).lowercased() + request.verb.dropFirst())")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            if isCodexTurn {
                Text("Codex cannot ask action by action. Allowed, this turn may run commands and write files anywhere on your Mac; kept sandboxed, it works only in Raven's own workspace.")
                    .font(.system(size: 12))
                    .foregroundStyle(StageColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let description = request.input["description"]?.stringValue, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(request.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(Self.previewLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(StageColors.groove.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let preview {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StageColors.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(StageColors.groove.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            HStack(spacing: 8) {
                Button(isCodexTurn ? "Keep Sandboxed" : "Decline") {
                    onChoose(.deny)
                }
                Spacer(minLength: 0)
                Button("Allow in This Conversation") {
                    onChoose(.conversation)
                }
                Button(isCodexTurn ? "Allow This Turn" : "Allow Once") {
                    onChoose(.once)
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The folder a conversation with Raven works in and whether it asks before acting on this Mac, as a chip
/// in its header whose menu shows the folder, chooses another, and changes what Raven may do.
struct RavenFolderMenu: View {
    let raven: RavenAgent
    let conversation: RavenConversation
    let isUnrestricted: Bool

    private var isCodex: Bool {
        conversation.engine == RavenConversation.engineCodex
    }

    private var accessTitle: String {
        if isUnrestricted {
            return "Allowed everywhere"
        }
        return switch conversation.localAccess {
        case .ask: "Asks first"
        case .allowed: "Allowed here"
        case .sandboxed: "Sandboxed"
        }
    }

    var body: some View {
        Menu {
            Button("Show in Finder") {
                let folder = conversation.folderURL
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            Button("Choose Folder…") {
                chooseFolder()
            }
            if conversation.folderPath != nil {
                Button("Use the Default Folder") {
                    raven.chooseFolder(nil, for: conversation.id)
                }
            }
            Divider()
            if isUnrestricted {
                Text("Raven acts on this Mac without asking in every conversation; change it in Settings, under Roost.")
            } else {
                Picker("On This Mac", selection: Binding(
                    get: { conversation.localAccess },
                    set: { raven.changeLocalAccess(to: $0, in: conversation.id) }
                )) {
                    Text("Ask Before Acting").tag(RavenLocalAccess.ask)
                    Text("Allow in This Conversation").tag(RavenLocalAccess.allowed)
                    if isCodex {
                        Text("Keep to Its Sandbox").tag(RavenLocalAccess.sandboxed)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(.folder)
                Text(conversation.folderURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .foregroundStyle(StageColors.tertiaryText)
                Text(accessTitle)
                    .foregroundStyle(StageColors.secondaryText)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(StageButtonStyle())
        .controlSize(.small)
        .fixedSize()
        .help("Raven works in \(conversation.folderURL.path)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = conversation.folderURL
        panel.prompt = "Choose"
        panel.message = "The folder Raven works in in this conversation"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        raven.chooseFolder(url, for: conversation.id)
    }
}
