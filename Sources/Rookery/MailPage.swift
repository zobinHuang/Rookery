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

    /// The widest the reader's conversation runs.
    private static let readerMaxWidth: CGFloat = 860
    /// How many rows and messages stand in for a list or a conversation still on its way.
    /// The folders whose messages a conversation leaves out, as drafts thrown away while replying, unless
    /// the one chosen is among them.
    private static let setHiddenThreadFolders: Set<MailFolder> = [.trash, .junk, .drafts]
    private static let skeletonRowCount = 8
    /// The least reader width that names the toolbar's buttons rather than showing their icons alone.
    private static let titledToolbarWidth: CGFloat = 620
    private static let skeletonMessageCount = 2

    @State private var place = MailPlace.allInboxes
    @State private var searchText = ""
    @State private var listMessages: [MailMessageSummary] = []
    @State private var mapInboxCounts: [String: MailboxCount] = [:]
    @State private var shownMessage: MailMessageDetail?
    /// The message last read for the reader, whether or not Mail still held it.
    @State private var loadedMessageId: Int?
    @State private var isLoading = false
    /// Whether the list was read at least once, so an empty one means no mail rather than not yet.
    @State private var hasLoadedList = false
    @State private var isToolbarTitled = true
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

    private static let replyEditorId = "mail.reply"

    /// Who wrote the message the mail being written answers, by name if they gave one.
    private var quotedSender: String? {
        guard
            let replyToId = fleetModel.pageMemory.mailReplyDraft?.replyToMessageId,
            let original = listThread.first(where: { $0.id == replyToId })
        else {
            return nil
        }
        return original.from.name.isEmpty ? original.from.address : original.from.name
    }

    /// Whether the mail being written answers a message of the thread shown.
    private var isReplyInThread: Bool {
        guard let replyToId = fleetModel.pageMemory.mailReplyDraft?.replyToMessageId else {
            return false
        }
        return listThread.contains { $0.id == replyToId }
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
                if let message = shownMessage, !columns.isHidden(.mailRaven) {
                    ColumnDivider(columns: columns, column: .mailRaven, isTrailing: true)
                    MailRavenPanel(fleetModel: fleetModel, message: message, listThreadIds: listThread.map(\.id))
                        .frame(width: columns.width(of: .mailRaven))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: columns.isHidden(.mailRaven))
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
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(StageColors.groove, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)
            if listMessages.isEmpty && (isLoading || !hasLoadedList) {
                listSkeleton
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
        if let message = shownMessage {
            let isSwitching = selectedId != nil && loadedMessageId != selectedId
            VStack(spacing: 0) {
                readerToolbar(message)
                Rectangle()
                    .fill(StageColors.separator)
                    .frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            threadHeader(message)
                                .padding(.bottom, 18)
                            ForEach(listThread, id: \.id) { summary in
                                threadItem(summary)
                                    .padding(.bottom, 22)
                            }
                            if isReplyInThread {
                                MailReplyEditor(fleetModel: fleetModel, quotedSender: quotedSender) {
                                    act {}
                                }
                                .id(Self.replyEditorId)
                                .padding(.bottom, 22)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                        .frame(maxWidth: Self.readerMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: fleetModel.pageMemory.mailReplyDraft?.replyToMessageId) { _, replyToId in
                        guard replyToId != nil else {
                            return
                        }
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(Self.replyEditorId, anchor: .bottom)
                        }
                    }
                }
                .id(message.summary.id)
                .opacity(isSwitching ? 0.55 : 1)
                .animation(.easeOut(duration: 0.15), value: isSwitching)
            }
        } else if selectedId != nil {
            readerSkeleton
                .transition(.opacity)
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

    /// One message of the conversation, in its bubble on the side of whoever wrote it, read in full once
    /// it comes into view.
    private func threadItem(_ summary: MailMessageSummary) -> some View {
        MailMessageCard(
            summary: summary,
            detail: mapDetails[summary.id],
            isOpen: !setFoldedIds.contains(summary.id),
            isMine: summary.from.address.caseInsensitiveCompare(summary.account) == .orderedSame,
            onToggle: { toggle(summary) }
        )
        .task(id: summary.id) {
            await loadDetail(of: summary.id)
        }
    }

    /// The rows of a list still being read: a mark, a sender, a subject and a line of text each.
    private var listSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<Self.skeletonRowCount, id: \.self) { _ in
                HStack(alignment: .top, spacing: 8) {
                    SkeletonBlock(width: 6, height: 6, cornerRadius: 3)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 110, height: 9)
                        SkeletonBlock(height: 8)
                        SkeletonBlock(width: 170, height: 8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// A conversation still being opened: its subject and a message or two, as they will stand.
    private var readerSkeleton: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 300, height: 18, cornerRadius: 6)
                SkeletonBlock(width: 170, height: 9)
            }
            ForEach(0..<Self.skeletonMessageCount, id: \.self) { _ in
                HStack(alignment: .top, spacing: 10) {
                    SkeletonBlock(width: MailMessageCard.markSize, height: MailMessageCard.markSize, cornerRadius: MailMessageCard.markSize / 2)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: 140, height: 9)
                        MailMessageCard.bubbleSkeleton(isMine: false)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: Self.readerMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// What the user can do to the message: with titles where the reader is wide enough for them, as icons
    /// alone where it is not.
    private func readerToolbar(_ message: MailMessageDetail) -> some View {
        let titledWidth = Self.titledToolbarWidth
        return toolbarButtons(message, isTitled: isToolbarTitled)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width >= titledWidth
            } action: { isWide in
                isToolbarTitled = isWide
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    private func toolbarButtons(_ message: MailMessageDetail, isTitled: Bool) -> some View {
        HStack(spacing: 8) {
            toolbarButton("Reply", icon: .undo, isTitled: isTitled) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    if !isReplyInThread {
                        fleetModel.pageMemory.mailReplyDraft = MailReplyDraft(replyingTo: message.summary)
                    }
                }
            }
            toolbarButton("Reply in Mail", icon: .release, isTitled: isTitled) {
                act { try await service.reply(to: message.summary) }
            }
            toolbarButton(message.summary.isRead ? "Mark Unread" : "Mark Read", icon: .envelopeOpen, isTitled: isTitled) {
                act { try await service.markRead(message.summary, isRead: !message.summary.isRead) }
            }
            toolbarButton(message.summary.isFlagged ? "Unflag" : "Flag", icon: .flag, isTitled: isTitled) {
                act { try await service.flag(message.summary, isFlagged: !message.summary.isFlagged) }
            }
            Spacer(minLength: 0)
            toolbarButton(columns.isHidden(.mailRaven) ? "Ask Raven" : "Hide Raven", icon: .sparkles, isTitled: isTitled) {
                columns.toggle(.mailRaven)
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
        defer {
            isLoading = false
            hasLoadedList = true
        }
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
            var listFound: [MailMessageSummary] = []
            if let detail {
                listFound = try await service.thread(of: detail.summary)
            }
            guard !Task.isCancelled else {
                return
            }
            if let detail {
                mapDetails[selectedId] = detail
                let listShown = listFound.filter { $0.id == selectedId || !Self.setHiddenThreadFolders.contains($0.folder) }
                listThread = listShown.contains(where: { $0.id == selectedId }) ? listShown.reversed() : [detail.summary]
            } else {
                listThread = []
            }
            setFoldedIds = []
            shownMessage = detail
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
}

/// A message of a conversation as a bubble on the side of whoever wrote it, as a chat shows it: the
/// user's own on the right, everyone else's on the left with their mark at its top left and the bubble's tail
/// reaching up to it; over it the sender, when
/// and to whom, which fold it to its opening and open it again. Inside, its own words, as sent when it has
/// HTML, the earlier mail it quotes only when asked; under it, its attachments. It keeps its own height and
/// quote, so the formatted text growing redraws only this message.
struct MailMessageCard: View {
    static let markSize: CGFloat = 32
    private static let markSpacing: CGFloat = 10
    /// The room a bubble leaves on the side away from its writer, so the two sides read apart.
    private static let farSideRoom: CGFloat = 56
    private static let cornerRadius: CGFloat = 17
    private static let bodyMinimumHeight: CGFloat = 40
    private static let skeletonHeight: CGFloat = 112
    private static let paperColor = Color.white

    let summary: MailMessageSummary
    let detail: MailMessageDetail?
    let isOpen: Bool
    let isMine: Bool
    let onToggle: () -> Void

    @State private var bodyHeight: CGFloat?
    @State private var isQuoteTrimmed = false
    @State private var isQuoteShown = false
    @Environment(\.people) private var people

    /// The person who wrote it, as the user set them down: anyone else always has a mark, from their
    /// person or their address; the user has one only once they set themselves down.
    private var writer: Person? {
        people?.person(withAddress: summary.from.address)
    }

    private var hasMark: Bool {
        !isMine || writer != nil
    }

    var body: some View {
        let edgeAnchor: UnitPoint = isMine ? .trailing : .leading
        let markRoom = hasMark ? Self.markSize + Self.markSpacing : 0
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Self.markSpacing) {
                if !isMine {
                    mark
                }
                VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                    Button(action: onToggle) {
                        head
                    }
                    .buttonStyle(.plain)
                    .help(isOpen ? "Fold this message" : "Open this message")
                    bubble
                }
                .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
                if isMine, hasMark {
                    mark
                }
            }
            if isOpen, let detail {
                footer(detail)
                    .padding(isMine ? .trailing : .leading, markRoom)
                    .padding(isMine ? .leading : .trailing, Self.farSideRoom)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isOpen)
        .animation(.easeOut(duration: 0.25), value: bodyHeight != nil)
        .scrollTransition(.interactive, axis: .vertical) { view, phase in
            view
                .scaleEffect(phase.isIdentity ? 1 : 0.95, anchor: edgeAnchor)
                .opacity(phase.isIdentity ? 1 : 0.6)
                .offset(y: phase.value * 8)
        }
    }

    private var mark: some View {
        PersonMark(
            person: writer,
            fallbackName: summary.from.name,
            fallbackAddress: summary.from.address,
            size: Self.markSize
        )
    }

    /// Who wrote it and when, and while open to whom.
    private var head: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if isMine {
                    time
                }
                AddressLabel(address: summary.from)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StageColors.primaryText)
                if !isMine {
                    time
                }
            }
            if isOpen, let detail, !detail.listTo.isEmpty {
                Text("to \(AddressLabel.names(detail.listTo + detail.listCc, people: people))")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var time: some View {
        Text(summary.receivedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(StageColors.tertiaryText)
    }

    @ViewBuilder
    private var bubble: some View {
        if !isOpen {
            Button(action: onToggle) {
                textBubble(summary.snippet.isEmpty ? "No text" : summary.snippet, lineLimit: 2)
            }
            .buttonStyle(.plain)
            .help("Open this message")
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: isMine ? .topTrailing : .topLeading)))
        } else if let detail {
            if detail.html.isEmpty {
                textBubble(textShown(of: detail), lineLimit: nil)
                    .textSelection(.enabled)
                    .transition(.opacity)
            } else {
                pageBubble(detail)
            }
        } else {
            Self.bubbleSkeleton(isMine: isMine)
                .transition(.opacity)
        }
    }

    /// A bubble still on its way: its outline in the theme with lines of text sweeping in it.
    static func bubbleSkeleton(isMine: Bool) -> some View {
        SkeletonLines(count: 4, lineHeight: 8, spacing: 9)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(height: skeletonHeight, alignment: .top)
            .background {
                MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                    .fill(StageColors.agentBubble)
                    .overlay {
                        MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                            .stroke(StageColors.agentBubbleBorder, lineWidth: 1)
                    }
            }
            .padding(isMine ? .leading : .trailing, farSideRoom)
    }

    /// Plain text in a bubble of the conversation's colors: the user's in the theme turned over; the mail
    /// it quotes drawn as quoted, under a bar for each level, its `>` marks taken off.
    private func textBubble(_ text: String, lineLimit: Int?) -> some View {
        let listPassages = MailQuote.passages(of: text)
        let ink = isMine ? AnyShapeStyle(StageColors.userBubbleText) : AnyShapeStyle(StageColors.primaryText)
        return VStack(alignment: .leading, spacing: 8) {
            if lineLimit != nil || listPassages.allSatisfy({ $0.depth == 0 }) {
                Text(listPassages.map(\.text).joined(separator: "\n"))
                    .lineLimit(lineLimit)
            } else {
                ForEach(Array(listPassages.enumerated()), id: \.offset) { _, passage in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<passage.depth, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(ink)
                                .opacity(0.3)
                                .frame(width: 2)
                        }
                        Text(passage.text)
                            .opacity(passage.depth == 0 ? 1 : 0.72)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2.5)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(ink)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background {
            MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                .fill(isMine ? AnyShapeStyle(StageColors.userBubble) : AnyShapeStyle(StageColors.agentBubble))
                .overlay {
                    MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                        .stroke(isMine ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(StageColors.agentBubbleBorder), lineWidth: 1)
                }
        }
        .padding(isMine ? .leading : .trailing, Self.farSideRoom)
    }

    /// Formatted text on its own white page, shaped as a bubble; its outline sweeps until the page is laid
    /// out and takes its height.
    private func pageBubble(_ detail: MailMessageDetail) -> some View {
        let isLaidOut = bodyHeight != nil
        return ZStack(alignment: .topLeading) {
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
            .frame(height: max(bodyHeight ?? Self.skeletonHeight, Self.bodyMinimumHeight))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .background {
                MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                    .fill(Self.paperColor)
                    .overlay {
                        MessageBubbleShape(isTrailing: isMine, hasTail: true, isTailOnTop: true)
                            .stroke(StageColors.agentBubbleBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
            }
            .opacity(isLaidOut ? 1 : 0)
            if !isLaidOut {
                Self.bubbleSkeleton(isMine: isMine)
                    .transition(.opacity)
            }
        }
        .padding(isMine ? .leading : .trailing, isLaidOut ? Self.farSideRoom : 0)
    }

    private func textShown(of detail: MailMessageDetail) -> String {
        if detail.text.isEmpty {
            return "Mail has not downloaded this message's text; open it in Mail."
        }
        return isQuoteShown ? detail.text : MailQuote.trimmed(detail.text) ?? detail.text
    }

    /// Under the bubble: the quoted mail's switch, when there is any, and the attachments.
    @ViewBuilder
    private func footer(_ detail: MailMessageDetail) -> some View {
        let hasQuote = isQuoteTrimmed || (detail.html.isEmpty && MailQuote.trimmed(detail.text) != nil)
        if hasQuote || !detail.listAttachments.isEmpty {
            FlowRow(spacing: 6, isTrailing: isMine) {
                if hasQuote {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isQuoteShown.toggle()
                        }
                    } label: {
                        RookeryLabel(isQuoteShown ? "Hide Quoted Mail" : "Show Quoted Mail", icon: .ellipsis)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StageColors.secondaryText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(StageColors.segmentGroove, in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(StageColors.segmentGrooveBorder)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(isQuoteShown ? "Show only what this message says" : "Show the earlier mail this message quotes")
                }
                ForEach(detail.listAttachments, id: \.self) { name in
                    InfoTag(name)
                }
            }
        }
    }
}
