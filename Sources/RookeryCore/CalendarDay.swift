import Foundation

/// The link that joins an event's video meeting, found in its link, place or notes.
public enum MeetingLink {
    /// The hosts of the meeting services whose links join a meeting.
    private static let listHosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "meeting.tencent.com",
        "voovmeeting.com", "vc.feishu.cn", "meetings.feishu.cn", "vc.larksuite.com", "webex.com", "whereby.com",
        "chime.aws", "bluejeans.com",
    ]

    /// The first link to a meeting service among some texts, in their order.
    public static func find(in listTexts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        for text in listTexts where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let host = url.host()?.lowercased() else {
                    continue
                }
                if listHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }

    /// An event's meeting link: its own link, then its place, then its notes.
    public static func of(_ event: CalendarEventSummary) -> URL? {
        find(in: [event.url, event.location, event.notes])
    }
}

/// Where an event sits in a day's column: which of the side-by-side lanes it takes, of how many, so events
/// at the same time stand beside one another rather than on top.
public struct CalendarPlacement: Equatable, Sendable {
    public let eventId: String
    public let lane: Int
    public let laneCount: Int

    public init(eventId: String, lane: Int, laneCount: Int) {
        self.eventId = eventId
        self.lane = lane
        self.laneCount = laneCount
    }

    /// The lanes of a day's timed events: each event takes the first lane free when it starts, and every
    /// event of a cluster that overlaps shares the cluster's lane count.
    public static func lanes(of listEvents: [CalendarEventSummary]) -> [CalendarPlacement] {
        let listSorted = listEvents.filter { !$0.isAllDay }.sorted { ($0.startsAt, $0.endsAt) < ($1.startsAt, $1.endsAt) }
        var listPlacements: [CalendarPlacement] = []
        var listCluster: [(event: CalendarEventSummary, lane: Int)] = []
        var listLaneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func closeCluster() {
            let laneCount = max(1, listLaneEnds.count)
            listPlacements += listCluster.map { CalendarPlacement(eventId: $0.event.id, lane: $0.lane, laneCount: laneCount) }
            listCluster = []
            listLaneEnds = []
        }
        for event in listSorted {
            if event.startsAt >= clusterEnd {
                closeCluster()
            }
            let lane = listLaneEnds.firstIndex { $0 <= event.startsAt } ?? listLaneEnds.count
            if lane == listLaneEnds.count {
                listLaneEnds.append(event.endsAt)
            } else {
                listLaneEnds[lane] = event.endsAt
            }
            listCluster.append((event, lane))
            clusterEnd = max(clusterEnd, event.endsAt)
        }
        closeCluster()
        return listPlacements
    }
}
