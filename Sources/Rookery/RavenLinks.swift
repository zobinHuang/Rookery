import Foundation
import Observation
import RookeryCore
import SwiftUI

/// What Raven reaches on the Rookmaster board: the teams its conversations direct, held while they are in
/// them, and what it touched a moment ago (an agent it messaged or heard from, a skill, playbook or
/// memory it changed), each for a few seconds; drawn as lines swaying from Raven's tab to each.
@MainActor
@Observable
final class RavenLinks {
    /// How long a link to something Raven touched lasts, fading at its end.
    static let touchLifetime: TimeInterval = 9
    /// Where Raven's own end of the links is on the board's anchors.
    static let ravenRef = FleetRef(kind: "raven", id: "panel")

    private(set) var mapTouchedAt: [FleetRef: Date] = [:]

    /// Note that Raven touched a resource now.
    func note(_ ref: FleetRef, at date: Date = .now) {
        mapTouchedAt[ref] = date
        mapTouchedAt = mapTouchedAt.filter { date.timeIntervalSince($0.value) < Self.touchLifetime }
    }

    /// What Raven touched within the lifetime of a link, with when.
    func listTouched(now: Date) -> [FleetRef] {
        mapTouchedAt
            .filter { now.timeIntervalSince($0.value) < Self.touchLifetime }
            .map(\.key)
            .sorted { $0.id < $1.id }
    }

    /// Note what an event from roost says Raven did: a change, a message or a mention of a resource, by
    /// one of Raven's conversations.
    func take(_ event: FleetEvent, graph: ResourceGraph) {
        guard
            let object = event.object,
            let actor = graph.resource(event.actor),
            actor.isRookeryOwn,
            object.kind != AgentFleet.agentKind || object.id != event.actor.id
        else {
            return
        }
        note(object)
    }
}

/// Raven's links drawn over the board: from its tab, a line to each team a conversation directs, slow and
/// faint, and to what it touched a moment ago, bright, swaying like a rope shaken from the bottom, with a
/// light running up it, fading as it ages. It draws frame by frame only while there is a link to draw.
struct RavenLinksOverlay: View {
    private static let swayPeriod: Double = 2.6
    private static let touchedSway: CGFloat = 26
    private static let heldSway: CGFloat = 10
    private static let fadeInDuration: Double = 0.35
    private static let fadeOutDuration: Double = 2.5

    let links: RavenLinks
    let listHeldRefs: [FleetRef]
    let mapAnchors: [FleetRef: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            let isIdle = mapAnchors[RavenLinks.ravenRef] == nil
                || (listHeldRefs.isEmpty && links.mapTouchedAt.isEmpty)
            TimelineView(.animation(paused: isIdle)) { context in
                Canvas { canvas, _ in
                    draw(in: &canvas, proxy: proxy, now: context.date)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in canvas: inout GraphicsContext, proxy: GeometryProxy, now: Date) {
        guard let ravenAnchor = mapAnchors[RavenLinks.ravenRef] else {
            return
        }
        let ravenFrame = proxy[ravenAnchor]
        let start = CGPoint(x: ravenFrame.midX, y: ravenFrame.minY)
        let time = now.timeIntervalSinceReferenceDate
        let listTouched = links.listTouched(now: now)
        for ref in listHeldRefs where !listTouched.contains(ref) {
            guard let anchor = mapAnchors[ref] else {
                continue
            }
            drawLink(in: &canvas, from: start, to: proxy[anchor], ref: ref, time: time, strength: 0.35, sway: Self.heldSway, hasLight: false)
        }
        for ref in listTouched {
            guard let anchor = mapAnchors[ref], let touchedAt = links.mapTouchedAt[ref] else {
                continue
            }
            let age = now.timeIntervalSince(touchedAt)
            let fadeIn = min(1, age / Self.fadeInDuration)
            let fadeOut = min(1, max(0, (RavenLinks.touchLifetime - age) / Self.fadeOutDuration))
            let isHeld = listHeldRefs.contains(ref)
            let strength = max(isHeld ? 0.35 : 0, fadeIn * fadeOut)
            drawLink(in: &canvas, from: start, to: proxy[anchor], ref: ref, time: time, strength: strength, sway: Self.touchedSway * fadeOut + Self.heldSway, hasLight: true)
        }
    }

    /// One link: a curve from Raven's tab up to the bottom of what it reaches, its middle swaying side to
    /// side on a wave that runs up from Raven, a fainter echo beside it, and for a touch a light climbing it.
    private func drawLink(
        in canvas: inout GraphicsContext,
        from start: CGPoint,
        to target: CGRect,
        ref: FleetRef,
        time: Double,
        strength: Double,
        sway: CGFloat,
        hasLight: Bool
    ) {
        guard strength > 0.01 else {
            return
        }
        let end = CGPoint(x: target.midX, y: target.maxY)
        let phase = Double(abs(ref.id.hashValue % 1000)) / 1000 * .pi * 2
        let wave = time / Self.swayPeriod * .pi * 2 + phase
        let rise = start.y - end.y
        let path = Self.curve(from: start, to: end, rise: rise, sway: sway, wave: wave)
        let echo = Self.curve(from: start, to: end, rise: rise, sway: sway * 0.6, wave: wave - 0.9)
        canvas.stroke(echo, with: .style(StageColors.primaryText.opacity(0.18 * strength)), lineWidth: 1)
        canvas.stroke(path, with: .style(StageColors.primaryText.opacity(0.55 * strength)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        if hasLight {
            let dash = StrokeStyle(lineWidth: 2.6, lineCap: .round, dash: [3, 22], dashPhase: CGFloat(-time * 60))
            canvas.stroke(path, with: .style(StageColors.primaryText.opacity(0.85 * strength)), style: dash)
        }
        let pulse = 3 + 1.5 * sin(time * 4 + phase)
        let dot = Path(ellipseIn: CGRect(x: end.x - pulse, y: end.y - pulse, width: pulse * 2, height: pulse * 2))
        canvas.fill(dot, with: .style(StageColors.primaryText.opacity(0.7 * strength)))
        let base = Path(ellipseIn: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5))
        canvas.fill(base, with: .style(StageColors.primaryText.opacity(0.5 * strength)))
    }

    private static func curve(from start: CGPoint, to end: CGPoint, rise: CGFloat, sway: CGFloat, wave: Double) -> Path {
        var path = Path()
        path.move(to: start)
        let firstSway = sway * CGFloat(sin(wave))
        let secondSway = sway * CGFloat(sin(wave - 1.4))
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + firstSway, y: start.y - rise * 0.45),
            control2: CGPoint(x: end.x + secondSway, y: end.y + rise * 0.4)
        )
        return path
    }
}
