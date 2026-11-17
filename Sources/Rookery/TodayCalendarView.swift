import AppKit
import RookeryCore
import SwiftUI

/// The right sidebar's calendar: the day shown, its next event with the link to join it, its all-day
/// events, and its hours with every account's events laid side by side where they overlap, a line at now.
struct TodayCalendarView: View {
    static let hourHeight: CGFloat = 46
    private static let hourLabelWidth: CGFloat = 38
    private static let minimumEventHeight: CGFloat = 18

    let personal: PersonalDataModel
    let onOpenPage: () -> Void
    let onOpenSettings: () -> Void

    @State private var shownEvent: CalendarEventSummary?

    private var isToday: Bool {
        Calendar.current.isDateInToday(personal.day)
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if let access = personal.access, access.calendarAuthorization != "full" {
                SidebarNotice(
                    icon: .calendar,
                    title: "Calendars are closed to Rookery",
                    text: "Allow Rookery to read your calendars in Settings, under Mail and Calendars.",
                    actionTitle: "Open Settings",
                    action: onOpenSettings
                )
            } else {
                if isToday, let next = personal.nextEvent {
                    NextEventCard(event: next, now: personal.now)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .onTapGesture {
                            shownEvent = next
                        }
                }
                allDay
                timeline
            }
        }
        .popover(item: $shownEvent, arrowEdge: .leading) { event in
            EventDetailView(event: event)
                .frame(width: 320)
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(isToday ? "Today" : personal.day.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 15, weight: .bold))
                Text(isToday ? personal.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : personal.day.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 4)
            if !isToday {
                Button("Today") {
                    personal.moveDay(by: nil)
                }
                .controlSize(.small)
            }
            iconButton(.chevronLeft, help: "The day before") {
                personal.moveDay(by: -1)
            }
            iconButton(.chevronRight, help: "The day after") {
                personal.moveDay(by: 1)
            }
            iconButton(.expand, help: "Open the whole calendar", action: onOpenPage)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var allDay: some View {
        let listAllDay = personal.listDayEvents.filter(\.isAllDay)
        if !listAllDay.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(listAllDay, id: \.id) { event in
                    Button {
                        shownEvent = event
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AccountColor.calendar(event.colorHex))
                                .frame(width: 3, height: 14)
                            Text(event.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(AccountColor.calendar(event.colorHex).opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var timeline: some View {
        let listTimed = personal.listDayEvents.filter { !$0.isAllDay }
        let mapPlacements = Dictionary(uniqueKeysWithValues: CalendarPlacement.lanes(of: listTimed).map { ($0.eventId, $0) })
        return ScrollViewReader { reader in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    GeometryReader { proxy in
                        let laneArea = proxy.size.width - Self.hourLabelWidth - 6
                        ForEach(listTimed, id: \.id) { event in
                            let placement = mapPlacements[event.id] ?? CalendarPlacement(eventId: event.id, lane: 0, laneCount: 1)
                            let laneWidth = laneArea / CGFloat(placement.laneCount)
                            EventBlock(event: event, isPast: event.endsAt < personal.now)
                                .frame(width: max(laneWidth - 2, 10), height: height(of: event))
                                .offset(x: Self.hourLabelWidth + CGFloat(placement.lane) * laneWidth, y: offset(of: event.startsAt))
                                .onTapGesture {
                                    shownEvent = event
                                }
                        }
                        if isToday {
                            nowLine(width: proxy.size.width)
                        }
                    }
                }
                .frame(height: Self.hourHeight * 24)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
            }
            .onAppear {
                scrollToFocus(reader)
            }
            .onChange(of: personal.day) {
                scrollToFocus(reader)
            }
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(Self.hourTitle(hour))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(StageColors.tertiaryText)
                        .frame(width: Self.hourLabelWidth, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(StageColors.separator)
                        .frame(height: 1)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

    private func nowLine(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1.5)
        }
        .frame(width: max(width - Self.hourLabelWidth - 3, 0))
        .offset(x: Self.hourLabelWidth + 3, y: offset(of: personal.now) - 3.5)
        .allowsHitTesting(false)
    }

    private func offset(of date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(personal.day)
        return CGFloat(min(max(seconds, 0), 24 * 3600) / 3600) * Self.hourHeight
    }

    private func height(of event: CalendarEventSummary) -> CGFloat {
        max(offset(of: event.endsAt) - offset(of: event.startsAt) - 1, Self.minimumEventHeight)
    }

    /// Open at an hour before now, or before the day's first event on another day.
    private func scrollToFocus(_ reader: ScrollViewProxy) {
        let focus = isToday ? personal.now : (personal.listDayEvents.filter { !$0.isAllDay }.map(\.startsAt).min() ?? personal.day.addingTimeInterval(8 * 3600))
        let hour = max(0, Calendar.current.component(.hour, from: focus) - 1)
        reader.scrollTo(hour, anchor: .top)
    }

    private static func hourTitle(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    private func iconButton(_ icon: RookeryIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RookeryIconView(icon)
                .foregroundStyle(StageColors.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

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

/// The next event, or the one under way: how soon it starts or how long it runs, where, and a button to join
/// its video meeting when it has one.
struct NextEventCard: View {
    let event: CalendarEventSummary
    let now: Date

    var body: some View {
        let color = AccountColor.calendar(event.colorHex)
        let link = MeetingLink.of(event)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(when)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(event.startsAt <= now ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StageColors.secondaryText))
                Text(event.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                if !event.location.isEmpty && link?.absoluteString != event.location {
                    Text(event.location)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StageColors.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    RookeryLabel("Join", icon: .video, spacing: 4)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(link.absoluteString)
            }
        }
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
        .background(StageColors.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
        .contentShape(Rectangle())
    }

    private var when: String {
        if event.startsAt <= now {
            return "Now, until \(event.endsAt.formatted(date: .omitted, time: .shortened))"
        }
        let minutes = Int(event.startsAt.timeIntervalSince(now) / 60)
        if minutes < 60 {
            return "In \(max(minutes, 1)) min, \(event.startsAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Next at \(event.startsAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// An event in full: when, where, the link to join, who organized it and who is invited with their
/// answers, and its notes; with ways to open it in Calendar.
struct EventDetailView: View {
    let event: CalendarEventSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AccountColor.calendar(event.colorHex))
                        .frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 14, weight: .bold))
                            .textSelection(.enabled)
                        Text(timeText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(StageColors.secondaryText)
                    }
                }
                fact(.folder, "\(event.calendar), \(event.account)" + (event.listAlsoOn.isEmpty ? "" : "; also on \(event.listAlsoOn.joined(separator: ", "))"))
                if !event.location.isEmpty {
                    fact(.pin, event.location)
                }
                if let link = MeetingLink.of(event) {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        RookeryLabel("Join the Meeting", icon: .video, spacing: 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if !event.organizer.isEmpty {
                    fact(.person, "Organized by \(event.organizer)")
                }
                if !event.listAttendees.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(event.listAttendees, id: \.address) { attendee in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Self.statusColor(attendee.status))
                                    .frame(width: 6, height: 6)
                                Text(attendee.name.isEmpty ? attendee.address : attendee.name)
                                    .font(.system(size: 11.5, weight: attendee.isMe ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(attendee.status)
                                    .font(.system(size: 10))
                                    .foregroundStyle(StageColors.tertiaryText)
                            }
                        }
                    }
                }
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StageColors.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open in Calendar") {
                    let encoded = event.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.id
                    if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
        .frame(maxHeight: 460)
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
