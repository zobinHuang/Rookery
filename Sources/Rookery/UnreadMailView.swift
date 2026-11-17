import AppKit
import RookeryCore
import SwiftUI

/// The right sidebar's mail: every account's unread inbox mail, newest first, each with its sender,
/// subject, opening and account; one account's alone when picked. A row opens the mail page on it, and
/// marks it read or opens it in Mail from where it is.
struct UnreadMailView: View {
    let personal: PersonalDataModel
    let onOpenMessage: (MailMessageSummary) -> Void
    let onOpenPage: () -> Void
    let onOpenSettings: () -> Void

    @State private var hoveredId: Int?

    private var shownAccount: String? {
        personal.shownMailAccount
    }

    private var listShown: [MailMessageSummary] {
        guard let shownAccount else {
            return personal.listUnread
        }
        return personal.listUnread.filter { $0.account == shownAccount }
    }

    private var listAccounts: [String] {
        Array(Set(personal.mapUnreadCounts.keys).union(personal.listUnread.map(\.account))).sorted()
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
            } else if listShown.isEmpty {
                SidebarNotice(icon: .envelopeOpen, title: "All read", text: shownAccount.map { "Nothing unread in \($0)." } ?? "Nothing unread in any inbox.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(listShown, id: \.id) { message in
                            row(message)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: listShown.map(\.id))
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Unread")
                    .font(.system(size: 15, weight: .bold))
                Text(shownAccount.map { "\(personal.mapUnreadCounts[$0] ?? listShown.count) in \($0)" } ?? "\(personal.unreadTotal) in every inbox")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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

    /// A tab for every inbox together and one for each account, each with its unread count, which lists
    /// that account's mail alone.
    private var accountTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                accountTab(nil, title: "All", count: personal.unreadTotal)
                ForEach(listAccounts, id: \.self) { account in
                    accountTab(account, title: Self.shortName(of: account), count: personal.mapUnreadCounts[account])
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
                personal.showMailAccount(account)
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
        .help(account ?? "Every inbox")
    }

    /// An account as a tab names it: the part before the @, with the domain's first label where that is
    /// what tells two apart.
    static func shortName(of address: String) -> String {
        let listParts = address.split(separator: "@")
        guard listParts.count == 2 else {
            return address
        }
        let domain = listParts[1].split(separator: ".").first.map(String.init) ?? ""
        return ["gmail", "outlook", "hotmail", "icloud", "qq", "163"].contains(domain) ? String(listParts[0]) : domain
    }

    private func row(_ message: MailMessageSummary) -> some View {
        let isHovered = hoveredId == message.id
        return Button {
            onOpenMessage(message)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(AccountColor.of(message.account))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .help(message.account)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if isHovered {
                            actions(message)
                        } else {
                            Text(MailTime.short(message.receivedAt))
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(StageColors.tertiaryText)
                        }
                    }
                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    if !message.snippet.isEmpty {
                        Text(message.snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(2)
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
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private func actions(_ message: MailMessageSummary) -> some View {
        HStack(spacing: 6) {
            Button {
                personal.markRead(message)
            } label: {
                RookeryIconView(.envelopeOpen)
                    .foregroundStyle(StageColors.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Mark as read")
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
