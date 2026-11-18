import AppKit
import RookeryCore
import SwiftUI

/// One event on the day's hours: a block in its calendar's color, with its title and time.
struct EventBlock: View {
    let event: CalendarEventSummary
    let isPast: Bool

    var body: some View {
        let color = AccountColor.calendar(event.colorHex)
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                Text(event.startsAt.formatted(date: .omitted, time: .shortened) + (event.location.isEmpty || event.location.contains("://") ? "" : "  \(event.location)"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(isPast ? 0.55 : 1)
        .contentShape(Rectangle())
        .help("\(event.title)\n\(event.calendar) (\(event.account))")
    }
}

/// One event in full, as a card in the stage's colors: its calendar's color down its side, its title and
/// time, where it is, who organized it and who comes and how they answered, its notes, and buttons to join
/// its meeting and open it in Calendar; with a button to close it.
struct EventDetailView: View {
    let event: CalendarEventSummary
    /// Removes the event, offered for one on a calendar that takes changes.
    var onRemove: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AccountColor.calendar(event.colorHex))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .bold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timeText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StageColors.secondaryText)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    RookeryIconView(.close)
                        .foregroundStyle(StageColors.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(StageColors.tile, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    fact(.folder, "\(event.calendar), \(event.account)" + (event.listAlsoOn.isEmpty ? "" : "; also on \(event.listAlsoOn.joined(separator: ", "))"))
                    if !event.location.isEmpty && !event.location.contains("://") {
                        fact(.pin, event.location)
                    }
                    if !event.organizer.isEmpty {
                        fact(.person, "Organized by \(event.organizer)")
                    }
                    if !event.listAttendees.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(event.listAttendees.count) invited")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(StageColors.tertiaryText)
                            ForEach(event.listAttendees, id: \.address) { attendee in
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(Self.statusColor(attendee.status))
                                        .frame(width: 6, height: 6)
                                    AddressLabel(address: MailAddress(address: attendee.address, name: attendee.name), markSize: 16)
                                        .font(.system(size: 11.5, weight: attendee.isMe ? .semibold : .regular))
                                    Spacer(minLength: 4)
                                    Text(Self.statusTitle(attendee.status))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(StageColors.tertiaryText)
                                }
                            }
                        }
                    }
                    if !event.notes.isEmpty {
                        Text(event.notes)
                            .font(.system(size: 11.5))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                if let link = MeetingLink.of(event) {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        RookeryLabel("Join", icon: .video, spacing: 5)
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                }
                if let onRemove {
                    Button("Remove…", role: .destructive, action: onRemove)
                }
                Spacer(minLength: 0)
                Button("Open in Calendar") {
                    let encoded = event.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.id
                    if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .controlSize(.small)
            .buttonStyle(StageButtonStyle())
            .padding(12)
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .background(StageColors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private static func statusTitle(_ status: String) -> String {
        switch status {
        case "accepted": "Going"
        case "declined": "Declined"
        case "tentative": "Maybe"
        case "pending": "Not answered"
        default: status.capitalized
        }
    }

    private var timeText: String {
        if event.isAllDay {
            return event.startsAt.formatted(.dateTime.weekday(.wide).month().day()) + ", all day"
        }
        let start = event.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
        return "\(start) to \(event.endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private func fact(_ icon: RookeryIcon, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RookeryIconView(icon)
                .foregroundStyle(StageColors.tertiaryText)
            Text(text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func statusColor(_ status: String) -> Color {
        switch status {
        case "accepted": .green
        case "declined": .red
        case "tentative": .orange
        default: .gray
        }
    }
}
