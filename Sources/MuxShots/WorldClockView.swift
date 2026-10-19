import SwiftUI

/// The time in each chosen city, city on the left and a 24-hour seven-segment clock on the right with the
/// date and, in plain text, the weekday under it, read from the system clock on the minute; the colons blink with the seconds.
struct WorldClockView: View {
    private static let digitHeight: CGFloat = 19
    /// The date and weekday under each time, smaller than it.
    private static let dateDigitHeight: CGFloat = 9
    private static let dateSpacing: CGFloat = 4
    private static let dateWeekdaySpacing: CGFloat = 5
    /// How the identifiers of zones that are fixed offsets from UTC start.
    private static let listFixedOffsetPrefixes = ["UTC", "GMT"]
    private static let fixedOffsetDetail = "Fixed offset"
    /// Room for the widest weekday, so every row's date lines up.
    private static let weekdayWidth: CGFloat = 24
    /// The weekdays as the display spells them, Sunday first as the calendar counts them.
    private static let listWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    let listCities: [WorldClockCity]

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 8) {
                ForEach(listCities) { city in
                    if let timeZone = TimeZone(identifier: city.timeZoneId) {
                        row(for: city, in: timeZone, at: context.date)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(for city: WorldClockCity, in timeZone: TimeZone, at date: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(city.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail(for: timeZone, at: date))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: Self.dateSpacing) {
                SevenSegmentDisplay(
                    text: Self.clockText(for: timeZone, at: date),
                    digitHeight: Self.digitHeight,
                    color: StageColors.clockSegment,
                    isBlinking: true
                )
                HStack(alignment: .center, spacing: Self.dateWeekdaySpacing) {
                    SevenSegmentDisplay(
                        text: Self.dateText(for: timeZone, at: date),
                        digitHeight: Self.dateDigitHeight,
                        color: StageColors.clockSegment
                    )
                    Text(Self.weekdayText(for: timeZone, at: date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: Self.weekdayWidth, alignment: .trailing)
                }
            }
        }
    }

    /// The zone's abbreviation, or for a fixed offset from UTC that it is one, with how many days it is
    /// ahead of or behind here when that differs.
    private func detail(for timeZone: TimeZone, at date: Date) -> String {
        let isFixedOffset = Self.listFixedOffsetPrefixes.contains { timeZone.identifier.hasPrefix($0) }
        let abbreviation = isFixedOffset ? Self.fixedOffsetDetail : timeZone.abbreviation(for: date) ?? timeZone.identifier
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

    /// The date in a time zone, as "2026-10-20".
    private static func dateText(for timeZone: TimeZone, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The weekday in a time zone, as "Tue".
    private static func weekdayText(for timeZone: TimeZone, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date)
        return listWeekdayNames.indices.contains(weekday - 1) ? listWeekdayNames[weekday - 1] : ""
    }

    private static func clockText(for timeZone: TimeZone, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
