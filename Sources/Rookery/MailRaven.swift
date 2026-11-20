import QuickLook
import QuickLookThumbnailing
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
                isQueueing: true,
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
    @State private var isDropTargeted = false
    /// The attachment shown in Quick Look.
    @State private var previewURL: URL?
    /// Where images pasted or dropped as data are kept to be attached.
    private static var pastedImageDirectory: URL {
        DataDirectory.url.appending(path: "mail-attachments", directoryHint: .isDirectory)
    }

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
                attachmentTiles(of: draft)
                if let problem {
                    RookeryLabel(problem, icon: .warning)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                actionBar(for: draft)
            }
            .padding(14)
            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.separator), lineWidth: isDropTargeted ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .quickLookPreview($previewURL)
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { listProviders in
                takeDropped(listProviders)
                return true
            }
            .onPasteCommand(of: [.fileURL, .image]) { listProviders in
                takeDropped(listProviders)
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

    /// The files going with the mail, each as a tile with its preview.
    @ViewBuilder
    private func attachmentTiles(of draft: MailReplyDraft) -> some View {
        if !draft.listAttachments.isEmpty {
            FlowRow(spacing: 10) {
                ForEach(draft.listAttachments, id: \.self) { path in
                    MailAttachmentTile(path: path) {
                        previewURL = URL(fileURLWithPath: path)
                    } onRemove: {
                        change { $0.listAttachments.removeAll { $0 == path } }
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: draft.listAttachments)
        }
    }

    /// Throwing the draft away, attaching to it, and sending it.
    private func actionBar(for draft: MailReplyDraft) -> some View {
        HStack(spacing: 8) {
            Button("Discard") {
                withAnimation(.easeOut(duration: 0.2)) {
                    memory.openDraftId = nil
                    fleetModel.mailDrafts.remove(draft.id)
                }
            }
            Button {
                chooseFiles()
            } label: {
                Image(systemName: "paperclip")
            }
            .help(draft.replyToMessageId == nil || quotedSender == nil ? "Attach files" : "Attach files; Mail puts them above your text and sends the reply without quoting the message it answers")
            Button {
                pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Attach the image or files on the clipboard")
            Spacer(minLength: 0)
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

    /// Add files to the open draft, as long as they come to no more than a mail carries.
    private func attach(_ listPaths: [String]) {
        guard let current = draft else {
            return
        }
        let listNew = listPaths.filter { !current.listAttachments.contains($0) }
        let total = (current.listAttachments + listNew).reduce(0) { sum, path in
            sum + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0)
        }
        guard total <= MailReplyDraft.attachmentLimitBytes else {
            problem = "The attachments would come to more than 20 MB, more than mail servers take."
            return
        }
        problem = nil
        change { $0.listAttachments += listNew }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else {
            return
        }
        attach(panel.urls.map(\.path))
    }

    /// Attach what the clipboard holds: files copied in the Finder, or an image, kept as a PNG.
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let listURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !listURLs.isEmpty {
            attach(listURLs.map(\.path))
            return
        }
        guard let image = NSImage(pasteboard: pasteboard), let path = Self.keep(image) else {
            problem = "The clipboard holds no image or file to attach."
            return
        }
        attach([path])
    }

    private func takeDropped(_ listProviders: [NSItemProvider]) {
        for provider in listProviders {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let path = url?.path else { return }
                    Task { @MainActor in attach([path]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in
                        if let path = Self.keep(image) {
                            attach([path])
                        }
                    }
                }
            }
        }
    }

    /// Keep an image as a PNG file to attach, named for when it was pasted.
    private static func keep(_ image: NSImage) -> String? {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = pastedImageDirectory.appending(path: "Image \(formatter.string(from: .now)).png")
        do {
            try FileManager.default.createDirectory(at: pastedImageDirectory, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            return nil
        }
        return url.path
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


/// A file going with a mail as a tile: a preview of it, as Quick Look draws one, and its name; a click
/// opens it in its app, its menu shows it in Quick Look or the Finder, and a button over its corner takes
/// it off.
struct MailAttachmentTile: View {
    private static let side: CGFloat = 92
    private static let cornerRadius: CGFloat = 10

    let path: String
    let onPreview: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    private var url: URL {
        URL(fileURLWithPath: path)
    }

    private var isPresent: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(spacing: 5) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(StageColors.content)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: Self.side, height: Self.side)
                            .clipped()
                    } else if isPresent {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(isPresent ? AnyShapeStyle(StageColors.separator) : AnyShapeStyle(Color.orange), lineWidth: 1)
                }
                .scaleEffect(isHovered ? 1.03 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!isPresent)
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.65), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                    .help("Take \(url.lastPathComponent) off")
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.side)
        }
        .onHover { isHovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = isHovering
            }
        }
        .help(isPresent ? "Open \(url.lastPathComponent)" : "\(url.path) is not on this Mac")
        .contextMenu {
            Button("Open") {
                NSWorkspace.shared.open(url)
            }
            .disabled(!isPresent)
            Button("Quick Look", action: onPreview)
                .disabled(!isPresent)
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
            .disabled(!isPresent)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
        .task(id: path) {
            thumbnail = await Self.thumbnail(of: url, side: Self.side)
        }
    }

    /// A preview of a file as Quick Look draws it, at the tile's size, or nil when it draws none.
    private static func thumbnail(of url: URL, side: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
