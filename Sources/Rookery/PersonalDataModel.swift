import EventKit
import Foundation
import Observation
import os
import RookeryCore

/// The user's day and unread mail as the stage's right sidebar shows them, kept current: the calendars
/// when EventKit says they changed and every minute, the mail when Mail writes its library and every half
/// minute. Read from the Mac's own Mail and Calendar through `MailService`; nothing leaves the Mac.
@MainActor
@Observable
final class PersonalDataModel {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "mail")
    static let unreadLimit = 200
    private static let mailPollInterval: Duration = .seconds(5)
    private static let mailRefreshInterval: TimeInterval = 30
    private static let clockInterval: Duration = .seconds(60)

    /// The day the calendar shows, at its start.
    private(set) var day = Calendar.current.startOfDay(for: .now)
    private(set) var listDayEvents: [CalendarEventSummary] = []
    private(set) var listUnread: [MailMessageSummary] = []
    private(set) var unreadTotal = 0
    private(set) var access: MailAccess?
    /// The time the calendar's now line and countdown are drawn at, ticking every minute.
    private(set) var now = Date.now
    private(set) var calendarProblem: String?
    private(set) var mailProblem: String?

    @ObservationIgnored private let service: any MailSource
    @ObservationIgnored private var listTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var calendarObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var mailStamp: Date?
    @ObservationIgnored private var mailReadAt = Date.distantPast
    @ObservationIgnored private var viewerCount = 0

    init(service: any MailSource) {
        self.service = service
    }

    /// Start keeping the data current while some view shows it; each view that starts stops once.
    func begin() {
        viewerCount += 1
        guard viewerCount == 1 else {
            return
        }
        calendarObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCalendar()
            }
        }
        listTasks.append(Task { [weak self] in
            await self?.refreshAccess()
            await self?.readCalendar()
            await self?.readMail()
        })
        listTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.clockInterval)
                guard let self else {
                    return
                }
                now = .now
                if Calendar.current.isDateInToday(now) && !Calendar.current.isDate(day, inSameDayAs: now) && listDayEvents.isEmpty {
                    day = Calendar.current.startOfDay(for: now)
                }
                await readCalendar()
            }
        })
        listTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.mailPollInterval)
                guard let self else {
                    return
                }
                let stamp = await Task.detached { MailService.libraryStamp() }.value
                if stamp != mailStamp || Date.now.timeIntervalSince(mailReadAt) > Self.mailRefreshInterval {
                    mailStamp = stamp
                    await readMail()
                }
            }
        })
    }

    func end() {
        viewerCount = max(0, viewerCount - 1)
        guard viewerCount == 0 else {
            return
        }
        for task in listTasks {
            task.cancel()
        }
        listTasks.removeAll()
        if let calendarObserver {
            NotificationCenter.default.removeObserver(calendarObserver)
        }
        calendarObserver = nil
    }

    /// Show another day, by days from the one shown, or today with nil.
    func moveDay(by count: Int?) {
        if let count {
            day = Calendar.current.date(byAdding: .day, value: count, to: day) ?? day
        } else {
            day = Calendar.current.startOfDay(for: .now)
        }
        refreshCalendar()
    }

    /// The next event yet to start today, or under way.
    var nextEvent: CalendarEventSummary? {
        listDayEvents.filter { !$0.isAllDay && $0.endsAt > now }.min { $0.startsAt < $1.startsAt }
    }

    /// Mark a message read in Mail, showing it read at once.
    func markRead(_ message: MailMessageSummary) {
        listUnread.removeAll { $0.id == message.id }
        unreadTotal = max(0, unreadTotal - 1)
        Task {
            do {
                try await service.markRead(message, isRead: true)
            } catch {
                mailProblem = String(describing: error)
            }
            await readMail()
        }
    }

    func refreshCalendar() {
        Task { await readCalendar() }
    }

    func refreshAccess() async {
        let read = await service.access()
        AccountColor.know(read.listMailAccounts.compactMap(\.listAddresses.first))
        access = read
    }

    private func readCalendar() async {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        do {
            listDayEvents = try await service.events(from: day, to: end)
            calendarProblem = nil
        } catch {
            calendarProblem = String(describing: error)
        }
    }

    private func readMail() async {
        mailReadAt = .now
        do {
            listUnread = try await service.unreadInbox(limit: Self.unreadLimit)
            unreadTotal = try await service.unreadCount()
            mailProblem = nil
        } catch {
            mailProblem = String(describing: error)
            Self.logger.info("cannot read the unread mail: \(String(describing: error), privacy: .public)")
        }
    }
}
