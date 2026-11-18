import Foundation

/// The time a new event would take, as dragged out on a day's hours: whole quarter hours, a quarter hour
/// at the least, whichever way the drag went.
public struct EventSlot: Equatable, Sendable {
    private static let quarterHour: TimeInterval = 15 * 60
    private static let day: TimeInterval = 24 * 3600

    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// The slot between where a drag began and where it is now, on a day's hours.
    ///
    /// - Parameters:
    ///   - startY: where the drag began, down the day's hours
    ///   - currentY: where it is now
    ///   - day: the day's start
    ///   - hourHeight: how tall an hour is drawn
    public static func dragged(from startY: CGFloat, to currentY: CGFloat, on day: Date, hourHeight: CGFloat) -> EventSlot {
        let first = quarter(at: min(startY, currentY), hourHeight: hourHeight, isRoundingUp: false)
        let last = quarter(at: max(startY, currentY), hourHeight: hourHeight, isRoundingUp: true)
        let startOffset = min(first, Self.day - quarterHour)
        let endOffset = min(max(last, startOffset + quarterHour), Self.day)
        return EventSlot(start: day.addingTimeInterval(startOffset), end: day.addingTimeInterval(endOffset))
    }

    private static func quarter(at y: CGFloat, hourHeight: CGFloat, isRoundingUp: Bool) -> TimeInterval {
        let quarters = Double(max(0, y) / (hourHeight / 4))
        let rounded = isRoundingUp ? quarters.rounded(.up) : quarters.rounded(.down)
        return min(max(rounded * quarterHour, 0), Self.day)
    }

    /// The slot's time, as `10:00 – 11:30 AM`.
    public var timeText: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
