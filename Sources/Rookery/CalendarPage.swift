import RookeryCore
import SwiftUI

/// How the calendar page lays out time.
enum CalendarSpan: String, CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// Every account's calendars in the content area: a day, a week or a month, each calendar shown or hidden,
/// an event's details a click away, and events the user adds or removes themselves, on the calendars Raven
/// and the stage may use.
struct CalendarPage: View {
    private static let hourHeight: CGFloat = 50
    private static let hourLabelWidth: CGFloat = 46
    private static let monthEventLimit = 3

    let fleetModel: FleetModel
    let onClose: () -> Void

    @State private var span = CalendarSpan.week
    @State private var anchor = Calendar.current.startOfDay(for: .now)
    @State private var listEvents: [CalendarEventSummary] = []
    @State private var listCalendars: [CalendarSummary] = []
    @State private var setHiddenCalendarIds: Set<String> = []
    @State private var shownEvent: CalendarEventSummary?
    @State private var isAdding = false
    @State private var eventToRemove: CalendarEventSummary?
    @State private var problem: String?
    /// The calendar a new event starts on, as the user set in the settings.
    @State private var defaultCalendarId: String?
    /// Whether the events of the span shown have been read once.
    @State private var hasLoaded = false
    /// The event being dragged to a new time, and how far it has moved.
    @State private var draggedEventId: String?
    @State private var dragTranslation = CGSize.zero

    private var service: any MailSource {
        fleetModel.mailSource
    }

    private var listShown: [CalendarEventSummary] {
        listEvents.filter { !setHiddenCalendarIds.contains($0.calendarId) }
    }

    /// The days the span shows, each at its start.
    private var listDays: [Date] {
        let calendar = Calendar.current
        switch span {
        case .day:
            return [anchor]
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            let monthStart = calendar.dateInterval(of: .month, for: anchor)?.start ?? anchor
            let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
            return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            HStack(spacing: 0) {
                if !fleetModel.pageColumns.isHidden(.calendarList) {
                    calendarList
                        .frame(width: fleetModel.pageColumns.width(of: .calendarList))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ColumnDivider(columns: fleetModel.pageColumns, column: .calendarList)
                }
                Group {
                    switch span {
                    case .day, .week:
                        hoursView
                    case .month:
                        monthView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(hasLoaded ? 1 : 0)
                .overlay {
                    if !hasLoaded {
                        PageLoading(title: "Reading your calendars")
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: hasLoaded)
            }
        }
        .foregroundStyle(StageColors.primaryText, StageColors.secondaryText, StageColors.tertiaryText)
        .task(id: "\(span.rawValue)\(anchor.timeIntervalSince1970)") {
            await load()
        }
        .onChange(of: fleetModel.personal.listDayEvents) {
            Task { await load() }
        }
        .overlay {
            if isAdding {
                NewEventForm(listCalendars: listCalendars.filter(\.isWritable), defaultCalendarId: defaultCalendarId, day: anchor) { calendarId, title, start, end, isAllDay, location in
                    add(calendarId: calendarId, title: title, start: start, end: end, isAllDay: isAllDay, location: location)
                } onCancel: {
                    isAdding = false
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isAdding)
        .confirmationDialog("Remove \(eventToRemove?.title ?? "")?", isPresented: Binding(get: { eventToRemove != nil }, set: { if !$0 { eventToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let eventToRemove {
                    remove(eventToRemove)
                }
            }
        } message: {
            Text(eventToRemove?.isRecurring == true ? "Only this occurrence is removed, from its calendar and for everyone it was shared with." : "It is removed from its calendar, and for everyone it was shared with.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ColumnToggle(columns: fleetModel.pageColumns, column: .calendarList, title: "Calendars")
            RookeryIconView(.calendar, scale: 1.6)
            Text(title)
                .font(.system(size: 18, weight: .bold))
            Spacer(minLength: 8)
            if let problem {
                RookeryLabel(problem, icon: .warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button("Today") {
                anchor = Calendar.current.startOfDay(for: .now)
            }
            HStack(spacing: 0) {
                stepButton(.chevronLeft, by: -1)
                stepButton(.chevronRight, by: 1)
            }
            .buttonStyle(.borderless)
            StageSegmentedControl(selection: $span, listOptions: CalendarSpan.allCases, title: \.title)
            Button {
                isAdding = true
            } label: {
                RookeryLabel("New Event", icon: .plus, spacing: 4)
            }
            .disabled(listCalendars.allSatisfy { !$0.isWritable })
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

    private var title: String {
        switch span {
        case .day:
            return anchor.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week:
            guard let first = listDays.first, let last = listDays.last else {
                return ""
            }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    private func stepButton(_ icon: RookeryIcon, by count: Int) -> some View {
        Button {
            let component: Calendar.Component = span == .day ? .day : span == .week ? .weekOfYear : .month
            anchor = Calendar.current.date(byAdding: component, value: count, to: anchor) ?? anchor
        } label: {
            RookeryIconView(icon)
                .frame(width: 24, height: 22)
        }
    }

    // MARK: - Calendars

    private var calendarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Set(listCalendars.map(\.accountTitle))).sorted(), id: \.self) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StageColors.secondaryText)
                            .lineLimit(1)
                        ForEach(listCalendars.filter { $0.accountTitle == account }, id: \.id) { calendar in
                            Toggle(isOn: Binding(
                                get: { !setHiddenCalendarIds.contains(calendar.id) },
                                set: { isShown in
                                    if isShown {
                                        setHiddenCalendarIds.remove(calendar.id)
                                    } else {
                                        setHiddenCalendarIds.insert(calendar.id)
                                    }
                                }
                            )) {
                                Text(calendar.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .toggleStyle(CalendarCheckStyle(color: AccountColor.calendar(calendar.colorHex)))
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Day and week

    private var hoursView: some View {
        let listDays = listDays
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear
                    .frame(width: Self.hourLabelWidth, height: 1)
                ForEach(listDays, id: \.self) { day in
                    VStack(spacing: 4) {
                        dayTitle(day)
                        let listAllDay = listShown.filter { $0.isAllDay && Self.event($0, isOn: day) }
                        VStack(spacing: 2) {
                            ForEach(listAllDay, id: \.id) { event in
                                chip(event)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            ScrollViewReader { reader in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(Self.hourTitle(hour))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(StageColors.tertiaryText)
                                    .frame(width: Self.hourLabelWidth - 6, height: Self.hourHeight, alignment: .topTrailing)
                                    .offset(y: -6)
                                    .id(hour)
                            }
                        }
                        .padding(.trailing, 6)
                        ForEach(listDays, id: \.self) { day in
                            dayColumn(day)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .onAppear {
                    reader.scrollTo(max(0, Calendar.current.component(.hour, from: .now) - 1), anchor: .top)
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isToday ? AnyShapeStyle(Color.white) : AnyShapeStyle(StageColors.primaryText))
                .frame(minWidth: 24, minHeight: 24)
                .background(isToday ? AnyShapeStyle(Color.red) : AnyShapeStyle(StageColor.clear), in: Circle())
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let listTimed = listShown.filter { !$0.isAllDay && $0.endsAt > day && $0.startsAt < end }
        let mapPlacements = Dictionary(uniqueKeysWithValues: CalendarPlacement.lanes(of: listTimed).map { ($0.eventId, $0) })
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle()
                            .fill(StageColors.gridLine)
                            .frame(height: 1)
                            .frame(maxHeight: Self.hourHeight, alignment: .top)
                    }
                }
                ForEach(listTimed, id: \.id) { event in
                    let placement = mapPlacements[event.id] ?? CalendarPlacement(eventId: event.id, lane: 0, laneCount: 1)
                    let laneWidth = (proxy.size.width - 4) / CGFloat(placement.laneCount)
                    let top = Self.offset(of: max(event.startsAt, day), in: day)
                    let bottom = Self.offset(of: min(event.endsAt, end), in: day)
                    let isDragged = draggedEventId == event.id
                    EventBlock(event: event, isPast: event.endsAt < .now)
                        .frame(width: max(laneWidth - 2, 8), height: max(bottom - top - 1, 18))
                        .overlay(alignment: .topLeading) {
                            if isDragged {
                                Text(movedStart(of: event, columnWidth: proxy.size.width).formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule())
                                    .offset(y: -16)
                            }
                        }
                        .shadow(color: isDragged ? .black.opacity(0.25) : .clear, radius: 6, y: 3)
                        .zIndex(isDragged ? 1 : 0)
                        .offset(x: 2 + CGFloat(placement.lane) * laneWidth, y: top)
                        .offset(isDragged ? dragTranslation : .zero)
                        .onTapGesture {
                            shownEvent = event
                        }
                        .gesture(moveGesture(event, columnWidth: proxy.size.width))
                        .popover(item: Binding(get: { shownEvent?.id == event.id ? shownEvent : nil }, set: { shownEvent = $0 }), arrowEdge: .trailing) { shown in
                            eventPopover(shown)
                        }
                }
                if Calendar.current.isDateInToday(day) {
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 1.5)
                        .offset(y: Self.offset(of: .now, in: day))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.hourHeight * 24)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StageColors.gridLine)
                .frame(width: 1)
        }
    }

    /// Dragging an event on the hours, on a calendar that takes changes: up and down by quarter hours, and
    /// in the week across days; it lands when let go.
    private func moveGesture(_ event: CalendarEventSummary, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isMovable(event) else {
                    return
                }
                draggedEventId = event.id
                dragTranslation = CGSize(
                    width: span == .week ? CGFloat(dayShift(value.translation.width, columnWidth: columnWidth)) * columnWidth : 0,
                    height: CGFloat(quarterHours(value.translation.height)) * Self.hourHeight / 4
                )
            }
            .onEnded { value in
                guard isMovable(event) else {
                    return
                }
                let shift = TimeInterval(quarterHours(value.translation.height) * 15 * 60)
                    + TimeInterval(span == .week ? dayShift(value.translation.width, columnWidth: columnWidth) : 0) * 24 * 3600
                draggedEventId = nil
                dragTranslation = .zero
                guard shift != 0 else {
                    return
                }
                move(event, by: shift)
            }
    }

    private func isMovable(_ event: CalendarEventSummary) -> Bool {
        listCalendars.first { $0.id == event.calendarId }?.isWritable == true
    }

    private func quarterHours(_ height: CGFloat) -> Int {
        Int((height / (Self.hourHeight / 4)).rounded())
    }

    private func dayShift(_ width: CGFloat, columnWidth: CGFloat) -> Int {
        columnWidth > 0 ? Int((width / columnWidth).rounded()) : 0
    }

    /// Where a dragged event would start if let go now.
    private func movedStart(of event: CalendarEventSummary, columnWidth: CGFloat) -> Date {
        let shift = TimeInterval(quarterHours(dragTranslation.height) * 15 * 60)
            + TimeInterval(dayShift(dragTranslation.width, columnWidth: columnWidth)) * 24 * 3600
        return event.startsAt.addingTimeInterval(shift)
    }

    private func move(_ event: CalendarEventSummary, by shift: TimeInterval) {
        if let index = listEvents.firstIndex(where: { $0.id == event.id }) {
            let moved = listEvents[index]
            listEvents[index] = CalendarEventSummary(
                id: moved.id,
                globalId: moved.globalId,
                calendarId: moved.calendarId,
                calendar: moved.calendar,
                account: moved.account,
                title: moved.title,
                startsAt: moved.startsAt.addingTimeInterval(shift),
                endsAt: moved.endsAt.addingTimeInterval(shift),
                isAllDay: moved.isAllDay,
                location: moved.location,
                notes: moved.notes,
                url: moved.url,
                organizer: moved.organizer,
                listAttendees: moved.listAttendees,
                isRecurring: moved.isRecurring,
                listAlsoOn: moved.listAlsoOn,
                colorHex: moved.colorHex
            )
        }
        Task {
            do {
                try await service.moveEvent(event.id, startsAt: event.startsAt.addingTimeInterval(shift), endsAt: event.endsAt.addingTimeInterval(shift))
                problem = nil
            } catch {
                problem = String(describing: error)
            }
            await load()
        }
    }

    // MARK: - Month

    private var monthView: some View {
        let listDays = listDays
        let month = Calendar.current.component(.month, from: anchor)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(listDays.prefix(7), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StageColors.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(listDays, id: \.self) { day in
                    monthCell(day, isInMonth: Calendar.current.component(.month, from: day) == month)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func monthCell(_ day: Date, isInMonth: Bool) -> some View {
        let listDay = listShown.filter { Self.event($0, isOn: day) }.sorted { ($0.isAllDay ? 0 : 1, $0.startsAt) < ($1.isAllDay ? 0 : 1, $1.startsAt) }
        let isToday = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 11.5, weight: isToday ? .bold : .medium))
                .foregroundStyle(isToday ? AnyShapeStyle(Color.white) : AnyShapeStyle((isInMonth ? StageColors.primaryText : StageColors.tertiaryText)))
                .frame(minWidth: 20, minHeight: 20)
                .background(isToday ? AnyShapeStyle(Color.red) : AnyShapeStyle(StageColor.clear), in: Circle())
            ForEach(listDay.prefix(Self.monthEventLimit), id: \.id) { event in
                chip(event)
            }
            if listDay.count > Self.monthEventLimit {
                Button("\(listDay.count - Self.monthEventLimit) more") {
                    anchor = day
                    span = .day
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(isInMonth ? StageColor.clear : StageColors.groove.opacity(0.4))
        .overlay {
            Rectangle()
                .strokeBorder(StageColors.gridLine, lineWidth: 0.5)
        }
    }

    private func chip(_ event: CalendarEventSummary) -> some View {
        let color = AccountColor.calendar(event.colorHex)
        return Button {
            shownEvent = event
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(event.isAllDay ? event.title : "\(event.startsAt.formatted(date: .omitted, time: .shortened)) \(event.title)")
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(event.isAllDay ? AnyShapeStyle(color.opacity(0.16)) : AnyShapeStyle(StageColor.clear), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(item: Binding(get: { shownEvent?.id == event.id ? shownEvent : nil }, set: { shownEvent = $0 }), arrowEdge: .trailing) { shown in
            eventPopover(shown)
        }
    }

    private func eventPopover(_ event: CalendarEventSummary) -> some View {
        VStack(spacing: 0) {
            EventDetailView(event: event)
            if listCalendars.first(where: { $0.id == event.calendarId })?.isWritable == true {
                Button("Remove Event…", role: .destructive) {
                    shownEvent = nil
                    eventToRemove = event
                }
                .controlSize(.small)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 320)
    }

    // MARK: - Work

    private func load() async {
        guard let first = listDays.first, let last = listDays.last, let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            return
        }
        do {
            listCalendars = try await service.allowedCalendars()
            defaultCalendarId = await service.defaultCalendarId()
            listEvents = try await service.events(from: first, to: end)
            problem = nil
        } catch {
            problem = String(describing: error)
        }
        hasLoaded = true
    }

    private func add(calendarId: String, title: String, start: Date, end: Date, isAllDay: Bool, location: String) {
        Task {
            do {
                _ = try await service.addEvent(calendarId: calendarId, title: title, startsAt: start, endsAt: end, isAllDay: isAllDay, location: location)
                isAdding = false
                await load()
            } catch {
                problem = String(describing: error)
            }
        }
    }

    private func remove(_ event: CalendarEventSummary) {
        Task {
            do {
                try await service.removeEvent(event.id)
                await load()
            } catch {
                problem = String(describing: error)
            }
        }
    }

    private static func event(_ event: CalendarEventSummary, isOn day: Date) -> Bool {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return event.startsAt < end && event.endsAt > day
    }

    private static func offset(of date: Date, in day: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(day), 0), 24 * 3600) / 3600) * hourHeight
    }

    private static func hourTitle(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

/// A calendar's check box, filled in its color when shown.
struct CalendarCheckStyle: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(color) : AnyShapeStyle(StageColor.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(color, lineWidth: 1.5)
                    }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The form that adds an event the user makes: its title, calendar, time or day, and place. It floats over
/// the calendar page.
struct NewEventForm: View {
    let listCalendars: [CalendarSummary]
    /// The calendar chosen when the form opens: the user's default, if it takes events.
    var defaultCalendarId: String?
    let day: Date
    let onAdd: (String, String, Date, Date, Bool, String) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var calendarId = ""
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var isAllDay = false
    @State private var location = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 12) {
                Text("New Event")
                    .font(.system(size: 16, weight: .bold))
                EditorField(text: $title, placeholder: "Title")
                Picker("Calendar", selection: $calendarId) {
                    ForEach(listCalendars, id: \.id) { calendar in
                        Text("\(calendar.title), \(calendar.accountTitle)").tag(calendar.id)
                    }
                }
                Toggle("All day", isOn: $isAllDay)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                DatePicker("Starts", selection: $start, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                EditorField(text: $location, placeholder: "Place or meeting link")
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Add") {
                        let finish = isAllDay ? (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end) : end
                        let begin = isAllDay ? Calendar.current.startOfDay(for: start) : start
                        onAdd(calendarId, title.trimmingCharacters(in: .whitespaces), begin, finish, isAllDay, location.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || calendarId.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(StageColors.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StageColors.separator)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onAppear {
            calendarId = listCalendars.first { $0.id == defaultCalendarId }?.id ?? listCalendars.first?.id ?? ""
            let hour = Calendar.current.component(.hour, from: .now) + 1
            start = Calendar.current.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: day) ?? day
            end = start.addingTimeInterval(3600)
        }
    }
}
