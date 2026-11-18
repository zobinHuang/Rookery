import Foundation
import RookeryCore
import Testing

struct EventSlotTests {
    private let day = Date(timeIntervalSinceReferenceDate: 0)
    private let hourHeight: CGFloat = 40

    @Test func aDragTakesWholeQuarterHoursFromWhereItBeganToWhereItIs() {
        let slot = EventSlot.dragged(from: 105, to: 175, on: day, hourHeight: hourHeight)
        #expect(slot.start == day.addingTimeInterval(2.5 * 3600))
        #expect(slot.end == day.addingTimeInterval(4.5 * 3600))
    }

    @Test func aDragUpwardsTakesTheSameSlotAsOneDownwards() {
        #expect(EventSlot.dragged(from: 175, to: 105, on: day, hourHeight: hourHeight) == EventSlot.dragged(from: 105, to: 175, on: day, hourHeight: hourHeight))
    }

    @Test func aSlotIsAQuarterHourAtTheLeastAndStaysWithinTheDay() {
        let tiny = EventSlot.dragged(from: 80, to: 80, on: day, hourHeight: hourHeight)
        #expect(tiny.end.timeIntervalSince(tiny.start) == 15 * 60)
        let late = EventSlot.dragged(from: 959, to: 2000, on: day, hourHeight: hourHeight)
        #expect(late.end == day.addingTimeInterval(24 * 3600))
        #expect(late.start == day.addingTimeInterval(23.75 * 3600))
    }
}
