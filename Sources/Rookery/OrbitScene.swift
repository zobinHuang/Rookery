import SwiftUI

/// The screen saver's backdrop: the view from a spacecraft in orbit, looking straight down at a wireframe
/// Earth whose horizon is a half circle resting on the bottom edge, in the neon colors of 1980s retro art.
/// The surface flows from the horizon towards the viewer as the craft orbits, and the stars drift the same
/// way, slower, at the rate the craft turns to keep facing the ground.
struct OrbitScene {
    /// How far the camera is from the Earth's centre, in Earth radii: low enough that the grid bends hard
    /// towards the horizon.
    private static let cameraDistance = 1.32
    /// Seconds for one revolution of the orbit.
    private static let orbitPeriod: Double = 180
    /// The tilt of the Earth's axis against the orbit, small enough that a pole passes through the view.
    private static let inclination = 28 * Double.pi / 180
    /// Degrees between two meridians, and between two parallels.
    private static let gridStepDegrees = 6
    /// Degrees between two points sampled along a grid line.
    private static let sampleStepDegrees = 2
    private static let starCount = 1800
    /// Radians in the golden angle, which spreads the stars evenly over the sky.
    private static let goldenAngle = Double.pi * (3 - 5.0.squareRoot())
    private static let starTwinkleGroupCount = 3
    /// The constants of the usual shader hash, which scatters consecutive indices far apart.
    private static let hashIndexScale = 12.9898
    private static let hashSaltScale = 78.233
    private static let hashSpread = 43758.5453
    private static let starJitterSalt: Double = 1
    private static let starAngleSalt: Double = 2
    private static let starSizeSalt: Double = 3
    private static let starTwinklePeriod: Double = 5

    /// The horizon's radius against the width and the height of the scene.
    private static let horizonWidthFraction: CGFloat = 0.42
    private static let horizonHeightFraction: CGFloat = 0.6
    /// How far the atmosphere's glow reaches beyond the horizon, against the horizon's radius.
    private static let atmosphereReach: CGFloat = 0.22
    /// Where, against the horizon's radius, the grid starts to sink into the haze near the horizon.
    private static let hazeStart: CGFloat = 0.7
    private static let gridGlowWidth: CGFloat = 7
    private static let gridHaloWidth: CGFloat = 3
    private static let gridLineWidth: CGFloat = 1.5
    private static let horizonGlowWidth: CGFloat = 10
    private static let horizonLineWidth: CGFloat = 1.6
    private static let starMinimumSize: CGFloat = 0.8
    private static let starSizeRange: CGFloat = 1.3
    private static let scanlineSpacing: CGFloat = 3
    private static let scanlineHeight: CGFloat = 1

    private static let skyTop = Color(red: 0.03, green: 0.01, blue: 0.10)
    private static let skyMiddle = Color(red: 0.11, green: 0.02, blue: 0.23)
    private static let skyHorizon = Color(red: 0.36, green: 0.07, blue: 0.43)
    private static let atmosphere = Color(red: 1, green: 0.18, blue: 0.71)
    private static let groundCentre = Color(red: 0.06, green: 0.0, blue: 0.15)
    private static let groundEdge = Color(red: 0.17, green: 0.03, blue: 0.31)
    private static let gridNear = Color(red: 1, green: 0.44, blue: 0.81)
    private static let gridMiddle = Color(red: 0.73, green: 0.40, blue: 1)
    private static let gridFar = Color(red: 0.0, green: 0.80, blue: 1)
    private static let star = Color(red: 0.92, green: 0.90, blue: 1)
    private static let scanline = Color.black.opacity(0.12)
    private static let atmosphereOpacity = 0.55
    private static let hazeOpacity = 0.75
    private static let gridGlowOpacity = 0.16
    private static let gridHaloOpacity = 0.35
    private static let horizonGlowOpacity = 0.35
    private static let starBaseBrightness = 0.6
    private static let starTwinkleDepth = 0.4

    /// The grid on the Earth, in the Earth's own frame with the north pole along y: every meridian from pole
    /// to pole, then every parallel all the way round, each as points on the unit sphere.
    private static let listGridLines: [[SIMD3<Double>]] = meridians() + parallels()
    /// The stars as directions, spread evenly over the whole sky with a little jitter.
    private static let listStars: [SIMD3<Double>] = (0..<starCount).map(starDirection(index:))

    /// The horizon's radius in a scene of a given size, so the caption can sit in the sky above it.
    static func horizonRadius(in size: CGSize) -> CGFloat {
        min(size.width * horizonWidthFraction, size.height * horizonHeightFraction)
    }

    /// Draw what stays still behind the moving parts: the sky, the atmosphere's glow and the ground.
    ///
    /// - Parameters:
    ///   - context: the canvas to draw into
    ///   - size: the canvas size
    static func drawBackdrop(in context: GraphicsContext, size: CGSize) {
        let radius = horizonRadius(in: size)
        let centre = horizonCentre(in: size)
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .linearGradient(
            Gradient(colors: [skyTop, skyMiddle, skyHorizon]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height)
        ))
        context.fill(Path(bounds), with: .radialGradient(
            Gradient(colors: [atmosphere.opacity(atmosphereOpacity), atmosphere.opacity(0)]),
            center: centre,
            startRadius: radius,
            endRadius: radius * (1 + atmosphereReach)
        ))
        context.fill(Path(ellipseIn: horizonRect(in: size)), with: .radialGradient(
            Gradient(colors: [groundCentre, groundEdge]),
            center: centre,
            startRadius: 0,
            endRadius: radius
        ))
    }

    /// Draw what moves, as it is a given number of seconds into the orbit: the stars above the horizon and
    /// the grid below it.
    ///
    /// - Parameters:
    ///   - context: the canvas to draw into
    ///   - size: the canvas size
    ///   - time: seconds since any fixed moment; the scene repeats every orbit
    static func drawMotion(
        in context: GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        let radius = horizonRadius(in: size)
        let centre = horizonCentre(in: size)
        let focalLength = radius * (cameraDistance * cameraDistance - 1).squareRoot()
        let orbitAngle = (time.truncatingRemainder(dividingBy: orbitPeriod) / orbitPeriod) * 2 * Double.pi
        drawStars(
            in: context,
            size: size,
            focalLength: focalLength,
            orbitAngle: orbitAngle,
            time: time
        )
        let grid = gridPath(
            centre: centre,
            focalLength: focalLength,
            orbitAngle: orbitAngle
        )
        context.stroke(grid, with: .color(gridNear.opacity(gridGlowOpacity)), lineWidth: gridGlowWidth)
        context.stroke(grid, with: .color(gridNear.opacity(gridHaloOpacity)), lineWidth: gridHaloWidth)
        context.stroke(grid, with: .radialGradient(
            Gradient(colors: [gridNear, gridMiddle, gridFar]),
            center: centre,
            startRadius: 0,
            endRadius: radius
        ), lineWidth: gridLineWidth)
    }

    /// Draw what stays still in front of the moving parts: the haze the grid sinks into near the horizon,
    /// the horizon's glowing edge and the scanlines over everything.
    ///
    /// - Parameters:
    ///   - context: the canvas to draw into
    ///   - size: the canvas size
    static func drawForeground(in context: GraphicsContext, size: CGSize) {
        let radius = horizonRadius(in: size)
        let horizon = Path(ellipseIn: horizonRect(in: size))
        context.fill(horizon, with: .radialGradient(
            Gradient(colors: [groundEdge.opacity(0), groundEdge.opacity(hazeOpacity)]),
            center: horizonCentre(in: size),
            startRadius: radius * hazeStart,
            endRadius: radius
        ))
        var neon = context
        neon.blendMode = .plusLighter
        neon.stroke(horizon, with: .color(atmosphere.opacity(horizonGlowOpacity)), lineWidth: horizonGlowWidth)
        neon.stroke(horizon, with: .color(gridFar), lineWidth: horizonLineWidth)
        context.fill(scanlines(in: size), with: .color(scanline))
    }

    /// The Earth's centre, on the middle of the bottom edge.
    private static func horizonCentre(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height)
    }

    /// The square the horizon's circle is drawn in.
    private static func horizonRect(in size: CGSize) -> CGRect {
        let radius = horizonRadius(in: size)
        let centre = horizonCentre(in: size)
        return CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    /// The visible part of the grid, projected onto the canvas. A line that passes over the horizon is cut
    /// where it meets it.
    private static func gridPath(
        centre: CGPoint,
        focalLength: CGFloat,
        orbitAngle: Double
    ) -> Path {
        let horizonDepth = 1 / cameraDistance
        let orbitCosine = cos(orbitAngle)
        let orbitSine = sin(orbitAngle)
        let tiltCosine = cos(inclination)
        let tiltSine = sin(inclination)
        var path = Path()
        for listPoints in listGridLines {
            var previous = SIMD3<Double>.zero
            var isPreviousVisible = false
            for (pointIndex, earthPoint) in listPoints.enumerated() {
                let tilted = SIMD3(
                    earthPoint.x * tiltCosine - earthPoint.y * tiltSine,
                    earthPoint.x * tiltSine + earthPoint.y * tiltCosine,
                    earthPoint.z
                )
                let point = SIMD3(
                    tilted.x,
                    tilted.y * orbitCosine - tilted.z * orbitSine,
                    tilted.y * orbitSine + tilted.z * orbitCosine
                )
                let isVisible = point.z > horizonDepth
                if isVisible && !isPreviousVisible {
                    let start = pointIndex == 0
                        ? point
                        : horizonCrossing(from: previous, to: point, horizonDepth: horizonDepth)
                    path.move(to: project(start, centre: centre, focalLength: focalLength))
                }
                if isVisible || isPreviousVisible {
                    let end = isVisible
                        ? point
                        : horizonCrossing(from: previous, to: point, horizonDepth: horizonDepth)
                    path.addLine(to: project(end, centre: centre, focalLength: focalLength))
                }
                previous = point
                isPreviousVisible = isVisible
            }
        }
        return path
    }

    /// Where the grid line between two points, one on each side of the horizon, meets it.
    private static func horizonCrossing(
        from start: SIMD3<Double>,
        to end: SIMD3<Double>,
        horizonDepth: Double
    ) -> SIMD3<Double> {
        let fraction = (horizonDepth - start.z) / (end.z - start.z)
        let point = start + (end - start) * fraction
        return point / (point * point).sum().squareRoot()
    }

    /// A point on the Earth on the canvas, with the camera on the z axis looking at the Earth's centre.
    private static func project(
        _ point: SIMD3<Double>,
        centre: CGPoint,
        focalLength: CGFloat
    ) -> CGPoint {
        let depth = cameraDistance - point.z
        return CGPoint(
            x: centre.x + focalLength * point.x / depth,
            y: centre.y - focalLength * point.y / depth
        )
    }

    /// The stars in front of the camera and above the horizon, twinkling in a few groups out of step with
    /// each other.
    private static func drawStars(
        in context: GraphicsContext,
        size: CGSize,
        focalLength: CGFloat,
        orbitAngle: Double,
        time: Double
    ) {
        let bounds = CGRect(origin: .zero, size: size)
        let centre = horizonCentre(in: size)
        let radius = horizonRadius(in: size)
        let orbitCosine = cos(orbitAngle)
        let orbitSine = sin(orbitAngle)
        var listGroups = Array(repeating: Path(), count: starTwinkleGroupCount)
        for (starIndex, direction) in listStars.enumerated() {
            let depth = -(direction.y * orbitSine + direction.z * orbitCosine)
            guard depth > 0 else {
                continue
            }
            let height = direction.y * orbitCosine - direction.z * orbitSine
            let position = CGPoint(
                x: centre.x + focalLength * direction.x / depth,
                y: centre.y - focalLength * height / depth
            )
            guard
                bounds.contains(position)
                && hypot(position.x - centre.x, position.y - centre.y) > radius
            else {
                continue
            }
            let diameter = starMinimumSize + starSizeRange * hash(starIndex, salt: starSizeSalt)
            listGroups[starIndex % starTwinkleGroupCount].addEllipse(in: CGRect(
                x: position.x - diameter / 2,
                y: position.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        for (groupIndex, group) in listGroups.enumerated() {
            let phase = Double(groupIndex) / Double(starTwinkleGroupCount) * 2 * Double.pi
            let twinkle = sin(time / starTwinklePeriod * 2 * Double.pi + phase)
            let brightness = starBaseBrightness + starTwinkleDepth * twinkle
            context.fill(group, with: .color(star.opacity(brightness)))
        }
    }

    /// Faint horizontal lines across the whole scene, as on a cathode-ray screen.
    private static func scanlines(in size: CGSize) -> Path {
        var path = Path()
        var top: CGFloat = 0
        while top < size.height {
            path.addRect(CGRect(x: 0, y: top, width: size.width, height: scanlineHeight))
            top += scanlineSpacing
        }
        return path
    }

    private static func meridians() -> [[SIMD3<Double>]] {
        stride(from: 0, to: 360, by: gridStepDegrees).map { longitude in
            stride(from: -90, through: 90, by: sampleStepDegrees).map { latitude in
                earthPoint(latitude: latitude, longitude: longitude)
            }
        }
    }

    private static func parallels() -> [[SIMD3<Double>]] {
        stride(from: gridStepDegrees - 90, to: 90, by: gridStepDegrees).map { latitude in
            stride(from: 0, through: 360, by: sampleStepDegrees).map { longitude in
                earthPoint(latitude: latitude, longitude: longitude)
            }
        }
    }

    private static func earthPoint(latitude: Int, longitude: Int) -> SIMD3<Double> {
        let latitudeRadians = Double(latitude) * Double.pi / 180
        let longitudeRadians = Double(longitude) * Double.pi / 180
        return SIMD3(
            cos(latitudeRadians) * sin(longitudeRadians),
            sin(latitudeRadians),
            cos(latitudeRadians) * cos(longitudeRadians)
        )
    }

    private static func starDirection(index: Int) -> SIMD3<Double> {
        let height = 1 - 2 * (Double(index) + hash(index, salt: starJitterSalt)) / Double(starCount)
        let ring = (1 - height * height).squareRoot()
        let angle = Double(index) * goldenAngle + hash(index, salt: starAngleSalt)
        return SIMD3(ring * cos(angle), height, ring * sin(angle))
    }

    /// A number in 0..<1 that looks random but is the same for the same index and salt on every launch.
    private static func hash(_ index: Int, salt: Double) -> Double {
        let value = sin(Double(index) * hashIndexScale + salt * hashSaltScale) * hashSpread
        return value - value.rounded(.down)
    }
}
