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

    let fleetModel: FleetModel
    let onClose: () -> Void
    /// Shows the Rookmaster console, where Raven's conversations are.
    let onShowRookmaster: () -> Void

    /// The widest the reader's conversation runs.
    private static let readerMaxWidth: CGFloat = 860
    private static let threadLineWidth: CGFloat = 1.5
    private static let threadDotSize: CGFloat = 11
    /// How far down its card a message's dot sits, level with the sender's name.
    private static let threadDotTop: CGFloat = 22

    @State private var place = MailPlace.allInboxes
    @State private var searchText = ""
    @State private var listMessages: [MailMessageSummary] = []
    @State private var mapInboxCounts: [String: MailboxCount] = [:]
    @State private var shownMessage: MailMessageDetail?
    /// The message last read for the reader, whether or not Mail still held it.
    @State private var loadedMessageId: Int?
    @State private var isLoading = false
    @State private var problem: String?
    /// The conversation of the message chosen, newest first, its messages read in full, and those the
    /// user folded; every other one is open.
    @State private var listThread: [MailMessageSummary] = []
    @State private var mapDetails: [Int: MailMessageDetail] = [:]
    @State private var setFoldedIds: Set<Int> = []

    @Environment(\.people) private var people

    private var service: any MailSource {
        fleetModel.mailSource
    }

    private var columns: PageColumns {
        fleetModel.pageColumns
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
                if !columns.isHidden(.mailFolders) {
                    folderList
                        .frame(width: columns.width(of: .mailFolders))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ColumnDivider(columns: columns, column: .mailFolders)
                }
                messageList
                    .frame(width: columns.width(of: .mailMessages))
                ColumnDivider(columns: columns, column: .mailMessages)
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
            ColumnToggle(columns: columns, column: .mailFolders, title: "Mailboxes")
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
                    .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
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
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StageColors.selectedRow)
                        .strokeBorder(StageColors.contrastActiveBorder)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                }
            }
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
            if listMessages.isEmpty && isLoading {
                PageLoading(title: "Reading \(place.title)")
            } else if listMessages.isEmpty {
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
                    .fill(message.isRead ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.primaryText))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        AddressLabel(address: message.from, markSize: 16)
                            .font(.system(size: 12, weight: message.isRead ? .medium : .bold))
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
                            .foregroundStyle(StageColors.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(StageColors.selectedRow)
                        .strokeBorder(StageColors.contrastActiveBorder)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reader

    @ViewBuilder
    private var reader: some View {
        if let selectedId, loadedMessageId != selectedId {
            PageLoading(title: "Opening the message")
                .transition(.opacity)
        } else if let message = shownMessage {
            VStack(spacing: 0) {
                readerToolbar(message)
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        threadHeader(message)
                            .padding(.bottom, 18)
                        ForEach(Array(listThread.enumerated()), id: \.element.id) { index, summary in
                            threadItem(summary, isFirst: index == 0, isLast: index == listThread.count - 1)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: Self.readerMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            SidebarNotice(icon: .mail, title: "No message chosen", text: "Pick a message to read it here.")
        }
    }

    /// The conversation's subject, how many messages it holds and which account it is in.
    private func threadHeader(_ message: MailMessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.summary.subject.isEmpty ? "No subject" : message.summary.subject)
                .font(.system(size: 19, weight: .bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(listThread.count == 1 ? "1 message in \(message.summary.account)" : "\(listThread.count) messages in \(message.summary.account)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StageColors.secondaryText)
            }
        }
    }

    /// One message of the conversation on its line: a dot on the line that runs through them all, the
    /// line drawn from the message before to the one after, and the message's card beside it.
    private func threadItem(_ summary: MailMessageSummary, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.separator))
                    .frame(width: Self.threadLineWidth, height: Self.threadDotTop)
                Circle()
                    .fill(summary.isRead ? AnyShapeStyle(StageColors.window) : AnyShapeStyle(StageColors.primaryText))
                    .overlay {
                        Circle()
                            .strokeBorder(summary.isRead ? AnyShapeStyle(StageColors.tertiaryText) : AnyShapeStyle(StageColors.primaryText), lineWidth: 1.5)
                    }
                    .frame(width: Self.threadDotSize, height: Self.threadDotSize)
                Rectangle()
                    .fill(isLast ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.separator))
                    .frame(width: Self.threadLineWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: Self.threadDotSize)
            MailMessageCard(
                summary: summary,
                detail: mapDetails[summary.id],
                isOpen: !setFoldedIds.contains(summary.id),
                isChosen: summary.id == selectedId,
                onToggle: { toggle(summary) }
            )
            .task(id: summary.id) {
                await loadDetail(of: summary.id)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
    }

    /// Read a message of the conversation in full, once.
    private func loadDetail(of messageId: Int) async {
        guard mapDetails[messageId] == nil else {
            return
        }
        do {
            mapDetails[messageId] = try await service.message(messageId)
        } catch {
            problem = String(describing: error)
        }
    }

    /// Fold a message of the conversation to its opening, or open it again.
    private func toggle(_ summary: MailMessageSummary) {
        if setFoldedIds.contains(summary.id) {
            setFoldedIds.remove(summary.id)
        } else {
            setFoldedIds.insert(summary.id)
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
            let detail = try await service.message(selectedId)
            shownMessage = detail
            if let detail {
                mapDetails[selectedId] = detail
                let listFound = try await service.thread(of: detail.summary)
                listThread = listFound.contains(where: { $0.id == selectedId }) ? listFound.reversed() : [detail.summary]
                setFoldedIds = []
            } else {
                listThread = []
            }
        } catch {
            problem = String(describing: error)
        }
        loadedMessageId = selectedId
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

/// A message of a conversation in its card: its sender, to whom and when, then its own words, formatted as
/// sent when it has HTML, the earlier mail it quotes shown only when asked, and its attachments; folded to
/// its opening when the user folds it. Its head folds and opens it. It keeps its own height and quote, so
/// the formatted text growing redraws only this card.
private struct MailMessageCard: View {
    /// A formatted message's height until its own is read, and the least it takes.
    private static let bodyStartHeight: CGFloat = 120
    private static let bodyMinimumHeight: CGFloat = 40

    let summary: MailMessageSummary
    let detail: MailMessageDetail?
    let isOpen: Bool
    let isChosen: Bool
    let onToggle: () -> Void

    @State private var bodyHeight: CGFloat?
    @State private var isQuoteTrimmed = false
    @State private var isQuoteShown = false
    @Environment(\.people) private var people

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                head
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Fold this message" : "Open this message")
            if isOpen {
                if let detail {
                    messageBody(detail)
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(14)
        .background(StageColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isChosen ? AnyShapeStyle(StageColors.secondaryText.opacity(0.35)) : AnyShapeStyle(StageColors.separator))
        }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: 10) {
            PersonMark(
                person: people?.person(withAddress: summary.from.address),
                fallbackName: summary.from.name,
                fallbackAddress: summary.from.address,
                size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AddressLabel(address: summary.from)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 6)
                    Text(summary.receivedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(StageColors.tertiaryText)
                }
                if isOpen, let detail, !detail.listTo.isEmpty {
                    Text("to \(AddressLabel.names(detail.listTo + detail.listCc, people: people))")
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(2)
                } else if !isOpen {
                    Text(summary.snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// A message's text: as sent, on a page of its own, when it has HTML; else its plain text; then its
    /// attachments.
    @ViewBuilder
    private func messageBody(_ detail: MailMessageDetail) -> some View {
        let trimmedText = detail.html.isEmpty ? MailQuote.trimmed(detail.text) : nil
        if !detail.html.isEmpty {
            MailHTMLView(
                html: detail.html,
                isRemoteAllowed: true,
                isQuoteTrimmed: !isQuoteShown,
                onQuoteTrimmed: { isTrimmed in
                    if isTrimmed {
                        isQuoteTrimmed = true
                    }
                },
                onHeight: { height in
                    if bodyHeight != height {
                        bodyHeight = height
                    }
                }
            )
            .frame(height: max(bodyHeight ?? Self.bodyStartHeight, Self.bodyMinimumHeight))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
        } else {
            Text(detail.text.isEmpty ? "Mail has not downloaded this message's text; open it in Mail." : (isQuoteShown ? detail.text : trimmedText ?? detail.text))
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(detail.text.isEmpty ? AnyShapeStyle(StageColors.secondaryText) : AnyShapeStyle(StageColors.primaryText))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if isQuoteTrimmed || trimmedText != nil {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    isQuoteShown.toggle()
                }
            } label: {
                RookeryLabel(isQuoteShown ? "Hide Quoted Mail" : "Show Quoted Mail", icon: .ellipsis)
                    .font(.system(size: 11.5))
            }
            .help(isQuoteShown ? "Show only what this message says" : "Show the earlier mail this message quotes")
        }
        if !detail.listAttachments.isEmpty {
            FlowRow(spacing: 5) {
                ForEach(detail.listAttachments, id: \.self) { name in
                    InfoTag(name)
                }
            }
        }
    }
}
