import RookeryCore
import SwiftUI

/// Raven beside the mail being read, in the Mail page's right column: the thread's conversations, kept
/// with Raven's other conversations, the latest shown unless the user picks another or starts a new one;
/// a conversation's first request carries which mail it is about. When the user is happy with a reply
/// Raven proposes it as a draft, which goes into Rookery's drafts and opens under the thread.
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

    private var listThreadConversations: [RavenConversation] {
        raven.conversations.conversations(aboutMail: listThreadIds)
    }

    private var threadKey: Int {
        message.summary.conversationId
    }

    /// The conversation shown: the one picked for the thread, none when a new one was asked for, or else
    /// the thread's latest.
    private var conversationId: String? {
        let listConversations = listThreadConversations
        if let choice = fleetModel.pageMemory.mapMailRavenChoices[threadKey] {
            return listConversations.first { $0.id == choice }?.id
        }
        return listConversations.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RavenView(isWorking: raven.isRunning(conversationId))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Raven")
                        .font(.system(size: 13, weight: .bold))
                    Text(conversationId.flatMap { raven.conversations.conversation($0)?.title } ?? "New conversation about this mail")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                conversationMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            if let conversationId {
                RavenThreadView(fleetModel: fleetModel, conversationId: conversationId, sendToken: sendToken) { draftId in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        fleetModel.pageMemory.openDraftId = draftId
                    }
                }
                .id(conversationId)
            } else {
                suggestions
            }
            RavenComposer(
                fleetModel: fleetModel,
                text: Bindable(fleetModel.pageMemory).mailRavenDraft,
                placeholder: fleetModel.client() == nil ? "Connect to roost first" : "Ask Raven about this mail",
                isEnabled: fleetModel.client() != nil,
                isBusy: raven.isRunning(conversationId),
                onStop: {
                    if let conversationId {
                        raven.cancel(conversationId)
                    }
                },
                onSend: { request in
                    send(request.text, mentioning: request.listMentions, addresses: request.mapAddresses)
                },
                isFocused: $isFocused,
                mentionFolder: raven.folder(of: conversationId)
            )
            .padding(12)
        }
        .background(StageColors.sidebar)
        .onAppear {
            raven.loadIfNeeded()
        }
    }

    /// The thread's conversations to switch between, and a new one.
    private var conversationMenu: some View {
        Menu {
            ForEach(listThreadConversations) { conversation in
                Button {
                    fleetModel.pageMemory.mapMailRavenChoices[threadKey] = conversation.id
                } label: {
                    if conversation.id == conversationId {
                        Label(conversation.title, systemImage: "checkmark")
                    } else {
                        Text(conversation.title)
                    }
                }
            }
            if !listThreadConversations.isEmpty {
                Divider()
            }
            Button("New Conversation") {
                fleetModel.pageMemory.mapMailRavenChoices[threadKey] = ""
                isFocused = true
            }
        } label: {
            HStack(spacing: 4) {
                RookeryIconView(.bubble)
                Text("\(listThreadConversations.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("This thread's conversations with Raven")
    }

    /// Where a thread with no conversation yet starts one: what Raven can do with it.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk this mail over with Raven. When you like a reply, Raven puts it in Drafts and opens it under the thread, for you to change and send.")
                .font(.system(size: 12))
                .foregroundStyle(StageColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.listSuggestions, id: \.self) { suggestion in
                Button {
                    send(suggestion, mentioning: [])
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
    private func send(_ text: String, mentioning listNamed: [FleetRef], addresses mapAddresses: [String: String] = [:]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let conversationId {
            guard raven.ask(trimmed, mentioning: listNamed, addresses: mapAddresses, in: conversationId) != nil else {
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
            guard let newId = raven.ask(request, mentioning: listNamed, addresses: mapAddresses, in: nil, origin: .mail) else {
                return
            }
            raven.link(newId, toMail: summary.id)
            fleetModel.pageMemory.mapMailRavenChoices[threadKey] = newId
        }
        fleetModel.pageMemory.mailRavenDraft = ""
        sendToken += 1
    }
}

/// The mail being written, one of Rookery's drafts: a reply under the thread it answers, or a new message
/// on its own; who it goes from and to, its subject and its text, all editable and kept as typed. Mail
/// sends it when the user presses Send, without showing a window, and it leaves the drafts.
struct MailReplyEditor: View {
    let fleetModel: FleetModel
    /// Who wrote the message the reply answers, quoted under its text as it is sent.
    let quotedSender: String?
    let onSent: () -> Void

    @State private var toLine = ""
    @State private var ccLine = ""
    @State private var isSending = false
    @State private var problem: String?

    private var memory: PageMemory {
        fleetModel.pageMemory
    }

    private var draft: MailReplyDraft? {
        memory.openDraftId.flatMap(fleetModel.mailDrafts.draft)
    }

    var body: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    RookeryIconView(draft.replyToMessageId == nil ? .draft : .undo)
                        .foregroundStyle(Color.accentColor)
                    Text(draft.replyToMessageId == nil ? "New Message" : "Reply")
                        .font(.system(size: 13, weight: .semibold))
                    Text(draft.account.isEmpty ? "from the account it answers" : "from \(draft.account)")
                        .font(.system(size: 12))
                        .foregroundStyle(StageColors.secondaryText)
                    Spacer(minLength: 0)
                }
                field("To") {
                    TextField("Recipients", text: $toLine)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: toLine) { _, line in
                            change { $0.listTo = MailReplyDraft.addresses(in: line) }
                        }
                }
                field("Cc") {
                    TextField("Copied", text: $ccLine)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: ccLine) { _, line in
                            change { $0.listCc = MailReplyDraft.addresses(in: line) }
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
                    .frame(minHeight: draft.replyToMessageId == nil ? 320 : 180)
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
                            memory.openDraftId = nil
                            fleetModel.mailDrafts.remove(draft.id)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Kept in Drafts as you write")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.tertiaryText)
                    Button {
                        send(draft)
                    } label: {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .disabled(isSending || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.listTo.isEmpty && draft.replyToMessageId == nil))
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
            .onChange(of: draft.id) {
                toLine = self.draft?.listTo.joined(separator: ", ") ?? ""
                ccLine = self.draft?.listCc.joined(separator: ", ") ?? ""
                problem = nil
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

    /// Change the open draft and keep it.
    private func change(_ edit: (inout MailReplyDraft) -> Void) {
        guard var changed = draft else {
            return
        }
        edit(&changed)
        fleetModel.mailDrafts.update(changed)
    }

    private func binding(_ keyPath: WritableKeyPath<MailReplyDraft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in change { $0[keyPath: keyPath] = value } }
        )
    }

    /// Have Mail send the draft, then let it go from the drafts.
    private func send(_ draft: MailReplyDraft) {
        isSending = true
        problem = nil
        Task {
            do {
                try await fleetModel.mailService.send(draft)
                withAnimation(.easeOut(duration: 0.2)) {
                    if memory.openDraftId == draft.id {
                        memory.openDraftId = nil
                    }
                    fleetModel.mailDrafts.remove(draft.id)
                }
                onSent()
            } catch {
                problem = String(describing: error)
            }
            isSending = false
        }
    }
}
