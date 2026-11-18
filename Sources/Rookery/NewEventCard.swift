import RookeryCore
import SwiftUI

/// A slot being dragged out on the hours: a soft block with a dashed edge and its time.
struct EventSlotBlock: View {
    let slot: EventSlot

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(StageColors.primaryText.opacity(0.1))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(StageColors.secondaryText, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .overlay(alignment: .topLeading) {
                Text(slot.timeText)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StageColors.primaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .allowsHitTesting(false)
    }
}

/// A new event for a slot dragged out on the hours, as a card beside them like an event's own: its title
/// typed at once, the calendar it goes on (the user's default first), its times to adjust, and where it
/// is; Return adds it, Escape lets it go.
struct NewEventCard: View {
    let slot: EventSlot
    let listCalendars: [CalendarSummary]
    var defaultCalendarId: String?
    /// Adds the event: its calendar, title, start, end and place.
    let onAdd: (String, String, Date, Date, String) async throws -> Void
    let onClose: () -> Void

    @State private var title = ""
    @State private var calendarId = ""
    @State private var start: Date
    @State private var end: Date
    @State private var location = ""
    @State private var isAdding = false
    @State private var problem: String?
    @FocusState private var isTitleFocused: Bool

    init(
        slot: EventSlot,
        listCalendars: [CalendarSummary],
        defaultCalendarId: String? = nil,
        onAdd: @escaping (String, String, Date, Date, String) async throws -> Void,
        onClose: @escaping () -> Void
    ) {
        self.slot = slot
        self.listCalendars = listCalendars
        self.defaultCalendarId = defaultCalendarId
        self.onAdd = onAdd
        self.onClose = onClose
        _start = State(initialValue: slot.start)
        _end = State(initialValue: slot.end)
    }

    private var calendar: CalendarSummary? {
        listCalendars.first { $0.id == calendarId }
    }

    private var isReady: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && calendar != nil && end > start && !isAdding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                row("Calendar") {
                    calendarMenu
                }
                row("Starts") {
                    DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                row("Ends") {
                    DatePicker("", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                row("Where") {
                    TextField("Place or meeting link", text: $location)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                if let problem {
                    RookeryLabel(problem, icon: .warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isAdding ? "Adding…" : "Add Event", action: add)
                    .buttonStyle(StageButtonStyle(kind: .prominent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady)
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
        .onAppear {
            isTitleFocused = true
        }
        .onChange(of: slot) {
            start = slot.start
            end = slot.end
        }
        .onChange(of: listCalendars.map(\.id), initial: true) {
            if calendar == nil {
                calendarId = listCalendars.first { $0.id == defaultCalendarId }?.id ?? listCalendars.first?.id ?? ""
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(AccountColor.calendar(calendar?.colorHex ?? ""))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                TextField("New Event", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .bold))
                    .focused($isTitleFocused)
                    .onSubmit(add)
                Text(EventSlot(start: start, end: end).timeText + ", " + start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
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
            .help("Close")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
    }

    private var calendarMenu: some View {
        Menu {
            ForEach(listCalendars, id: \.id) { choice in
                Button("\(choice.title), \(choice.accountTitle)") {
                    calendarId = choice.id
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AccountColor.calendar(calendar?.colorHex ?? ""))
                    .frame(width: 7, height: 7)
                Text(calendar?.title ?? (listCalendars.isEmpty ? "No calendar takes events" : "Choose a calendar"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let calendar {
                    Text(calendar.accountTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(StageColors.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(StageButtonStyle())
        .controlSize(.small)
        .fixedSize()
        .disabled(listCalendars.isEmpty)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
                .frame(width: 54, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func add() {
        guard isReady, let calendar else {
            return
        }
        isAdding = true
        problem = nil
        Task {
            do {
                try await onAdd(calendar.id, title.trimmingCharacters(in: .whitespaces), start, end, location.trimmingCharacters(in: .whitespaces))
                onClose()
            } catch {
                problem = String(describing: error)
            }
            isAdding = false
        }
    }
}
