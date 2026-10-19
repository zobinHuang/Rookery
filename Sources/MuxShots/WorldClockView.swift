import SwiftUI

/// The time in each chosen city, city on the left and a 24-hour seven-segment clock on the right, read
/// from the system clock every second so the colons blink with the seconds.
struct WorldClockView: View {
    private static let digitHeight: CGFloat = 19
    private static let colonFadeSeconds = 0.3

    let listCities: [WorldClockCity]

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: 1)) { context in
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
            SevenSegmentDisplay(
                text: Self.clockText(for: timeZone, at: date),
                digitHeight: Self.digitHeight,
                color: StageColors.clockSegment,
                colonOpacity: Self.isColonLit(at: date) ? 1 : 0
            )
            .animation(.easeInOut(duration: Self.colonFadeSeconds), value: Self.isColonLit(at: date))
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

    /// Whether the colons are lit: on even seconds, dark on odd ones.
    private static func isColonLit(at date: Date) -> Bool {
        Int(date.timeIntervalSince1970.rounded(.down)) % 2 == 0
    }

    private static func clockText(for timeZone: TimeZone, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}
