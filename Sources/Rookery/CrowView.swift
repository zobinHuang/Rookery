import AppKit
import ImageIO
import os
import RookeryCore
import SwiftUI

/// How the crow's states play, as `branding/` writes it beside their strips: the frame size in pixels, the
/// frame rate, and each state's frame count and order.
struct CrowTimeline: Decodable {
    struct StateTimeline: Decodable {
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
    let mapStates: [String: StateTimeline]

    enum CodingKeys: String, CodingKey {
        case frameWidth = "frame_width"
        case frameHeight = "frame_height"
        case framesPerSecond = "frames_per_second"
        case mapStates = "states"
    }
}

/// The crow's art in the app's resources: one strip of frames per state at a pixel a grid pixel, which the
/// view scales without smoothing. Each strip is read once and kept.
@MainActor
enum CrowArt {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "agents")
    private static let timelineName = "Crows"
    private static let stripPrefix = "Crow_"
    private static var cachedTimeline: CrowTimeline??
    private static var mapFrames: [AgentState: [CGImage]] = [:]

    /// The timeline, or nil when the resources are missing.
    static var timeline: CrowTimeline? {
        if let cachedTimeline {
            return cachedTimeline
        }
        var timeline: CrowTimeline?
        if let url = Bundle.main.url(forResource: timelineName, withExtension: "json") {
            do {
                timeline = try JSONDecoder().decode(CrowTimeline.self, from: Data(contentsOf: url))
            } catch {
                logger.error("cannot read the crows' timeline: \(error)")
            }
        }
        cachedTimeline = .some(timeline)
        return timeline
    }

    /// A state's loop.
    static func animation(for state: AgentState) -> PixelAnimation? {
        guard let timeline, let stateTimeline = timeline.mapStates[state.rawValue] else {
            return nil
        }
        return PixelAnimation(
            framesForScale: { _ in frames(for: state) },
            listSequence: stateTimeline.listSequence,
            framesPerSecond: timeline.framesPerSecond
        )
    }

    private static func frames(for state: AgentState) -> [CGImage] {
        if let frames = mapFrames[state] {
            return frames
        }
        var listFrames: [CGImage] = []
        if
            let timeline,
            let url = Bundle.main.url(forResource: stripPrefix + state.rawValue, withExtension: "png"),
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
            logger.error("cannot read the crow's frames for \(state.rawValue)")
        }
        mapFrames[state] = listFrames
        return listFrames
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

    private var size: CGFloat {
        crowSize.rawValue
    }

    var body: some View {
        if CrowArt.animation(for: state) != nil {
            CrowLayer(state: state)
                .frame(width: size, height: size)
                .accessibilityElement()
                .accessibilityLabel(state.title)
        } else {
            PixelIconView(.agent)
                .frame(width: size, height: size)
        }
    }
}

/// The layer behind `CrowView`, switching loops when the state changes.
private struct CrowLayer: NSViewRepresentable {
    let state: AgentState

    func makeNSView(context: Context) -> PixelAnimationView {
        let view = PixelAnimationView()
        context.coordinator.shownState = state
        if let animation = CrowArt.animation(for: state) {
            view.show(animation)
        }
        return view
    }

    func updateNSView(_ nsView: PixelAnimationView, context: Context) {
        guard context.coordinator.shownState != state, let animation = CrowArt.animation(for: state) else {
            return
        }
        context.coordinator.shownState = state
        nsView.show(animation)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var shownState: AgentState?
    }
}
