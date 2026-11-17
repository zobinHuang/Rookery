import AppKit
import RookeryCore
import SwiftUI

/// The right sidebar's mail. A tab for every inbox's unread mail together, then one per account, each with
/// its unread count; an account's tab lists its unread mail above and its read mail below, each a page at
/// a time, newest first. A row opens the mail page on its message, and an unread one can be marked read
/// from where it is.
struct UnreadMailView: View {
    let personal: PersonalDataModel
    let onOpenMessage: (MailMessageSummary) -> Void
    let onOpenPage: () -> Void
    let onOpenSettings: () -> Void

    @State private var shownAccount: String?
    @State private var unreadPage = 0
    @State private var readPage = 0
    @State private var listUnreadShown: [MailMessageSummary] = []
    @State private var listReadShown: [MailMessageSummary] = []
    @State private var hoveredId: Int?
    @State private var problem: String?

    private var listAccounts: [String] {
        personal.mapInboxCounts.keys.sorted()
    }

    private var unreadCount: Int {
        shownAccount.map { personal.mapInboxCounts[$0]?.unread ?? 0 } ?? personal.unreadTotal
    }

    private var readCount: Int {
        guard let shownAccount, let counts = personal.mapInboxCounts[shownAccount] else {
            return 0
        }
        return max(0, counts.total - counts.unread)
    }

    /// What the shown pages depend on, so they are read again when any of it changes.
    private var pageKey: String {
        "\(shownAccount ?? "")|\(unreadPage)|\(readPage)|\(personal.mailGeneration)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            accountTabs
            if let access = personal.access, !access.hasFullDiskAccess {
                SidebarNotice(
                    icon: .mail,
                    title: "Mail is closed to Rookery",
                    text: "Give Rookery Full Disk Access in Settings, under Mail and Calendars, to read Mail's library.",
                    actionTitle: "Open Settings",
                    action: onOpenSettings
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        section(
                            title: "Unread",
                            count: unreadCount,
                            page: $unreadPage,
                            listMessages: listUnreadShown,
                            emptyText: shownAccount.map { "Nothing unread in \($0)." } ?? "Nothing unread in any inbox."
                        )
                        if shownAccount != nil {
                            section(
                                title: "Read",
                                count: readCount,
                                page: $readPage,
                                listMessages: listReadShown,
                                emptyText: "Nothing read in this inbox yet."
                            )
                            .padding(.top, 10)
                        }
                        if let problem {
                            Text(problem)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.red)
                                .padding(12)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .id(shownAccount ?? "")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: shownAccount)
        .task(id: pageKey) {
            await loadPages()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Mails")
                .font(.system(size: 15, weight: .bold))
            Spacer(minLength: 4)
            Button(action: onOpenPage) {
                RookeryIconView(.expand)
                    .foregroundStyle(StageColors.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open the mail")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// The tab of every inbox's unread mail, then one per account, each with its unread count.
    private var accountTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                accountTab(nil, title: "All Unread", count: personal.unreadTotal)
                ForEach(listAccounts, id: \.self) { account in
                    accountTab(account, title: Self.shortName(of: account), count: personal.mapInboxCounts[account]?.unread)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func accountTab(_ account: String?, title: String, count: Int?) -> some View {
        let isSelected = shownAccount == account
        let tint = account.map(AccountColor.of) ?? Color.accentColor
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                shownAccount = account
                unreadPage = 0
                readPage = 0
            }
        } label: {
            HStack(spacing: 5) {
                if account != nil {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if let count, count > 0 {
                    Text(RightSidebarView.count(count))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(StageColors.tertiaryText))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(StageColors.primaryText) : AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(StageColors.segmentGroove), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isSelected ? AnyShapeStyle(tint.opacity(0.5)) : AnyShapeStyle(StageColor.clear))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(account ?? "Every inbox's unread mail")
    }

    private static let setMailProviders: Set<String> = ["gmail", "googlemail", "outlook", "hotmail", "live", "icloud", "me", "yahoo", "qq", "163", "126", "foxmail"]
    private static let setDomainSuffixes: Set<String> = ["com", "net", "org", "edu", "gov", "ac", "co", "io", "ai"]

    /// An account as a tab names it: the part before the @ for a mail provider's address, else the
    /// organization its domain names, the label before the domain's suffix (`nus` for `u.nus.edu`,
    /// `ox` for `cs.ox.ac.uk`).
    static func shortName(of address: String) -> String {
        let listParts = address.lowercased().split(separator: "@")
        guard listParts.count == 2 else {
            return address
        }
        var listLabels = listParts[1].split(separator: ".").map(String.init)
        if listLabels.count > 1 {
            listLabels.removeLast()
        }
        while listLabels.count > 1, let last = listLabels.last, Self.setDomainSuffixes.contains(last) {
            listLabels.removeLast()
        }
        let organization = listLabels.last ?? ""
        return Self.setMailProviders.contains(organization) || organization.isEmpty ? String(listParts[0]) : organization
    }

    /// A titled list of one page of messages, with the page's place among them all and a way to the pages
    /// before and after.
    private func section(
        title: String,
        count: Int,
        page: Binding<Int>,
        listMessages: [MailMessageSummary],
        emptyText: String
    ) -> some View {
        let pageCount = max(1, Int((Double(count) / Double(PersonalDataModel.pageSize)).rounded(.up)))
        let first = page.wrappedValue * PersonalDataModel.pageSize
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StageColors.secondaryText)
                Text(count.formatted())
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StageColors.tertiaryText)
                Spacer(minLength: 4)
                if pageCount > 1 {
                    Text("\(first + 1)–\(min(first + PersonalDataModel.pageSize, count)) of \(count.formatted())")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(StageColors.tertiaryText)
                    pagerButton(.chevronLeft, isEnabled: page.wrappedValue > 0, help: "Newer") {
                        page.wrappedValue -= 1
                    }
                    pagerButton(.chevronRight, isEnabled: page.wrappedValue < pageCount - 1, help: "Older") {
                        page.wrappedValue += 1
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if listMessages.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            } else {
                ForEach(listMessages, id: \.id) { message in
                    row(message)
                }
            }
        }
    }

    private func pagerButton(_ icon: RookeryIcon, isEnabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RookeryIconView(icon)
                .foregroundStyle(isEnabled ? AnyShapeStyle(StageColors.secondaryText) : AnyShapeStyle(StageColors.tertiaryText.opacity(0.5)))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }

    private func row(_ message: MailMessageSummary) -> some View {
        let isHovered = hoveredId == message.id
        return Button {
            onOpenMessage(message)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(message.isRead ? AnyShapeStyle(StageColor.clear) : AnyShapeStyle(AccountColor.of(message.account)))
                    .overlay {
                        Circle()
                            .strokeBorder(message.isRead ? AnyShapeStyle(AccountColor.of(message.account).opacity(0.6)) : AnyShapeStyle(StageColor.clear))
                    }
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .help(message.account)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                            .font(.system(size: 12, weight: message.isRead ? .medium : .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if isHovered && !message.isRead {
                            Button {
                                personal.markRead(message)
                            } label: {
                                RookeryIconView(.envelopeOpen)
                                    .foregroundStyle(StageColors.secondaryText)
                            }
                            .buttonStyle(.borderless)
                            .help("Mark as read")
                        } else {
                            Text(MailTime.short(message.receivedAt))
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(StageColors.tertiaryText)
                        }
                    }
                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                        .font(.system(size: 11.5, weight: message.isRead ? .regular : .medium))
                        .foregroundStyle(message.isRead ? AnyShapeStyle(StageColors.secondaryText) : AnyShapeStyle(StageColors.primaryText))
                        .lineLimit(1)
                    if !message.snippet.isEmpty {
                        Text(message.snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(message.isRead ? 1 : 2)
                    }
                    if shownAccount == nil {
                        Text(message.account)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(AccountColor.of(message.account))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AccountColor.of(message.account).opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isHovered ? AnyShapeStyle(StageColors.hoveredRow) : AnyShapeStyle(StageColor.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredId = isInside ? message.id : (hoveredId == message.id ? nil : hoveredId)
            }
        }
    }

    private func loadPages() async {
        guard personal.access?.hasFullDiskAccess != false else {
            return
        }
        do {
            let listUnread = try await personal.inboxPage(account: shownAccount, isRead: false, page: unreadPage)
            let listRead = shownAccount == nil ? [] : try await personal.inboxPage(account: shownAccount, isRead: true, page: readPage)
            withAnimation(.easeOut(duration: 0.18)) {
                listUnreadShown = listUnread
                listReadShown = listRead
            }
            problem = nil
        } catch {
            problem = String(describing: error)
        }
    }
}

/// How a message's time reads in a list: the time today, the weekday this week, the date before.
enum MailTime {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
