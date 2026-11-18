import RookeryCore
import SwiftUI

/// Raven beside the mail being read, in the Mail page's right column: one conversation per mail thread,
/// kept with Raven's other conversations, whose first request carries which mail it is about. When the user
/// is happy with a reply Raven proposes it as a draft, which goes into the reply editor under the thread.
struct MailRavenPanel: View {
    let fleetModel: FleetModel
    let message: MailMessageDetail
    /// The thread's messages, any of which a conversation may be about.
    let listThreadIds: [Int]

    @State private var sendToken = 0
    @FocusState private var isFocused: Bool

    private var raven: RavenAgent {
        fleetModel.raven
    }

    private var conversationId: String? {
        raven.conversations.conversation(aboutMail: listThreadIds)?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RavenView(isWorking: raven.isRunning(conversationId))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Raven")
                        .font(.system(size: 13, weight: .bold))
                    Text(conversationId == nil ? "Ask about this mail" : "About this mail")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            if let conversationId {
                RavenThreadView(fleetModel: fleetModel, conversationId: conversationId, sendToken: sendToken) { draft in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        fleetModel.pageMemory.mailReplyDraft = draft
                    }
                }
                .id(conversationId)
            } else {
                suggestions
            }
            AgentComposer(
                text: Bindable(fleetModel.pageMemory).mailRavenDraft,
                placeholder: fleetModel.client() == nil ? "Connect to roost first" : "Ask Raven about this mail",
                isEnabled: fleetModel.client() != nil,
                isBusy: raven.isRunning(conversationId),
                fontSize: 12,
                onStop: {
                    if let conversationId {
                        raven.cancel(conversationId)
                    }
                },
                onSend: {
                    send(fleetModel.pageMemory.mailRavenDraft)
                },
                isFocused: $isFocused
            )
            .padding(12)
        }
        .background(StageColors.sidebar)
    }

    /// Where a thread with no conversation yet starts one: what Raven can do with it.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk this mail over with Raven. When you like a reply, Raven drafts it into the editor under the thread, for you to change and send.")
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.listSuggestions, id: \.self) { suggestion in
                Button {
                    send(suggestion)
                } label: {
                    RookeryLabel(suggestion, icon: .sparkles, spacing: 6)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(fleetModel.client() == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let listSuggestions = [
        "Summarize this thread for me",
        "What does this mail want from me?",
        "Draft a reply",
    ]

    /// Send a request in the thread's conversation, or open one with it, telling Raven which mail it is
    /// about and how the user finishes a reply.
    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let conversationId {
            guard raven.ask(trimmed, mentioning: [], in: conversationId) != nil else {
                return
            }
        } else {
            let summary = message.summary
            let sender = summary.from.name.isEmpty ? summary.from.address : "\(summary.from.name) <\(summary.from.address)>"
            let request = """
                \(trimmed)

                This is about the mail with id \(summary.id) in \(summary.account), from \(sender), subject "\(summary.subject)". \
                Read it and its thread with the mail tools first. When I am happy with a reply, write it with propose_draft, \
                reply_to \(summary.id); I will change it and send it myself in Rookery's Mail page.
                """
            guard let newId = raven.ask(request, mentioning: [], in: nil) else {
                return
            }
            raven.link(newId, toMail: summary.id)
        }
        fleetModel.pageMemory.mailRavenDraft = ""
        sendToken += 1
    }
}

/// The mail being written under a thread, Raven's draft or the user's own reply: who it goes from and to,
/// its subject and its text, all editable, sent by Mail when the user presses Send, or opened in Mail to
/// finish there. It lives in the page's memory, so it survives leaving the page.
struct MailReplyEditor: View {
    let fleetModel: FleetModel
    /// Who wrote the message the reply answers, quoted under its text as it is sent.
    let quotedSender: String?
    let onSent: () -> Void

    @State private var toLine = ""
    @State private var ccLine = ""
    @State private var isWorking = false
    @State private var problem: String?

    private var memory: PageMemory {
        fleetModel.pageMemory
    }

    var body: some View {
        if let draft = memory.mailReplyDraft {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    RookeryIconView(.undo)
                        .foregroundStyle(Color.accentColor)
                    Text("Reply")
                        .font(.system(size: 13, weight: .semibold))
                    Text("from \(draft.account)")
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.secondaryText)
                    Spacer(minLength: 0)
                }
                field("To") {
                    TextField("Recipients", text: $toLine)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: toLine) { _, line in
                            memory.mailReplyDraft?.listTo = MailReplyDraft.addresses(in: line)
                        }
                }
                field("Cc") {
                    TextField("Copied", text: $ccLine)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: ccLine) { _, line in
                            memory.mailReplyDraft?.listCc = MailReplyDraft.addresses(in: line)
                        }
                }
                field("Subject") {
                    TextField("Subject", text: binding(\.subject))
                        .textFieldStyle(.roundedBorder)
                }
                TextEditor(text: binding(\.body))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(StageColors.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(StageColors.separator)
                    }
                if let quotedSender {
                    RookeryLabel("\(quotedSender)'s message is quoted under your text when it goes", icon: .bubble, spacing: 5)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StageColors.tertiaryText)
                }
                if let problem {
                    RookeryLabel(problem, icon: .warning)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("Discard") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            memory.mailReplyDraft = nil
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Open in Mail") {
                        hand(draft, isSending: false)
                    }
                    .disabled(isWorking)
                    Button {
                        hand(draft, isSending: true)
                    } label: {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .disabled(isWorking || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.listTo.isEmpty && draft.replyToMessageId == nil))
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
            .onAppear {
                toLine = draft.listTo.joined(separator: ", ")
                ccLine = draft.listCc.joined(separator: ", ")
            }
            .onChange(of: draft.replyToMessageId) {
                toLine = memory.mailReplyDraft?.listTo.joined(separator: ", ") ?? ""
                ccLine = memory.mailReplyDraft?.listCc.joined(separator: ", ") ?? ""
            }
        }
    }

    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 56, alignment: .leading)
            control()
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MailReplyDraft, String>) -> Binding<String> {
        Binding(
            get: { memory.mailReplyDraft?[keyPath: keyPath] ?? "" },
            set: { memory.mailReplyDraft?[keyPath: keyPath] = $0 }
        )
    }

    /// Hand the mail to Mail, sent or opened, and let it go from the editor once Mail has it.
    private func hand(_ draft: MailReplyDraft, isSending: Bool) {
        isWorking = true
        problem = nil
        Task {
            do {
                try await fleetModel.mailService.write(draft, isSending: isSending)
                withAnimation(.easeOut(duration: 0.2)) {
                    memory.mailReplyDraft = nil
                }
                onSent()
            } catch {
                problem = String(describing: error)
            }
            isWorking = false
        }
    }
}
