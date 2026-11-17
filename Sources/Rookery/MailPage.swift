import AppKit
import RookeryCore
import SwiftUI

/// A place in the mail page's list of folders: every inbox, the unread or flagged mail of all of them, or
/// one account's folder.
enum MailPlace: Hashable {
    case allInboxes
    case unread
    case flagged
    case account(String, MailFolder)

    var title: String {
        switch self {
        case .allInboxes: "All Inboxes"
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .account(_, let folder): folder.title
        }
    }

    var icon: RookeryIcon {
        switch self {
        case .allInboxes: .mail
        case .unread: .envelopeOpen
        case .flagged: .flag
        case .account(_, let folder): folder == .sent ? .send : .mail
        }
    }

    /// The search this place lists.
    func query(text: String) -> MailQuery {
        var query = MailQuery()
        query.text = text
        query.limit = MailQuery.maximumLimit
        switch self {
        case .allInboxes:
            query.folder = .inbox
        case .unread:
            query.folder = .inbox
            query.isUnreadOnly = true
        case .flagged:
            query.isFlaggedOnly = true
        case .account(let address, let folder):
            query.listAccounts = [address]
            query.folder = folder
        }
        return query
    }
}

/// Every account's mail in the content area: the folders on the left, the list in the middle with a search,
/// and the message read on the right, with what the user can do to it: reply in Mail, mark it read or
/// unread, flag it, open it in Mail, or have Raven draft a reply.
struct MailPage: View {
    private static let folderListWidth: CGFloat = 210
    private static let messageListWidth: CGFloat = 340

    let fleetModel: FleetModel
    let onClose: () -> Void
    /// Shows the Rookmaster console, where Raven's conversations are.
    let onShowRookmaster: () -> Void

    @State private var place = MailPlace.allInboxes
    @State private var searchText = ""
    @State private var listMessages: [MailMessageSummary] = []
    @State private var mapInboxCounts: [String: MailboxCount] = [:]
    @State private var shownMessage: MailMessageDetail?
    @State private var isLoading = false
    @State private var problem: String?

    private var service: any MailSource {
        fleetModel.mailSource
    }

    private var selectedId: Int? {
        fleetModel.pageMemory.selectedMailId
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            HStack(spacing: 0) {
                folderList
                    .frame(width: Self.folderListWidth)
                divider
                messageList
                    .frame(width: Self.messageListWidth)
                divider
                reader
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .task(id: "\(place)\(searchText)") {
            await loadList()
        }
        .task(id: selectedId) {
            await loadMessage()
        }
        .onChange(of: fleetModel.personal.listUnread) {
            Task {
                await loadList()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(StageColors.separator)
            .frame(width: 1)
    }

    // MARK: - Header and folders

    private var header: some View {
        HStack(spacing: 12) {
            RookeryIconView(.mail, scale: 1.6)
            Text("Mail")
                .font(.system(size: 18, weight: .bold))
            Spacer(minLength: 8)
            if let problem {
                RookeryLabel(problem, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button(action: onClose) {
                RookeryIconView(.close)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(StageColors.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                placeRow(.allInboxes, count: mapInboxCounts.values.map(\.unread).reduce(0, +))
                placeRow(.unread, count: nil)
                placeRow(.flagged, count: nil)
                ForEach(mapInboxCounts.keys.sorted(), id: \.self) { address in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AccountColor.of(address))
                            .frame(width: 7, height: 7)
                        Text(address)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                    placeRow(.account(address, .inbox), count: mapInboxCounts[address]?.unread)
                    placeRow(.account(address, .sent), count: nil)
                }
            }
            .padding(8)
        }
    }

    private func placeRow(_ shown: MailPlace, count: Int?) -> some View {
        let isSelected = place == shown
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                place = shown
            }
        } label: {
            HStack(spacing: 7) {
                RookeryIconView(shown.icon)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                Text(shown.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text(RightSidebarView.count(count))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StageColors.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(StageColor.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var messageList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                RookeryIconView(.search)
                    .foregroundStyle(StageColors.secondaryText)
                TextField("Search subject, sender, text", text: $searchText)
                    .textFieldStyle(.plain)
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)
            if listMessages.isEmpty && !isLoading {
                SidebarNotice(icon: .envelopeOpen, title: searchText.isEmpty ? "Nothing here" : "No match", text: searchText.isEmpty ? "\(place.title) holds no mail." : "No message in \(place.title) matches.")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(listMessages, id: \.id) { message in
                            messageRow(message)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func messageRow(_ message: MailMessageSummary) -> some View {
        let isSelected = selectedId == message.id
        return Button {
            fleetModel.pageMemory.selectedMailId = message.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(message.isRead ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                            .font(.system(size: 12, weight: message.isRead ? .medium : .bold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if message.isFlagged {
                            RookeryIconView(.flag)
                                .foregroundStyle(.orange)
                        }
                        Text(MailTime.short(message.receivedAt))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(StageColors.tertiaryText)
                    }
                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                        .font(.system(size: 11.5, weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Text(message.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(2)
                    if case .allInboxes = place {
                        Text(message.account)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AccountColor.of(message.account))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(StageColor.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reader

    @ViewBuilder
    private var reader: some View {
        if let message = shownMessage {
            VStack(spacing: 0) {
                readerToolbar(message)
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message.summary.subject.isEmpty ? "No subject" : message.summary.subject)
                            .font(.system(size: 18, weight: .bold))
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 3) {
                            readerLine("From", Self.people([message.summary.from]))
                            if !message.listTo.isEmpty {
                                readerLine("To", Self.people(message.listTo))
                            }
                            if !message.listCc.isEmpty {
                                readerLine("Cc", Self.people(message.listCc))
                            }
                            readerLine("Date", message.summary.receivedAt.formatted(date: .complete, time: .shortened))
                            readerLine("Account", message.summary.account)
                        }
                        if !message.listAttachments.isEmpty {
                            FlowRow(spacing: 5) {
                                ForEach(message.listAttachments, id: \.self) { name in
                                    InfoTag(name)
                                }
                            }
                        }
                        Rectangle()
                            .fill(StageColors.separator)
                            .frame(height: 1)
                        Text(message.text.isEmpty ? "Mail has not downloaded this message's text; open it in Mail." : message.text)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(message.text.isEmpty ? StageColors.secondaryText : StageColors.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                    .frame(maxWidth: 780, alignment: .leading)
                }
            }
        } else {
            SidebarNotice(icon: .mail, title: "No message chosen", text: "Pick a message to read it here.")
        }
    }

    /// What the user can do to the message: with titles where they fit, as icons alone where they do not.
    private func readerToolbar(_ message: MailMessageDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarButtons(message, isTitled: true)
            toolbarButtons(message, isTitled: false)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func toolbarButtons(_ message: MailMessageDetail, isTitled: Bool) -> some View {
        HStack(spacing: 8) {
            toolbarButton("Reply in Mail", icon: .undo, isTitled: isTitled) {
                act { try await service.reply(to: message.summary) }
            }
            toolbarButton(message.summary.isRead ? "Mark Unread" : "Mark Read", icon: .envelopeOpen, isTitled: isTitled) {
                act { try await service.markRead(message.summary, isRead: !message.summary.isRead) }
            }
            toolbarButton(message.summary.isFlagged ? "Unflag" : "Flag", icon: .flag, isTitled: isTitled) {
                act { try await service.flag(message.summary, isFlagged: !message.summary.isFlagged) }
            }
            Spacer(minLength: 0)
            toolbarButton("Draft with Raven", icon: .sparkles, isTitled: isTitled) {
                askRaven(message)
            }
            toolbarButton("Open in Mail", icon: .release, isTitled: isTitled) {
                act { try await service.openInMail(message.summary) }
            }
        }
    }

    private func toolbarButton(_ title: String, icon: RookeryIcon, isTitled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isTitled {
                RookeryLabel(title, icon: icon, spacing: 4)
                    .fixedSize()
            } else {
                RookeryIconView(icon)
            }
        }
        .help(title)
    }

    private func readerLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private static func people(_ listPeople: [MailAddress]) -> String {
        listPeople.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", ")
    }

    // MARK: - Work

    private func loadList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            listMessages = try await service.search(place.query(text: searchText.trimmingCharacters(in: .whitespaces)))
            mapInboxCounts = try await service.inboxCounts()
            problem = nil
            if selectedId == nil {
                fleetModel.pageMemory.selectedMailId = listMessages.first?.id
            }
        } catch {
            problem = String(describing: error)
        }
    }

    private func loadMessage() async {
        guard let selectedId else {
            shownMessage = nil
            return
        }
        do {
            shownMessage = try await service.message(selectedId)
        } catch {
            problem = String(describing: error)
        }
    }

    /// Do something to the message in Mail, then read the list and the message again.
    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                problem = nil
            } catch {
                problem = String(describing: error)
            }
            await loadList()
            await loadMessage()
        }
    }

    /// Ask Raven, in a new conversation, to draft a reply to the message, and show the conversation.
    private func askRaven(_ message: MailMessageDetail) {
        let request = "Draft a reply to the message with id \(message.summary.id) in \(message.summary.account), from \(Self.people([message.summary.from])), subject \"\(message.summary.subject)\". Read it and its thread first, then propose the draft."
        fleetModel.pageMemory.panelTab = .raven
        fleetModel.pageMemory.isPanelExpanded = true
        fleetModel.raven.ask(request, mentioning: [], in: nil)
        onShowRookmaster()
    }
}
