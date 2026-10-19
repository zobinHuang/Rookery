import SwiftUI

/// The time in each chosen city, city on the left and a 24-hour seven-segment clock on the right, updated
/// on the minute from the system clock.
struct WorldClockView: View {
    private static let digitHeight: CGFloat = 19

    let listTimeZoneIds: [String]

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 8) {
                ForEach(listTimeZoneIds, id: \.self) { timeZoneId in
                    if let timeZone = TimeZone(identifier: timeZoneId) {
                        row(for: timeZone, at: context.date)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(for timeZone: TimeZone, at date: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(WorldClock.cityName(forTimeZoneId: timeZone.identifier))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail(for: timeZone, at: date))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            SevenSegmentDisplay(text: Self.clockText(for: timeZone, at: date), digitHeight: Self.digitHeight)
        }
    }

    /// The zone's abbreviation, with how many days it is ahead of or behind here when that differs.
    private func detail(for timeZone: TimeZone, at date: Date) -> String {
        let abbreviation = timeZone.abbreviation(for: date) ?? timeZone.identifier
        var calendarHere = Calendar(identifier: .gregorian)
        calendarHere.timeZone = .current
        var calendarThere = Calendar(identifier: .gregorian)
        calendarThere.timeZone = timeZone
        let dayHere = calendarHere.dateComponents([.year, .month, .day], from: date)
        let dayThere = calendarThere.dateComponents([.year, .month, .day], from: date)
        guard
            let startHere = calendarHere.date(from: dayHere),
            let startThere = calendarHere.date(from: dayThere),
            let dayOffset = calendarHere.dateComponents([.day], from: startHere, to: startThere).day,
            dayOffset != 0
        else {
            return abbreviation
        }
        return "\(abbreviation) · \(dayOffset > 0 ? "+" : "−")\(abs(dayOffset))d"
    }

    private static func clockText(for timeZone: TimeZone, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
