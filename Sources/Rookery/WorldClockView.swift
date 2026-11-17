import SwiftUI

/// The time in each chosen city on one line, as the footbar shows them: the city, a 24-hour seven-segment
/// clock whose colon blinks with the seconds, the weekday, and how many days it is ahead of or behind here
/// when that differs; a hairline between cities. The zone and the full date are in each city's tooltip.
struct WorldClockView: View {
    private static let digitHeight: CGFloat = 9
    private static let citySpacing: CGFloat = 12
    /// How the identifiers of zones that are fixed offsets from UTC start.
    private static let listFixedOffsetPrefixes = ["UTC", "GMT"]
    private static let fixedOffsetDetail = "Fixed offset"
    /// The weekdays as the display spells them, Sunday first as the calendar counts them.
    private static let listWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    let listCities: [WorldClockCity]

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                ForEach(Array(listCities.enumerated()), id: \.element.id) { index, city in
                    if let timeZone = TimeZone(identifier: city.timeZoneId) {
                        if index > 0 {
                            Rectangle()
                                .fill(StageColors.separator)
                                .frame(width: 1, height: 11)
                                .padding(.horizontal, Self.citySpacing)
                        }
                        item(for: city, in: timeZone, at: context.date)
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func item(for city: WorldClockCity, in timeZone: TimeZone, at date: Date) -> some View {
        let dayOffset = Self.dayOffset(of: timeZone, at: date)
        return HStack(alignment: .center, spacing: 6) {
            Text(city.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(StageColors.secondaryText)
            SevenSegmentDisplay(
                text: Self.clockText(for: timeZone, at: date),
                digitHeight: Self.digitHeight,
                color: StageColors.clockSegment,
                isBlinking: true
            )
            Text(Self.weekdayText(for: timeZone, at: date))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StageColors.tertiaryText)
            if dayOffset != 0 {
                Text(dayOffset > 0 ? "+\(dayOffset)d" : "−\(abs(dayOffset))d")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StageColors.tertiaryText)
            }
        }
        .help("\(city.name), \(Self.zoneName(of: timeZone, at: date)), \(Self.dateText(for: timeZone, at: date))")
    }

    /// The zone's abbreviation, or for a fixed offset from UTC that it is one.
    private static func zoneName(of timeZone: TimeZone, at date: Date) -> String {
        let isFixedOffset = listFixedOffsetPrefixes.contains { timeZone.identifier.hasPrefix($0) }
        return isFixedOffset ? fixedOffsetDetail : timeZone.abbreviation(for: date) ?? timeZone.identifier
    }

    /// How many days a time zone's date is ahead of the date here, behind when negative.
    private static func dayOffset(of timeZone: TimeZone, at date: Date) -> Int {
        var calendarHere = Calendar(identifier: .gregorian)
        calendarHere.timeZone = .current
        var calendarThere = Calendar(identifier: .gregorian)
        calendarThere.timeZone = timeZone
        let dayHere = calendarHere.dateComponents([.year, .month, .day], from: date)
        let dayThere = calendarThere.dateComponents([.year, .month, .day], from: date)
        guard
            let startHere = calendarHere.date(from: dayHere),
            let startThere = calendarHere.date(from: dayThere)
        else {
            return 0
        }
        return calendarHere.dateComponents([.day], from: startHere, to: startThere).day ?? 0
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

/// The bar along the stage's bottom, one line high under the sidebars and the content, set off by a
/// hairline: the world clock at its right end.
struct Footbar: View {
    let listCities: [WorldClockCity]

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if !listCities.isEmpty {
                WorldClockView(listCities: listCities)
                    .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StageColors.separator)
                .frame(height: 1)
        }
    }
}
