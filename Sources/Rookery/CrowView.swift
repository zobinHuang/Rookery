import AppKit
import ImageIO
import os
import RookeryCore
import SwiftUI

/// How a set of looping pixel animations plays, as `branding/` writes it beside their strips: the frame
/// size in pixels, the frame rate, and each loop's frame count and order.
struct PixelSheetTimeline: Decodable {
    struct LoopTimeline: Decodable {
        let frameCount: Int
        let listSequence: [Int]

        enum CodingKeys: String, CodingKey {
            case frameCount = "frame_count"
            case listSequence = "sequence"
        }
    }

    let frameWidth: Int
    let frameHeight: Int
    let framesPerSecond: Double
    let mapLoops: [String: LoopTimeline]

    enum CodingKeys: String, CodingKey {
        case frameWidth = "frame_width"
        case frameHeight = "frame_height"
        case framesPerSecond = "frames_per_second"
        case mapLoops = "states"
    }
}

/// A set of named looping pixel animations in the app's resources, as `branding/` writes them: a timeline,
/// and one strip of frames per loop at a pixel a grid pixel, which a view scales without smoothing. Each
/// strip is read once and kept.
@MainActor
final class PixelAnimationSheet {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "stage")

    private let timelineName: String
    private let stripPrefix: String
    private var cachedTimeline: PixelSheetTimeline??
    private var mapFrames: [String: [CGImage]] = [:]

    /// - Parameters:
    ///   - timelineName: the timeline's resource name
    ///   - stripPrefix: what each loop's strip is named with before the loop's name
    init(timelineName: String, stripPrefix: String) {
        self.timelineName = timelineName
        self.stripPrefix = stripPrefix
    }

    /// The timeline, or nil when the resources are missing.
    var timeline: PixelSheetTimeline? {
        if let cachedTimeline {
            return cachedTimeline
        }
        var timeline: PixelSheetTimeline?
        if let url = Bundle.main.url(forResource: timelineName, withExtension: "json") {
            do {
                timeline = try JSONDecoder().decode(PixelSheetTimeline.self, from: Data(contentsOf: url))
            } catch {
                Self.logger.error("cannot read the timeline \(self.timelineName, privacy: .public): \(error)")
            }
        }
        cachedTimeline = .some(timeline)
        return timeline
    }

    /// One loop, or nil when the resources lack it.
    func animation(named name: String) -> PixelAnimation? {
        guard let timeline, let loopTimeline = timeline.mapLoops[name] else {
            return nil
        }
        return PixelAnimation(
            framesForScale: { [self] _ in frames(of: name) },
            listSequence: loopTimeline.listSequence,
            framesPerSecond: timeline.framesPerSecond
        )
    }

    private func frames(of name: String) -> [CGImage] {
        if let frames = mapFrames[name] {
            return frames
        }
        var listFrames: [CGImage] = []
        if
            let timeline,
            let url = Bundle.main.url(forResource: stripPrefix + name, withExtension: "png"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let strip = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            listFrames = (0..<(strip.width / max(timeline.frameWidth, 1))).compactMap { frameIndex in
                strip.cropping(to: CGRect(
                    x: frameIndex * timeline.frameWidth,
                    y: 0,
                    width: timeline.frameWidth,
                    height: timeline.frameHeight
                ))
            }
        } else {
            Self.logger.error("cannot read the frames of \(self.stripPrefix + name, privacy: .public)")
        }
        mapFrames[name] = listFrames
        return listFrames
    }
}

/// The crow's art: one loop per agent state, named as roost reports the state.
@MainActor
enum CrowArt {
    static let sheet = PixelAnimationSheet(timelineName: "Crows", stripPrefix: "Crow_")

    /// A state's loop.
    static func animation(for state: AgentState) -> PixelAnimation? {
        sheet.animation(named: state.rawValue)
    }
}

/// Raven's art: the crow facing left, outlined in white, at rest and at work.
@MainActor
enum RavenArt {
    static let sheet = PixelAnimationSheet(timelineName: "Raven", stripPrefix: "Raven_")

    static func animation(isWorking: Bool) -> PixelAnimation? {
        sheet.animation(named: isWorking ? "working" : "idle")
    }
}

/// How large a crow is drawn: always a whole number of screen pixels a pixel of its art, so no pixel is
/// dropped or smeared; on a Retina screen the regular crow is its art pixel for pixel.
enum CrowSize: CGFloat {
    case regular = 32
    case large = 64
}

/// One agent's crow, playing the loop of its state; the agent badge when the art is missing.
struct CrowView: View {
    let state: AgentState
    let crowSize: CrowSize

    init(state: AgentState, size crowSize: CrowSize = .regular) {
        self.state = state
        self.crowSize = crowSize
    }

    var body: some View {
        if let animation = CrowArt.animation(for: state) {
            PixelAnimationLayer(animation: animation, loopName: state.rawValue)
                .frame(width: crowSize.rawValue, height: crowSize.rawValue)
                .accessibilityElement()
                .accessibilityLabel(state.title)
        } else {
            RookeryIconView(.agent)
                .frame(width: crowSize.rawValue, height: crowSize.rawValue)
        }
    }
}

/// Raven, at rest or at work; the agent badge when the art is missing.
struct RavenView: View {
    let isWorking: Bool
    var crowSize = CrowSize.regular

    var body: some View {
        if let animation = RavenArt.animation(isWorking: isWorking) {
            PixelAnimationLayer(animation: animation, loopName: isWorking ? "working" : "idle")
                .frame(width: crowSize.rawValue, height: crowSize.rawValue)
                .accessibilityElement()
                .accessibilityLabel(isWorking ? "Raven, working" : "Raven")
        } else {
            RookeryIconView(.agent)
                .frame(width: crowSize.rawValue, height: crowSize.rawValue)
        }
    }
}

/// The layer that plays a pixel animation, switching loops when the loop named changes.
private struct PixelAnimationLayer: NSViewRepresentable {
    let animation: PixelAnimation
    let loopName: String

    func makeNSView(context: Context) -> PixelAnimationView {
        let view = PixelAnimationView()
        context.coordinator.shownLoopName = loopName
        view.show(animation)
        return view
    }

    func updateNSView(_ nsView: PixelAnimationView, context: Context) {
        guard context.coordinator.shownLoopName != loopName else {
            return
        }
        context.coordinator.shownLoopName = loopName
        nsView.show(animation)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var shownLoopName: String?
    }
}
