import AppKit
import Foundation
import Observation
import RookeryCore
import SwiftUI

/// What Raven reaches on the Rookmaster board, for the conversation open in its panel: the teams it
/// directs, held while it is in them, and what it touched a moment ago (an agent it messaged or heard
/// from, a skill, playbook or memory it changed), each for a few seconds; drawn as lines swaying from
/// Raven's tab to each. What each conversation touched is kept apart, so switching conversations switches
/// the lines.
@MainActor
@Observable
final class RavenLinks {
    /// How long a link to something Raven touched lasts, fading at its end.
    static let touchLifetime: TimeInterval = 9
    /// Where Raven's own end of the links is on the board's anchors.
    static let ravenRef = FleetRef(kind: "raven", id: "panel")

    /// When each conversation touched each resource, and which way, by conversation.
    private(set) var mapTouches: [String: [FleetRef: RavenTouch]] = [:]
    @ObservationIgnored private var pruneTask: Task<Void, Never>?

    /// Note that a conversation touched a resource now, or heard from it; the link goes once its lifetime
    /// is over.
    ///
    /// - Parameters:
    ///   - ref: what was touched
    ///   - conversationId: the conversation that touched it
    ///   - isFromResource: whether the resource reached Raven, as a teammate's message does, rather than
    ///     Raven it
    ///   - date: when
    func note(_ ref: FleetRef, by conversationId: String, isFromResource: Bool = false, at date: Date = .now) {
        mapTouches[conversationId, default: [:]][ref] = RavenTouch(at: date, isFromResource: isFromResource)
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
        let mapLive = mapTouches
            .mapValues { $0.filter { now.timeIntervalSince($0.value.at) < Self.touchLifetime } }
            .filter { !$0.value.isEmpty }
        if mapLive != mapTouches {
            mapTouches = mapLive
        }
    }

    /// When a conversation last touched each resource, and which way, within the lifetime of a link.
    func touches(by conversationId: String?, now: Date) -> [FleetRef: RavenTouch] {
        guard let conversationId else {
            return [:]
        }
        return (mapTouches[conversationId] ?? [:]).filter { now.timeIntervalSince($0.value.at) < Self.touchLifetime }
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
        note(object, by: actor.id)
    }
}

/// One touch between Raven and a resource: when, and whether the resource reached Raven or Raven it.
struct RavenTouch: Equatable {
    let at: Date
    let isFromResource: Bool
}

/// Raven's links drawn over the board, cut away where the cards are so they run beneath them: from its tab, a line to each team a conversation directs, slow and
/// faint, and to what it touched a moment ago, bright, swaying like a rope shaken from the bottom, with a
/// light running up it, fading as it ages. SwiftUI only finds where each line runs, when the cards move;
/// Core Animation sways and fades them, so a link costs the app nothing frame by frame.
struct RavenLinksOverlay: View {
    let links: RavenLinks
    /// The conversation open in Raven's panel, whose links are drawn; nil for none.
    let conversationId: String?
    let listHeldRefs: [FleetRef]
    let mapAnchors: [FleetRef: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            RavenLinksLayer(listLinks: listLinks(proxy: proxy), listCardFrames: listCardFrames(proxy: proxy))
        }
        .allowsHitTesting(false)
    }

    /// The frames of the board's cards, which the links pass beneath.
    private func listCardFrames(proxy: GeometryProxy) -> [CGRect] {
        mapAnchors
            .filter { $0.key != RavenLinks.ravenRef }
            .map { proxy[$0.value] }
            .sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    private func listLinks(proxy: GeometryProxy) -> [RavenLink] {
        guard let ravenAnchor = mapAnchors[RavenLinks.ravenRef] else {
            return []
        }
        let ravenFrame = proxy[ravenAnchor]
        let start = CGPoint(x: ravenFrame.midX, y: ravenFrame.minY)
        var listLinks: [RavenLink] = []
        let mapTouched = links.touches(by: conversationId, now: .now)
        for ref in Set(listHeldRefs).union(mapTouched.keys) {
            guard let anchor = mapAnchors[ref] else {
                continue
            }
            let target = proxy[anchor]
            listLinks.append(RavenLink(
                ref: ref,
                start: start,
                end: CGPoint(x: target.midX, y: target.maxY),
                isHeld: listHeldRefs.contains(ref),
                touch: mapTouched[ref]
            ))
        }
        return listLinks.sorted { $0.ref.id < $1.ref.id }
    }
}

/// One line from Raven's tab: what it reaches, between which points, whether it is held while a
/// conversation directs a team, and when and which way Raven and what it reaches last touched.
struct RavenLink: Equatable {
    let ref: FleetRef
    let start: CGPoint
    let end: CGPoint
    let isHeld: Bool
    let touch: RavenTouch?
}

/// The links as Core Animation layers.
struct RavenLinksLayer: NSViewRepresentable {
    let listLinks: [RavenLink]
    let listCardFrames: [CGRect]

    func makeNSView(context: Context) -> RavenLinksView {
        RavenLinksView()
    }

    func updateNSView(_ view: RavenLinksView, context: Context) {
        view.show(listLinks)
        view.passBeneath(listCardFrames)
    }
}

/// The layers of Raven's links: for each, a faint echo, the line, a light climbing it, a dot at the end it
/// leaves and an arrowhead at the end it reaches, swaying and fading by Core Animation alone, masked
/// away where the cards are.
final class RavenLinksView: NSView {
    private static let cardCornerRadius: CGFloat = 10
    private static let arrowLength: CGFloat = 9
    private static let arrowHalfWidth: CGFloat = 4.5
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
    private var listMaskedFrames: [CGRect] = []
    private let cardMask = CAShapeLayer()

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cardMask.fillRule = .evenOdd
        cardMask.fillColor = NSColor.black.cgColor
        layer?.mask = cardMask
    }

    override func layout() {
        super.layout()
        let listFrames = listMaskedFrames
        listMaskedFrames = []
        passBeneath(listFrames)
    }

    /// Cut the links away where these cards are, so they run beneath them.
    func passBeneath(_ listFrames: [CGRect]) {
        guard listFrames != listMaskedFrames || cardMask.frame != bounds else {
            return
        }
        listMaskedFrames = listFrames
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardMask.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        for frame in listFrames {
            path.addRoundedRect(in: frame, cornerWidth: Self.cardCornerRadius, cornerHeight: Self.cardCornerRadius)
        }
        cardMask.path = path
        CATransaction.commit()
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
        let age = link.touch.map { Date.now.timeIntervalSince($0.at) } ?? .infinity
        let isFromResource = link.touch?.isFromResource == true
        let isTouched = age < RavenLinks.touchLifetime
        let sway = isTouched ? Self.touchedSway + Self.heldSway : Self.heldSway
        let echo = Self.shape(ink: ink, opacity: 0.18, width: 1)
        let line = Self.shape(ink: ink, opacity: 0.55, width: 1.6)
        Self.sway(echo, through: Self.swayPaths(link, sway: sway * 0.6, phase: phase - 0.9), swayTime: swayTime)
        Self.sway(line, through: Self.swayPaths(link, sway: sway, phase: phase), swayTime: swayTime)
        group.addSublayer(echo)
        group.addSublayer(line)
        if isTouched {
            let light = Self.shape(ink: ink, opacity: 0.85, width: 2.6)
            light.lineDashPattern = Self.dashPattern
            Self.sway(light, through: Self.swayPaths(link, sway: sway, phase: phase), swayTime: swayTime)
            let climb = CABasicAnimation(keyPath: "lineDashPhase")
            climb.fromValue = 0
            climb.toValue = -Self.dashPattern.reduce(0) { $0 + CGFloat($1.doubleValue) }
            climb.duration = Double(Self.dashPattern.reduce(0) { $0 + $1.doubleValue }) / Double(Self.lightSpeed)
            climb.repeatCount = .infinity
            light.add(climb, forKey: "climb")
            group.addSublayer(light)
        }
        group.addSublayer(Self.dot(at: isFromResource ? link.end : link.start, radius: 2.5, ink: ink, opacity: 0.6))
        let head = CAShapeLayer()
        head.fillColor = ink
        head.strokeColor = nil
        head.opacity = 0.85
        Self.sway(head, through: Self.headPaths(link, sway: sway, phase: phase, isAtStart: isFromResource), swayTime: swayTime)
        group.addSublayer(head)
        group.opacity = link.isHeld && !isTouched ? Self.heldStrength : 1
        if isTouched {
            group.add(fadeAnimation(age: age, isHeld: link.isHeld), forKey: "fade")
        }
        return group
    }

    /// The line's path at frames around a loop, the middle swinging side to side on a wave running up
    /// from Raven.
    private static func swayPaths(_ link: RavenLink, sway: CGFloat, phase: Double) -> [CGPath] {
        let rise = link.start.y - link.end.y
        return (0...swayFrames).map { frame -> CGPath in
            let wave = Double(frame) / Double(swayFrames) * .pi * 2 + phase
            let path = CGMutablePath()
            path.move(to: link.start)
            path.addCurve(
                to: link.end,
                control1: CGPoint(x: link.start.x + sway * CGFloat(sin(wave)), y: link.start.y - rise * 0.45),
                control2: CGPoint(x: link.end.x + sway * CGFloat(sin(wave - 1.4)), y: link.end.y + rise * 0.4)
            )
            return path
        }
    }

    /// The arrowhead's path at the same frames as the line's, its tip on the end the link reaches and
    /// pointing along the line as it sways there: Raven's end for what reached Raven, else the resource's.
    private static func headPaths(_ link: RavenLink, sway: CGFloat, phase: Double, isAtStart: Bool) -> [CGPath] {
        let rise = link.start.y - link.end.y
        return (0...swayFrames).map { frame -> CGPath in
            let wave = Double(frame) / Double(swayFrames) * .pi * 2 + phase
            let tip: CGPoint
            let control: CGPoint
            if isAtStart {
                tip = link.start
                control = CGPoint(x: link.start.x + sway * CGFloat(sin(wave)), y: link.start.y - rise * 0.45)
            } else {
                tip = link.end
                control = CGPoint(x: link.end.x + sway * CGFloat(sin(wave - 1.4)), y: link.end.y + rise * 0.4)
            }
            let length = max(hypot(tip.x - control.x, tip.y - control.y), 1)
            let along = CGPoint(x: (tip.x - control.x) / length, y: (tip.y - control.y) / length)
            let base = CGPoint(x: tip.x - along.x * arrowLength, y: tip.y - along.y * arrowLength)
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x - along.y * arrowHalfWidth, y: base.y + along.x * arrowHalfWidth))
            path.addLine(to: CGPoint(x: base.x + along.y * arrowHalfWidth, y: base.y - along.x * arrowHalfWidth))
            path.closeSubpath()
            return path
        }
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

    /// Give a line its sway through these paths, continued from where every link's loop stands now, and
    /// the first of them as its own, so it shows where the sway does not run.
    private static func sway(_ shape: CAShapeLayer, through listPaths: [CGPath], swayTime: CFTimeInterval) {
        shape.path = listPaths.first
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = listPaths
        animation.duration = swayPeriod
        animation.repeatCount = .infinity
        animation.timeOffset = swayTime
        animation.calculationMode = .linear
        shape.add(animation, forKey: "sway")
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
