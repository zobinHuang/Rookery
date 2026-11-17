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

    @State private var shownAccount: String?
    @State private var hoveredId: Int?

    private var listShown: [MailMessageSummary] {
        guard let shownAccount else {
            return personal.listUnread
        }
        return personal.listUnread.filter { $0.account == shownAccount }
    }

    private var listAccounts: [String] {
        Array(Set(personal.listUnread.map(\.account))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                Text("\(personal.unreadTotal) in \(shownAccount ?? "every inbox")")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Every Account") {
                    shownAccount = nil
                }
                Divider()
                ForEach(listAccounts, id: \.self) { account in
                    Button(account) {
                        shownAccount = account
                    }
                }
            } label: {
                RookeryIconView(.filter)
                    .foregroundStyle(shownAccount == nil ? AnyShapeStyle(StageColors.secondaryText) : AnyShapeStyle(Color.accentColor))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show one account's mail")
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
