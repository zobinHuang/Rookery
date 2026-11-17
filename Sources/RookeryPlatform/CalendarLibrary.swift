import CoreGraphics
import EventKit
import Foundation
import RookeryCore

/// A failure to reach the calendars.
public enum CalendarLibraryError: Error, CustomStringConvertible {
    case notAllowed
    case failed(String)

    public var description: String {
        switch self {
        case .notAllowed: "Rookery may not read the calendars; allow it in System Settings, Privacy & Security, Calendars"
        case .failed(let reason): "the calendar store failed: \(reason)"
        }
    }
}

/// The Mac's calendars, every account's, through EventKit. One store for the app; access is asked for once.
public final class CalendarLibrary: @unchecked Sendable {
    // EKEventStore is thread-safe for reads and saves, as its documentation says.
    private let store = EKEventStore()

    public init() {}

    /// Whether the app may read and change the calendars, asking the user the first time.
    ///
    /// - Returns: true when full access is granted
    public func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// The authorization as a word: `full`, `write_only`, `denied`, `restricted` or `not_determined`.
    public static var authorization: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "full"
        case .writeOnly: "write_only"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    /// Every calendar of events.
    ///
    /// - Throws: `CalendarLibraryError.notAllowed` without full access
    public func calendars() throws -> [CalendarSummary] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarLibraryError.notAllowed
        }
        return store.calendars(for: .event).map { calendar in
            CalendarSummary(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                accountTitle: calendar.source?.title ?? "",
                accountKind: Self.kind(of: calendar.source?.sourceType),
                isWritable: calendar.allowsContentModifications,
                colorHex: Self.hex(of: calendar.cgColor)
            )
        }
    }

    /// The events between two moments, on the calendars given or on all.
    ///
    /// - Throws: `CalendarLibraryError.notAllowed` without full access
    public func events(from start: Date, to end: Date, calendarIds setCalendarIds: Set<String>? = nil) throws -> [CalendarEventSummary] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarLibraryError.notAllowed
        }
        let listCalendars = store.calendars(for: .event).filter { setCalendarIds?.contains($0.calendarIdentifier) ?? true }
        guard !listCalendars.isEmpty else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: listCalendars)
        return store.events(matching: predicate).map(Self.summary(of:))
    }

    /// Add an event to a calendar.
    ///
    /// - Returns: the event as saved
    /// - Throws: `CalendarLibraryError`
    public func addEvent(
        calendarId: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        location: String,
        notes: String
    ) throws -> CalendarEventSummary {
        guard let calendar = store.calendar(withIdentifier: calendarId), calendar.allowsContentModifications else {
            throw CalendarLibraryError.failed("no calendar \(calendarId) that takes events")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = startsAt
        event.endDate = endsAt
        event.isAllDay = isAllDay
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        try save(event)
        return Self.summary(of: event)
    }

    /// Change an event's time, title, place or notes; a field left nil stays as it is. A recurring event is
    /// changed in this occurrence only.
    ///
    /// - Throws: `CalendarLibraryError`
    public func changeEvent(
        _ eventId: String,
        title: String?,
        startsAt: Date?,
        endsAt: Date?,
        location: String?,
        notes: String?
    ) throws -> CalendarEventSummary {
        guard let event = store.event(withIdentifier: eventId) else {
            throw CalendarLibraryError.failed("no event \(eventId)")
        }
        if let title {
            event.title = title
        }
        if let startsAt {
            event.startDate = startsAt
        }
        if let endsAt {
            event.endDate = endsAt
        }
        if let location {
            event.location = location
        }
        if let notes {
            event.notes = notes
        }
        try save(event)
        return Self.summary(of: event)
    }

    /// Remove an event, this occurrence only for a recurring one.
    ///
    /// - Throws: `CalendarLibraryError`
    public func removeEvent(_ eventId: String) throws {
        guard let event = store.event(withIdentifier: eventId) else {
            throw CalendarLibraryError.failed("no event \(eventId)")
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarLibraryError.failed(error.localizedDescription)
        }
    }

    private func save(_ event: EKEvent) throws {
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarLibraryError.failed(error.localizedDescription)
        }
    }

    private static let notesLimit = 2000

    private static func summary(of event: EKEvent) -> CalendarEventSummary {
        CalendarEventSummary(
            id: event.eventIdentifier ?? "",
            globalId: event.calendarItemExternalIdentifier ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? "",
            calendar: event.calendar?.title ?? "",
            account: event.calendar?.source?.title ?? "",
            title: event.title ?? "",
            startsAt: event.startDate,
            endsAt: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            notes: String((event.notes ?? "").prefix(notesLimit)),
            url: event.url?.absoluteString ?? "",
            organizer: event.organizer.map { $0.name ?? address(of: $0) } ?? "",
            listAttendees: (event.attendees ?? []).map { participant in
                CalendarAttendee(
                    name: participant.name ?? "",
                    address: address(of: participant),
                    status: status(of: participant.participantStatus),
                    isMe: participant.isCurrentUser
                )
            },
            isRecurring: event.hasRecurrenceRules,
            colorHex: event.calendar.map { hex(of: $0.cgColor) } ?? ""
        )
    }

    private static func hex(of color: CGColor?) -> String {
        guard
            let color,
            let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
            let listComponents = converted.components,
            listComponents.count >= 3
        else {
            return ""
        }
        return String(format: "#%02x%02x%02x", Int(listComponents[0] * 255), Int(listComponents[1] * 255), Int(listComponents[2] * 255))
    }

    private static func address(of participant: EKParticipant) -> String {
        let url = participant.url.absoluteString
        return url.hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : url
    }

    private static func status(of participantStatus: EKParticipantStatus) -> String {
        switch participantStatus {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        default: "unknown"
        }
    }

    private static func kind(of sourceType: EKSourceType?) -> String {
        switch sourceType {
        case .calDAV: "caldav"
        case .exchange: "exchange"
        case .local: "local"
        case .subscribed: "subscribed"
        case .birthdays: "birthdays"
        case .mobileMe: "icloud"
        default: "unknown"
        }
    }
}
