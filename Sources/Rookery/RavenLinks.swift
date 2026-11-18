import AppKit
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
    @ObservationIgnored private var pruneTask: Task<Void, Never>?

    /// Note that Raven touched a resource now; the link goes once its lifetime is over.
    func note(_ ref: FleetRef, at date: Date = .now) {
        mapTouchedAt[ref] = date
        prune(now: date)
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.touchLifetime))
            guard !Task.isCancelled else {
                return
            }
            self?.prune(now: .now)
        }
    }

    private func prune(now: Date) {
        let mapLive = mapTouchedAt.filter { now.timeIntervalSince($0.value) < Self.touchLifetime }
        if mapLive.count != mapTouchedAt.count {
            mapTouchedAt = mapLive
        }
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
/// light running up it, fading as it ages. SwiftUI only finds where each line runs, when the cards move;
/// Core Animation sways and fades them, so a link costs the app nothing frame by frame.
struct RavenLinksOverlay: View {
    let links: RavenLinks
    let listHeldRefs: [FleetRef]
    let mapAnchors: [FleetRef: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            RavenLinksLayer(listLinks: listLinks(proxy: proxy))
        }
        .allowsHitTesting(false)
    }

    private func listLinks(proxy: GeometryProxy) -> [RavenLink] {
        guard let ravenAnchor = mapAnchors[RavenLinks.ravenRef] else {
            return []
        }
        let ravenFrame = proxy[ravenAnchor]
        let start = CGPoint(x: ravenFrame.midX, y: ravenFrame.minY)
        var listLinks: [RavenLink] = []
        for ref in Set(listHeldRefs).union(links.listTouched(now: .now)) {
            guard let anchor = mapAnchors[ref] else {
                continue
            }
            let target = proxy[anchor]
            listLinks.append(RavenLink(
                ref: ref,
                start: start,
                end: CGPoint(x: target.midX, y: target.maxY),
                isHeld: listHeldRefs.contains(ref),
                touchedAt: links.mapTouchedAt[ref]
            ))
        }
        return listLinks.sorted { $0.ref.id < $1.ref.id }
    }
}

/// One line from Raven's tab: what it reaches, between which points, whether it is held while a
/// conversation directs a team, and when Raven last touched what it reaches.
struct RavenLink: Equatable {
    let ref: FleetRef
    let start: CGPoint
    let end: CGPoint
    let isHeld: Bool
    let touchedAt: Date?
}

/// The links as Core Animation layers.
struct RavenLinksLayer: NSViewRepresentable {
    let listLinks: [RavenLink]

    func makeNSView(context: Context) -> RavenLinksView {
        RavenLinksView()
    }

    func updateNSView(_ view: RavenLinksView, context: Context) {
        view.show(listLinks)
    }
}

/// The layers of Raven's links: for each, a faint echo, the line, a light climbing it and a dot pulsing at
/// its end, swaying and fading by Core Animation alone.
final class RavenLinksView: NSView {
    private static let swayPeriod: CFTimeInterval = 2.6
    private static let swayFrames = 12
    private static let touchedSway: CGFloat = 26
    private static let heldSway: CGFloat = 10
    private static let fadeInDuration: CFTimeInterval = 0.35
    private static let fadeOutDuration: CFTimeInterval = 2.5
    private static let heldStrength: Float = 0.35
    private static let lightSpeed: CGFloat = 60
    private static let dashPattern: [NSNumber] = [3, 22]
    /// When every link's sway is measured from, so a line redrawn as cards move keeps swaying in step.
    private static let epoch = CACurrentMediaTime()

    private var mapGroups: [FleetRef: CALayer] = [:]
    private var listShown: [RavenLink] = []

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let listLinks = listShown
        listShown = []
        show(listLinks)
    }

    /// Draw these links, keeping each one's sway in step and dropping those gone.
    func show(_ listLinks: [RavenLink]) {
        guard listLinks != listShown else {
            return
        }
        listShown = listLinks
        let setShown = Set(listLinks.map(\.ref))
        for (ref, group) in mapGroups where !setShown.contains(ref) {
            group.removeFromSuperlayer()
            mapGroups[ref] = nil
        }
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
        }
        for link in listLinks {
            mapGroups[link.ref]?.removeFromSuperlayer()
            let group = makeGroup(link, ink: ink)
            layer?.addSublayer(group)
            mapGroups[link.ref] = group
        }
    }

    private func makeGroup(_ link: RavenLink, ink: CGColor) -> CALayer {
        let group = CALayer()
        group.frame = bounds
        let now = CACurrentMediaTime()
        let swayTime = (now - Self.epoch).truncatingRemainder(dividingBy: Self.swayPeriod)
        let phase = Double(abs(link.ref.id.hashValue % 1000)) / 1000 * .pi * 2
        let age = link.touchedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let isTouched = age < RavenLinks.touchLifetime
        let sway = isTouched ? Self.touchedSway + Self.heldSway : Self.heldSway
        let echo = Self.shape(ink: ink, opacity: 0.18, width: 1)
        let line = Self.shape(ink: ink, opacity: 0.55, width: 1.6)
        echo.add(swayAnimation(link, sway: sway * 0.6, phase: phase - 0.9, swayTime: swayTime), forKey: "sway")
        line.add(swayAnimation(link, sway: sway, phase: phase, swayTime: swayTime), forKey: "sway")
        group.addSublayer(echo)
        group.addSublayer(line)
        if isTouched {
            let light = Self.shape(ink: ink, opacity: 0.85, width: 2.6)
            light.lineDashPattern = Self.dashPattern
            light.add(swayAnimation(link, sway: sway, phase: phase, swayTime: swayTime), forKey: "sway")
            let climb = CABasicAnimation(keyPath: "lineDashPhase")
            climb.fromValue = 0
            climb.toValue = -Self.dashPattern.reduce(0) { $0 + CGFloat($1.doubleValue) }
            climb.duration = Double(Self.dashPattern.reduce(0) { $0 + $1.doubleValue }) / Double(Self.lightSpeed)
            climb.repeatCount = .infinity
            light.add(climb, forKey: "climb")
            group.addSublayer(light)
        }
        group.addSublayer(Self.dot(at: link.start, radius: 2.5, ink: ink, opacity: 0.5))
        let endDot = Self.dot(at: link.end, radius: 3, ink: ink, opacity: 0.7)
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.5
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        endDot.add(pulse, forKey: "pulse")
        group.addSublayer(endDot)
        group.opacity = link.isHeld && !isTouched ? Self.heldStrength : 1
        if isTouched {
            group.add(fadeAnimation(age: age, isHeld: link.isHeld), forKey: "fade")
        }
        return group
    }

    /// The line's sway: its path at frames around a loop, the middle swinging side to side on a wave
    /// running up from Raven, continued from where every link's loop stands now.
    private func swayAnimation(_ link: RavenLink, sway: CGFloat, phase: Double, swayTime: CFTimeInterval) -> CAKeyframeAnimation {
        let rise = link.start.y - link.end.y
        let listPaths = (0...Self.swayFrames).map { frame -> CGPath in
            let wave = Double(frame) / Double(Self.swayFrames) * .pi * 2 + phase
            let path = CGMutablePath()
            path.move(to: link.start)
            path.addCurve(
                to: link.end,
                control1: CGPoint(x: link.start.x + sway * CGFloat(sin(wave)), y: link.start.y - rise * 0.45),
                control2: CGPoint(x: link.end.x + sway * CGFloat(sin(wave - 1.4)), y: link.end.y + rise * 0.4)
            )
            return path
        }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = listPaths
        animation.duration = Self.swayPeriod
        animation.repeatCount = .infinity
        animation.timeOffset = swayTime
        animation.calculationMode = .linear
        return animation
    }

    /// A touch's fade: in at once, held, out over its last seconds, to the held link's strength when the
    /// conversation still directs what it reaches, else to nothing.
    private func fadeAnimation(age: TimeInterval, isHeld: Bool) -> CAKeyframeAnimation {
        let lifetime = RavenLinks.touchLifetime
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let rest: Float = isHeld ? Self.heldStrength : 0
        animation.values = [0, 1, 1, rest]
        animation.keyTimes = [
            0,
            NSNumber(value: Self.fadeInDuration / lifetime),
            NSNumber(value: (lifetime - Self.fadeOutDuration) / lifetime),
            1,
        ]
        animation.duration = lifetime
        animation.timeOffset = min(age, lifetime)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func shape(ink: CGColor, opacity: Float, width: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.strokeColor = ink
        shape.fillColor = nil
        shape.lineWidth = width
        shape.lineCap = .round
        shape.opacity = opacity
        return shape
    }

    private static func dot(at point: CGPoint, radius: CGFloat, ink: CGColor, opacity: Float) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        dot.fillColor = ink
        dot.opacity = opacity
        return dot
    }
}
