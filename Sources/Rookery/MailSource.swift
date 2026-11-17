import Foundation
import RookeryCore

/// Where the stage's calendar and mail come from: the Mac's own Mail and Calendar through `MailService`,
/// or sample data when the views are rendered offscreen, which must not script Mail.
protocol MailSource: Actor {
    func access() async -> MailAccess
    func unreadInbox(limit: Int) async throws -> [MailMessageSummary]
    func unreadCount() async throws -> Int
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSummary]
    func allowedCalendars() async throws -> [CalendarSummary]
    /// The calendar new events go on when none is named, by its id; nil when the user chose none.
    func defaultCalendarId() async -> String?
    func search(_ query: MailQuery) async throws -> [MailMessageSummary]
    func inboxCounts() async throws -> [String: MailboxCount]
    func message(_ messageId: Int) async throws -> MailMessageDetail?
    func markRead(_ summary: MailMessageSummary, isRead: Bool) async throws
    func flag(_ summary: MailMessageSummary, isFlagged: Bool) async throws
    func reply(to summary: MailMessageSummary) async throws
    func openInMail(_ summary: MailMessageSummary) async throws
    func addEvent(
        calendarId: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        location: String
    ) async throws -> CalendarEventSummary
    func removeEvent(_ eventId: String) async throws
    /// Move an event the user dragged to a new start and end.
    func moveEvent(_ eventId: String, startsAt: Date, endsAt: Date) async throws
}
