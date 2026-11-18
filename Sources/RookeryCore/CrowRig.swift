import CoreGraphics
import Foundation

/// What a crow is shown doing: an agent's state, or Raven, Rookery's own agent, waiting or at work.
public enum CrowAct: Hashable, Sendable {
    case agent(AgentState)
    case ravenIdle
    case ravenWorking

    /// Whether the bird is Raven, larger and with a raven's throat and tail.
    public var isRaven: Bool {
        switch self {
        case .agent: false
        case .ravenIdle, .ravenWorking: true
        }
    }
}

/// The colors a crow is drawn in for one theme: the darkest and lightest a feather facet can be, the beak's,
/// the paper of a letter, the perch line and the eye. In dark themes the crow turns silver, so it stands out
/// on a near-black ground.
public struct CrowLook: Hashable, Sendable {
    let low: [CGFloat]
    let high: [CGFloat]
    let beakLow: [CGFloat]
    let beakHigh: [CGFloat]
    let paperLow: [CGFloat]
    let paperHigh: [CGFloat]
    let line: [CGFloat]
    let eye: [CGFloat]

    public static let light = CrowLook(
        low: [14, 15, 18, 255], high: [96, 102, 114, 255], beakLow: [26, 27, 31, 255], beakHigh: [120, 125, 136, 255],
        paperLow: [196, 190, 176, 255], paperHigh: [250, 247, 240, 255], line: [20, 22, 26, 140], eye: [231, 233, 238, 255]
    )
    public static let dark = CrowLook(
        low: [118, 124, 136, 255], high: [240, 242, 246, 255], beakLow: [150, 155, 166, 255], beakHigh: [250, 251, 253, 255],
        paperLow: [150, 146, 138, 255], paperHigh: [252, 250, 245, 255], line: [220, 224, 232, 128], eye: [17, 19, 24, 255]
    )
    public static let highContrastLight = CrowLook(
        low: [0, 0, 0, 255], high: [70, 70, 72, 255], beakLow: [0, 0, 0, 255], beakHigh: [60, 60, 62, 255],
        paperLow: [196, 190, 176, 255], paperHigh: [250, 247, 240, 255], line: [0, 0, 0, 255], eye: [255, 255, 255, 255]
    )
    public static let highContrastDark = CrowLook(
        low: [175, 175, 178, 255], high: [255, 255, 255, 255], beakLow: [200, 200, 202, 255], beakHigh: [255, 255, 255, 255],
        paperLow: [150, 146, 138, 255], paperHigh: [252, 250, 245, 255], line: [255, 255, 255, 255], eye: [0, 0, 0, 255]
    )

    var isDark: Bool {
        low[0] > 100
    }
}

/// The crow of Rookery's agents, drawn in flat facets lit from the top left, acting out what an agent is
/// doing: asleep on its perch, gliding, beating its wings, pressing down a stack, calling out, staring with
/// its head cocked, spreading its wings, ruffled, waiting in the rain, or gone and its perch left empty.
/// Every act is a loop of continuous curves, so each frame is drawn afresh; the color of the act shows only
/// in a thin signal line under the perch. Drawn in a 100-unit square whose y axis points down, centred on
/// the box the whole loop fills, every agent's crow at one scale so a crow does not jump as its state
/// changes.
public enum CrowRig {
    /// How much of its square the widest act fills.
    static let frameFill: CGFloat = 0.94
    static let unit: CGFloat = 100
    static let light = CGVector(dx: -0.62, dy: -0.78)
    static let seam: CGFloat = 0.35
    /// The frames a second most acts are drawn at, and the fast ones.
    static let framesPerSecond: Double = 30
    static let fastFramesPerSecond: Double = 60

    /// Every act of an agent's crow, and of Raven.
    public static let listActs: [CrowAct] = AgentState.allCases.map(CrowAct.agent) + [.ravenIdle, .ravenWorking]

    /// How long an act's loop runs.
    public static func period(of act: CrowAct) -> Double {
        switch act {
        case .agent(.idle): 8.4
        case .agent(.thinking), .agent(.compacting): 13.2
        case .agent(.working): 0.42
        case .agent(.needsApproval): 1.1
        case .agent(.needsInput): 6
        case .agent(.done): 4.4
        case .agent(.error): 4.4
        case .agent(.rateLimited): 5
        case .agent(.ended): 4.8
        case .ravenIdle: 6
        case .ravenWorking: 0.62
        }
    }

    /// How many frames a second an act is drawn at: more for wings that beat fast.
    public static func framesPerSecond(of act: CrowAct) -> Double {
        switch act {
        case .agent(.working), .ravenWorking, .agent(.needsApproval): fastFramesPerSecond
        default: framesPerSecond
        }
    }

    /// The moment of an act's loop that reads best held still, for Reduce Motion.
    public static func stillTime(of act: CrowAct) -> Double {
        switch act {
        case .agent(.thinking): 0.9
        case .agent(.working): 0.1
        case .agent(.compacting): 0.45
        case .agent(.needsApproval): 0.22
        case .agent(.needsInput): 1.6
        case .agent(.done): 1.6
        case .agent(.error): 0.3
        case .agent(.rateLimited): 0.4
        case .agent(.ended): 1.2
        case .agent(.idle): 0
        case .ravenIdle: 0.9
        case .ravenWorking: 0.16
        }
    }

    /// The color of the signal line under an act's perch.
    public static func signal(of act: CrowAct) -> [CGFloat] {
        switch act {
        case .agent(.idle): [140, 150, 170, 255]
        case .agent(.thinking): [91, 141, 239, 255]
        case .agent(.working): [43, 179, 163, 255]
        case .agent(.compacting): [63, 176, 201, 255]
        case .agent(.needsApproval): [232, 163, 58, 255]
        case .agent(.needsInput): [160, 122, 224, 255]
        case .agent(.done): [79, 180, 119, 255]
        case .agent(.error): [224, 86, 79, 255]
        case .agent(.rateLimited): [215, 103, 154, 255]
        case .agent(.ended): [154, 160, 171, 255]
        case .ravenIdle, .ravenWorking: [141, 116, 232, 255]
        }
    }

    /// Draw one frame of an act filling a square.
    ///
    /// - Parameters:
    ///   - act: what the crow is doing
    ///   - time: seconds into its loop
    ///   - context: a context whose y axis points down
    ///   - side: the square's side in the context's units
    ///   - look: the theme's colors
    public static func draw(_ act: CrowAct, at time: Double, in context: CGContext, side: CGFloat, look: CrowLook) {
        let box = mapBoxes[act] ?? CGRect(x: 0, y: 0, width: unit, height: unit)
        let scale = side / unit * (act.isRaven ? ravenScale : crowScale)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: side / 2 - box.midX * scale, y: side / 2 - box.midY * scale)
        context.scaleBy(x: scale, y: scale)
        drawScene(pose(of: act, at: time), at: time, in: context, look: look, signal: signal(of: act), isMeasuring: false)
    }

    // MARK: - Centring

    /// The box each act's whole loop fills, measured once by drawing it.
    static let mapBoxes: [CrowAct: CGRect] = Dictionary(uniqueKeysWithValues: listActs.map { ($0, measure($0)) })
    static let crowScale: CGFloat = listActs.filter { !$0.isRaven }.compactMap { mapBoxes[$0].map(fitScale) }.min() ?? 1
    static let ravenScale: CGFloat = listActs.filter(\.isRaven).compactMap { mapBoxes[$0].map(fitScale) }.min() ?? 1

    private static func fitScale(_ box: CGRect) -> CGFloat {
        min(unit * frameFill / max(box.width, 1), unit * frameFill / max(box.height, 1))
    }

    private static func measure(_ act: CrowAct) -> CGRect {
        let pixels = 160
        let ratio = CGFloat(pixels) / unit
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: unit, height: unit)
        }
        var minX = pixels, minY = pixels, maxX = 0, maxY = 0
        let sampleCount = 36
        let span = min(period(of: act), 8)
        for sample in 0..<sampleCount {
            let time = Double(sample) / Double(sampleCount) * span
            context.saveGState()
            context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: ratio, y: -ratio)
            drawScene(pose(of: act, at: time), at: time, in: context, look: .light, signal: [0, 0, 0, 255], isMeasuring: true)
            context.restoreGState()
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
                continue
            }
            for row in stride(from: 0, to: pixels, by: 2) {
                for column in stride(from: 0, to: pixels, by: 2) where data[(row * pixels + column) * 4 + 3] > 24 {
                    minX = min(minX, column); maxX = max(maxX, column)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        guard maxX > minX else {
            return CGRect(x: 0, y: 0, width: unit, height: unit)
        }
        return CGRect(x: CGFloat(minX) / ratio, y: CGFloat(minY) / ratio, width: CGFloat(maxX - minX + 2) / ratio, height: CGFloat(maxY - minY + 2) / ratio)
    }

    // MARK: - Poses

    /// Everything about the crow a frame changes. Lengths are in the 100-unit square, angles in degrees.
    struct Pose {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rotation: CGFloat = 0
        var fluff: CGFloat = 0
        var ruffle: CGFloat = 0
        var breath: CGFloat = 0
        var headX: CGFloat = 0
        var headY: CGFloat = 0
        var headTilt: CGFloat = 0
        var headTurn: CGFloat = 0
        var isTucked = false
        var beak: CGFloat = 0
        var wingAngle: CGFloat = 0
        var wingSpread: CGFloat = 0
        var farWingAngle: CGFloat?
        var farWingSpread: CGFloat = 0
        var legs: CGFloat = 1
        var tail: CGFloat = 0
        var isRaven = false
        var isPerched = true
        var isEmpty = false
        var signal: CGFloat = 0.6
        var listProps: [Prop] = []
    }

    /// What is around the crow in an act.
    enum Prop {
        case stack(press: CGFloat)
        case call
        case rain
        case leftFeather
        case letter
        case carried
    }

    private static func wave(_ time: Double, _ period: Double, _ phase: Double = 0) -> CGFloat {
        CGFloat(sin(time / period * 2 * .pi + phase))
    }

    private static func pulse(_ time: Double, _ period: Double, _ width: Double, offset: Double = 0) -> CGFloat {
        let x = ((time - offset).truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        return x < width ? CGFloat(sin(x / width * .pi)) : 0
    }

    static func pose(of act: CrowAct, at time: Double) -> Pose {
        var pose = Pose()
        pose.isRaven = act.isRaven
        switch act {
        case .agent(.idle):
            pose.y = 2; pose.fluff = 0.5; pose.breath = 0.03 * wave(time, 4.2); pose.isTucked = true; pose.legs = 0.35; pose.tail = -4
            pose.signal = 0.35 + 0.15 * wave(time, 4.2)
        case .agent(.thinking):
            let lift = pow(max(0, wave(time, 3.3)), 4)
            pose.isPerched = false; pose.y = -6 + 3 * wave(time, 4.4); pose.rotation = -4 + 5 * wave(time, 4.4, 1.2)
            pose.wingAngle = 8 + 26 * lift; pose.wingSpread = 1; pose.farWingAngle = 14 + 24 * lift; pose.farWingSpread = 1
            pose.legs = 0; pose.tail = 6; pose.headTurn = 0.4 * wave(time, 6.6); pose.signal = 0.5
        case .agent(.working):
            let flap = wave(time, 0.42)
            pose.isPerched = false; pose.y = -6 + 2.4 * wave(time, 0.42, 1.3); pose.rotation = -10
            pose.wingAngle = 14 + 58 * flap; pose.wingSpread = 1; pose.farWingAngle = 22 + 52 * flap; pose.farWingSpread = 1
            pose.legs = 0; pose.tail = 10
        case .agent(.compacting):
            let dip = pulse(time, 1.65, 0.55)
            pose.rotation = 14 * dip; pose.headX = 3 * dip; pose.headY = 6 * dip; pose.headTilt = 26 * dip; pose.tail = -6 * dip
            pose.listProps = [.stack(press: dip)]; pose.signal = 0.55
        case .agent(.needsApproval):
            let caw = pulse(time, 1.1, 0.4)
            let flick = wave(time, 1.1 / 12)
            pose.rotation = -16 - 10 * caw; pose.y = -1.5 * caw; pose.headTilt = -42 * caw - 6; pose.headY = -3 * caw; pose.headX = 1.5 * caw
            pose.beak = 0.25 + 1.15 * caw
            pose.wingAngle = 30 + 10 * flick * (0.4 + caw); pose.wingSpread = 0.5
            pose.farWingAngle = 36 + 10 * flick * (0.4 + caw); pose.farWingSpread = 0.45
            pose.tail = 10 * caw; pose.fluff = 0.2 * caw; pose.listProps = [.call]; pose.signal = 0.6 + 0.4 * caw
        case .agent(.needsInput):
            let side: CGFloat = wave(time, 6) >= 0 ? 1 : -1
            let settle = min(1, abs(wave(time, 6)) * 3)
            pose.headTurn = 0.8; pose.headTilt = -24 * side * settle; pose.headY = -1; pose.signal = 0.5 + 0.35 * wave(time, 1.5)
        case .agent(.done):
            let u = time.truncatingRemainder(dividingBy: 4.4) / 4.4
            let open: CGFloat = u < 0.18 ? CGFloat(sin(u / 0.18 * .pi / 2)) : u < 0.62 ? 1 : u < 0.8 ? CGFloat(cos((u - 0.62) / 0.18 * .pi / 2)) : 0
            let held = open * (1 + 0.04 * wave(time, 0.88))
            pose.wingAngle = 78 * held; pose.wingSpread = open; pose.farWingAngle = 84 * held; pose.farWingSpread = open
            pose.rotation = -12 * open; pose.headTilt = -10 * open; pose.tail = 6 * open; pose.signal = 0.35 + 0.65 * open
        case .agent(.error):
            pose.ruffle = 0.85 + 0.15 * wave(time, 0.55); pose.fluff = 0.6; pose.rotation = 9 + 3 * wave(time, 2.2); pose.x = -2
            pose.headY = 5; pose.headX = -3; pose.headTilt = 10; pose.tail = 8; pose.legs = 0.75
            pose.signal = 0.45 + 0.55 * abs(wave(time, 1.1))
        case .agent(.rateLimited):
            pose.fluff = 0.4; pose.headY = 4; pose.headX = -2; pose.legs = 0.4; pose.tail = -2; pose.breath = 0.015 * wave(time, 5)
            pose.listProps = [.rain]; pose.signal = 0.5
        case .agent(.ended):
            pose.isEmpty = true; pose.listProps = [.leftFeather]; pose.signal = 0.25
        case .ravenIdle:
            let look = pulse(time, 6, 0.3)
            pose.headY = 5 * look; pose.headTilt = 30 * look; pose.headX = 2 * look; pose.listProps = [.letter]; pose.signal = 0.5
        case .ravenWorking:
            let flap = wave(time, 0.62)
            pose.isPerched = false; pose.y = -6 + 2 * wave(time, 0.62, 1); pose.rotation = -7
            pose.wingAngle = 16 + 48 * flap; pose.wingSpread = 1; pose.farWingAngle = 24 + 44 * flap; pose.farWingSpread = 1
            pose.legs = 0; pose.tail = 8; pose.listProps = [.carried]
        }
        return pose
    }

    // MARK: - Drawing

    private static let listBody: [CGPoint] = [
        CGPoint(x: 64, y: 52), CGPoint(x: 66.5, y: 59), CGPoint(x: 62, y: 67), CGPoint(x: 54, y: 71), CGPoint(x: 44, y: 71.5), CGPoint(x: 35, y: 69),
        CGPoint(x: 27, y: 65.5), CGPoint(x: 26, y: 62), CGPoint(x: 33, y: 57), CGPoint(x: 42, y: 52), CGPoint(x: 50, y: 49), CGPoint(x: 57, y: 47.8),
    ]
    private static let listWingFolded: [CGPoint] = [
        CGPoint(x: 3, y: -1), CGPoint(x: 5, y: 3), CGPoint(x: 0, y: 6), CGPoint(x: -10, y: 8), CGPoint(x: -21, y: 9), CGPoint(x: -31, y: 9),
        CGPoint(x: -35, y: 7.5), CGPoint(x: -30, y: 6), CGPoint(x: -34, y: 4), CGPoint(x: -27, y: 2.5), CGPoint(x: -18, y: 0), CGPoint(x: -8, y: -2),
    ]
    private static let listWingOpen: [CGPoint] = [
        CGPoint(x: 3, y: -2), CGPoint(x: 5, y: 3), CGPoint(x: -3, y: 7), CGPoint(x: -14, y: 9), CGPoint(x: -28, y: 8), CGPoint(x: -40, y: 5),
        CGPoint(x: -50, y: 1), CGPoint(x: -41, y: -1), CGPoint(x: -49, y: -6), CGPoint(x: -37, y: -7), CGPoint(x: -24, y: -8), CGPoint(x: -8, y: -5),
    ]

    private static func color(_ components: [CGFloat], alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: components[0] / 255, green: components[1] / 255, blue: components[2] / 255, alpha: components[3] / 255 * alpha)
    }

    private static func mix(_ low: [CGFloat], _ high: [CGFloat], _ amount: CGFloat) -> [CGFloat] {
        zip(low, high).map { $0 + ($1 - $0) * amount }
    }

    /// Fill a polygon as facets: a fan of triangles from a centre, each lit by which way it faces.
    private static func facets(_ listPoints: [CGPoint], around centre: CGPoint, low: [CGFloat], high: [CGFloat], bias: CGFloat = 0, in context: CGContext) {
        for index in listPoints.indices {
            let start = listPoints[index]
            let end = listPoints[(index + 1) % listPoints.count]
            let mx = (start.x + end.x) / 2 - centre.x
            let my = (start.y + end.y) / 2 - centre.y
            let length = max(hypot(mx, my), 0.0001)
            let lit = max(0, min(1, 0.5 + 0.55 * (mx / length * light.dx + my / length * light.dy) + bias))
            let fill = color(mix(low, high, lit))
            context.setFillColor(fill)
            context.setStrokeColor(fill)
            context.setLineWidth(seam)
            context.setLineJoin(.round)
            context.move(to: centre)
            context.addLine(to: start)
            context.addLine(to: end)
            context.closePath()
            context.drawPath(using: .fillStroke)
        }
    }

    private static func centroid(_ listPoints: [CGPoint]) -> CGPoint {
        let count = CGFloat(max(listPoints.count, 1))
        return CGPoint(x: listPoints.reduce(0) { $0 + $1.x } / count, y: listPoints.reduce(0) { $0 + $1.y } / count)
    }

    private static func wing(spread: CGFloat, angle: CGFloat, ruffle: CGFloat) -> [CGPoint] {
        let radians = angle * .pi / 180
        return zip(listWingFolded, listWingOpen).enumerated().map { index, pair in
            var x = pair.0.x + (pair.1.x - pair.0.x) * spread
            var y = pair.0.y + (pair.1.y - pair.0.y) * spread
            if ruffle > 0 {
                x += ruffle * 1.3 * CGFloat(sin(Double(index) * 2.3))
                y += ruffle * 1.5 * CGFloat(cos(Double(index) * 1.7))
            }
            return CGPoint(x: x * cos(radians) - y * sin(radians), y: x * sin(radians) + y * cos(radians))
        }
    }

    private static func head(radiusX: CGFloat, radiusY: CGFloat) -> [CGPoint] {
        (0..<8).map { index in
            let angle = CGFloat(index) / 8 * 2 * .pi + 0.2
            return CGPoint(x: radiusX * cos(angle), y: radiusY * sin(angle))
        }
    }

    private static func drawCrow(_ pose: Pose, look: CrowLook, in context: CGContext) {
        let size: CGFloat = pose.isRaven ? 1.1 : 1
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 50 + pose.x, y: 80 + pose.y)
        context.rotate(by: pose.rotation * .pi / 180)
        context.scaleBy(x: size, y: size)
        context.translateBy(x: -50, y: -80)
        let dimmed: ([CGFloat], CGFloat) -> [CGFloat] = { high, amount in mix(look.low, high, amount) }

        if let farAngle = pose.farWingAngle {
            context.saveGState()
            context.translateBy(x: 53, y: 53)
            let listPoints = wing(spread: pose.farWingSpread, angle: farAngle + 5, ruffle: 0)
            facets(listPoints, around: centroid(listPoints), low: look.low, high: dimmed(look.high, 0.45), bias: -0.2, in: context)
            context.restoreGState()
        }
        context.saveGState()
        context.translateBy(x: 29, y: 64.5)
        context.rotate(by: (pose.tail + 10) * .pi / 180)
        let tail = pose.isRaven
            ? [CGPoint(x: 3, y: -3), CGPoint(x: -17, y: -1.5), CGPoint(x: -23, y: 2), CGPoint(x: -17, y: 5.5), CGPoint(x: 3, y: 3)]
            : [CGPoint(x: 3, y: -3), CGPoint(x: -17, y: -1.5), CGPoint(x: -19, y: 2), CGPoint(x: -17, y: 5.5), CGPoint(x: 3, y: 3)]
        facets(tail, around: CGPoint(x: -6, y: 1), low: look.low, high: dimmed(look.high, 0.7), in: context)
        context.restoreGState()
        if pose.legs > 0.05 {
            context.saveGState()
            context.setStrokeColor(color(look.low))
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            let foot = 69 + 11 * pose.legs
            for legX: CGFloat in [48, 53] {
                context.move(to: CGPoint(x: legX, y: 69)); context.addLine(to: CGPoint(x: legX - 0.5, y: foot))
                context.move(to: CGPoint(x: legX - 3.2, y: foot + 0.5)); context.addLine(to: CGPoint(x: legX + 2.8, y: foot + 0.4))
            }
            context.strokePath()
            context.restoreGState()
        }
        let fluffScale = 1 + 0.18 * pose.fluff
        let body = listBody.enumerated().map { index, point -> CGPoint in
            var px = 47 + (point.x - 47) * fluffScale
            var py = 60 + (point.y - 60) * fluffScale * (1 + pose.breath)
            if pose.ruffle > 0 {
                let kick: CGFloat = index % 2 == 1 ? 1 : -0.5
                px += (px - 47) * 0.06 * pose.ruffle * kick
                py += (py - 60) * 0.1 * pose.ruffle * kick
            }
            return CGPoint(x: px, y: py)
        }
        facets(body, around: CGPoint(x: 49, y: 59), low: look.low, high: look.high, in: context)
        let headX = 63.5 + pose.headX
        let headY = 47 + pose.headY
        if pose.isTucked {
            let tilt: CGFloat = -0.35
            let tucked = head(radiusX: 7.5, radiusY: 5.8).map { point in
                CGPoint(x: 55 + point.x * cos(tilt) - point.y * sin(tilt), y: 50.5 + point.x * sin(tilt) + point.y * cos(tilt))
            }
            facets(tucked, around: CGPoint(x: 54, y: 49.5), low: look.low, high: look.high, bias: 0.06, in: context)
            facets([CGPoint(x: 51, y: 48.6), CGPoint(x: 45.5, y: 51.2), CGPoint(x: 51, y: 51.4)], around: CGPoint(x: 49, y: 50.4), low: look.beakLow, high: look.beakHigh, in: context)
        } else {
            facets(
                [CGPoint(x: 57, y: 48.5), CGPoint(x: headX + 2, y: headY + 3), CGPoint(x: headX + 4, y: headY + 7), CGPoint(x: 63, y: 60), CGPoint(x: 55, y: 56)],
                around: CGPoint(x: 59, y: 54), low: look.low, high: look.high, in: context
            )
            context.saveGState()
            context.translateBy(x: headX, y: headY)
            context.rotate(by: pose.headTilt * .pi / 180)
            let radiusX: CGFloat = pose.isRaven ? 8.6 : 7.8
            let radiusY: CGFloat = pose.isRaven ? 7.4 : 6.8
            if pose.isRaven {
                facets(
                    [CGPoint(x: 3, y: 4), CGPoint(x: 6, y: 11), CGPoint(x: 3.5, y: 9), CGPoint(x: 2, y: 12.5), CGPoint(x: 0, y: 8.5), CGPoint(x: -2, y: 11), CGPoint(x: -3, y: 5)],
                    around: CGPoint(x: 1.5, y: 7), low: look.low, high: dimmed(look.high, 0.7), in: context
                )
            }
            facets(head(radiusX: radiusX, radiusY: radiusY), around: CGPoint(x: -0.8, y: -0.8), low: look.low, high: look.high, bias: 0.08, in: context)
            let beakLength = (pose.isRaven ? 15 : 13) * (1 - 0.35 * abs(pose.headTurn))
            context.saveGState()
            context.translateBy(x: 6, y: -0.5)
            context.saveGState()
            context.rotate(by: pose.beak * 9 * .pi / 180)
            facets(
                [CGPoint(x: 0, y: 1.2), CGPoint(x: beakLength * 0.9, y: 1.6), CGPoint(x: 0, y: 3.6)],
                around: CGPoint(x: beakLength * 0.3, y: 2.1), low: look.beakLow, high: mix(look.beakLow, look.beakHigh, 0.5), in: context
            )
            context.restoreGState()
            facets(
                [CGPoint(x: -0.5, y: -2.8), CGPoint(x: beakLength * 0.55, y: -3.1), CGPoint(x: beakLength, y: 1.4), CGPoint(x: beakLength * 0.45, y: 0.9), CGPoint(x: -0.5, y: 1.6)],
                around: CGPoint(x: beakLength * 0.35, y: -0.6), low: look.beakLow, high: look.beakHigh, in: context
            )
            context.restoreGState()
            let eyeRadius: CGFloat = pose.isRaven ? 1.25 : 1.15
            context.setFillColor(color(look.eye))
            context.fillEllipse(in: CGRect(x: 2.6 - 1.2 * pose.headTurn - eyeRadius, y: -1.6 - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))
            if pose.listProps.contains(where: { if case .carried = $0 { true } else { false } }) {
                context.saveGState()
                context.translateBy(x: 6 + beakLength * 0.72, y: 4.6)
                context.rotate(by: 0.22)
                drawEnvelope(width: 11, height: 7, look: look, seal: nil, in: context)
                context.restoreGState()
            }
            context.restoreGState()
        }
        context.saveGState()
        context.translateBy(x: 55, y: 52)
        let nearWing = wing(spread: pose.wingSpread, angle: pose.wingAngle, ruffle: pose.ruffle)
        facets(nearWing, around: centroid(nearWing), low: look.low, high: look.high, bias: 0.04, in: context)
        context.restoreGState()
    }

    /// An envelope in the crow's facets: its back, the flap folded down over it, the side and bottom folds,
    /// each its own plane, and a seal where the flap's point meets them.
    private static func drawEnvelope(width: CGFloat, height: CGFloat, look: CrowLook, seal: [CGFloat]?, in context: CGContext) {
        let shade: (CGFloat) -> CGColor = { amount in color(mix(look.paperLow, look.paperHigh, amount)) }
        let left = -width / 2, right = width / 2, top = -height / 2, bottom = height / 2
        let centre = CGPoint(x: 0, y: height * 0.08)
        let plane: ([CGPoint], CGFloat) -> Void = { listPoints, amount in
            context.setFillColor(shade(amount)); context.setStrokeColor(shade(amount)); context.setLineWidth(0.25)
            context.addLines(between: listPoints); context.closePath(); context.drawPath(using: .fillStroke)
        }
        plane([CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)], 0.55)
        plane([CGPoint(x: left, y: top), centre, CGPoint(x: left, y: bottom)], 0.72)
        plane([CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), centre], 0.42)
        plane([CGPoint(x: left, y: bottom), CGPoint(x: 0, y: centre.y - height * 0.05), CGPoint(x: right, y: bottom)], 0.6)
        plane([CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: 0, y: centre.y + height * 0.12)], 0.95)
        context.setStrokeColor(shade(0.2)); context.setLineWidth(0.35)
        context.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: 0, y: centre.y + height * 0.12), CGPoint(x: right, y: top)])
        context.strokePath()
        if let seal {
            let radius = height * 0.17
            context.setFillColor(color(seal))
            context.fillEllipse(in: CGRect(x: -radius, y: centre.y + height * 0.1 - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// Rain: slanting streaks of different lengths and speeds, each splashing where it meets the perch,
    /// and drops running off the tip of the tail; every streak comes round a whole number of times a loop.
    private static func drawRain(at time: Double, look: CrowLook, in context: CGContext) {
        let ink: [CGFloat] = look.isDark ? [210, 216, 228, 255] : [70, 78, 94, 255]
        let perchY: CGFloat = 80.6
        let slant: CGFloat = 0.22
        let loop = period(of: .agent(.rateLimited))
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        for index in 0..<26 {
            let seed = (Double(index) * 0.6180339).truncatingRemainder(dividingBy: 1)
            let turns = Double(4 + index % 3)
            let progress = (time / loop * turns + seed).truncatingRemainder(dividingBy: 1)
            let length = 5 + 7 * CGFloat((Double(index) * 0.73).truncatingRemainder(dividingBy: 1))
            let x = 4 + CGFloat((Double(index) * 37.3).truncatingRemainder(dividingBy: 92))
            let y = -10 + CGFloat(progress) * 120
            let end = min(y, perchY)
            let start = end - length
            if start > perchY {
                continue
            }
            let strength = 0.18 + 0.3 * CGFloat((Double(index) * 0.41).truncatingRemainder(dividingBy: 1))
            if let gradient = CGGradient(colorsSpace: nil, colors: [color(ink, alpha: 0), color(ink, alpha: strength)] as CFArray, locations: [0, 1]) {
                context.saveGState()
                context.setLineWidth(0.45 + 0.35 * CGFloat((Double(index) * 0.29).truncatingRemainder(dividingBy: 1)))
                context.move(to: CGPoint(x: x - slant * (end - start), y: start))
                context.addLine(to: CGPoint(x: x, y: end))
                context.replacePathWithStrokedPath()
                context.clip()
                context.drawLinearGradient(gradient, start: CGPoint(x: x - slant * (end - start), y: start), end: CGPoint(x: x, y: end), options: [])
                context.restoreGState()
            }
            if y > perchY, y < perchY + 6, x > 24, x < 76 {
                let splash = (y - perchY) / 6
                context.setStrokeColor(color(ink, alpha: 0.55 * (1 - splash)))
                context.setLineWidth(0.45)
                context.move(to: CGPoint(x: x - 0.6, y: perchY - 0.4)); context.addLine(to: CGPoint(x: x - 0.6 - 1.6 * splash, y: perchY - 0.4 - 1.8 * splash))
                context.move(to: CGPoint(x: x + 0.6, y: perchY - 0.4)); context.addLine(to: CGPoint(x: x + 0.6 + 1.6 * splash, y: perchY - 0.4 - 1.8 * splash))
                context.strokePath()
            }
        }
        for index in 0..<2 {
            let progress = CGFloat((time / (loop / 3) + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
            let y = 69 + progress * 11.5
            context.setFillColor(color(ink, alpha: 0.7 * (1 - progress * 0.6)))
            context.move(to: CGPoint(x: 13, y: y - 1.4))
            context.addQuadCurve(to: CGPoint(x: 13, y: y + 0.9), control: CGPoint(x: 14.1, y: y + 0.2))
            context.addQuadCurve(to: CGPoint(x: 13, y: y - 1.4), control: CGPoint(x: 11.9, y: y + 0.2))
            context.fillPath()
        }
    }

    private static func drawScene(_ pose: Pose, at time: Double, in context: CGContext, look: CrowLook, signal: [CGFloat], isMeasuring: Bool) {
        let line = color(look.line)
        if !isMeasuring {
            context.saveGState()
            context.setStrokeColor(color(signal, alpha: 0.9 * pose.signal))
            context.setLineWidth(1.3)
            context.setLineCap(.round)
            let y: CGFloat = pose.isPerched ? 85.5 : 88
            context.move(to: CGPoint(x: 40, y: y)); context.addLine(to: CGPoint(x: 60, y: y))
            context.strokePath()
            context.restoreGState()
        }
        if pose.isPerched {
            context.saveGState()
            context.setStrokeColor(line); context.setLineWidth(0.9)
            context.move(to: CGPoint(x: 24, y: 80.6)); context.addLine(to: CGPoint(x: 76, y: 80.6))
            context.strokePath()
            context.restoreGState()
        }
        for prop in pose.listProps {
            context.saveGState()
            switch prop {
            case .stack(let press):
                context.setStrokeColor(line); context.setLineWidth(0.9)
                for index in 0..<3 {
                    let y = 79 - CGFloat(index) * 2.2 * (1 - 0.25 * press)
                    context.move(to: CGPoint(x: 66 - CGFloat(index), y: y)); context.addLine(to: CGPoint(x: 80 + CGFloat(index) * 0.5, y: y))
                }
                context.strokePath()
            case .call where !isMeasuring:
                let progress = time.truncatingRemainder(dividingBy: 1.1) / 1.1
                context.setLineWidth(1.1); context.setLineCap(.round)
                for offset in [0.08, 0.17, 0.26] {
                    let u = (progress - offset) / 0.5
                    guard u >= 0, u <= 1 else {
                        continue
                    }
                    context.setStrokeColor(color(signal, alpha: (1 - CGFloat(u)) * 0.95))
                    context.addArc(center: CGPoint(x: 76, y: 30), radius: 5 + CGFloat(u) * 11, startAngle: -1.1, endAngle: 0.15, clockwise: false)
                    context.strokePath()
                }
            case .rain where !isMeasuring:
                drawRain(at: time, look: look, in: context)
            case .leftFeather:
                context.translateBy(x: 52, y: 80.6)
                context.rotate(by: 0.2 + 0.25 * wave(time, 2.4))
                context.setStrokeColor(line); context.setLineWidth(0.5)
                context.move(to: .zero); context.addLine(to: CGPoint(x: 0, y: 12)); context.strokePath()
                facets(
                    [CGPoint(x: 0, y: 2), CGPoint(x: 1.8, y: 6), CGPoint(x: 1.2, y: 11), CGPoint(x: 0, y: 13), CGPoint(x: -1.2, y: 9), CGPoint(x: -1, y: 4)],
                    around: CGPoint(x: 0.2, y: 7), low: look.low, high: look.high, in: context
                )
            case .letter:
                context.translateBy(x: 65, y: 77.4)
                context.rotate(by: -0.08)
                drawEnvelope(width: 15, height: 6.4, look: look, seal: signal, in: context)
            case .call, .rain, .carried:
                break
            }
            context.restoreGState()
        }
        if !pose.isEmpty {
            drawCrow(pose, look: look, in: context)
        }
    }
}
