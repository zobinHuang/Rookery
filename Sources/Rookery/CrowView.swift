import AppKit
import RookeryCore
import SwiftUI

/// How large a crow is drawn.
enum CrowSize: CGFloat {
    case regular = 32
    case large = 64
}

/// The frames of every crow on screen, drawn by `CrowRig` at the pixel size and in the theme they are shown
/// in, each loop once however many crows play it, off the main thread; the least recently used are let
/// go once more than a handful are kept.
@MainActor
final class CrowFrames {
    static let shared = CrowFrames()
    private static let keptLoopCount = 32

    /// One drawn loop: what it shows, at which side in pixels, in which theme's colors.
    struct Key: Hashable {
        let act: CrowAct
        let side: Int
        let look: CrowLook
    }

    private var mapLoops: [Key: [CGImage]] = [:]
    private var listRecent: [Key] = []
    private var mapPending: [Key: Task<[CGImage], Never>] = [:]

    /// A loop's frames, drawn now or taken from those kept.
    func loop(_ key: Key) async -> [CGImage] {
        if let listFrames = mapLoops[key] {
            touch(key)
            return listFrames
        }
        if let pending = mapPending[key] {
            return await pending.value
        }
        let pending = Task.detached(priority: .utility) { Self.draw(key) }
        mapPending[key] = pending
        let listFrames = await pending.value
        mapPending[key] = nil
        mapLoops[key] = listFrames
        touch(key)
        return listFrames
    }

    /// A theme's colors for its crows.
    static func look(of theme: Theme) -> CrowLook {
        switch theme {
        case .light: .light
        case .dark: .dark
        case .highContrastLight: .highContrastLight
        case .highContrastDark: .highContrastDark
        }
    }

    /// The frame that stands for an act held still, drawn at once.
    func still(_ key: Key) -> CGImage? {
        Self.frame(key.act, at: CrowRig.stillTime(of: key.act), side: key.side, look: key.look)
    }

    private func touch(_ key: Key) {
        listRecent.removeAll { $0 == key }
        listRecent.append(key)
        while listRecent.count > Self.keptLoopCount {
            mapLoops[listRecent.removeFirst()] = nil
        }
    }

    nonisolated private static func draw(_ key: Key) -> [CGImage] {
        let period = CrowRig.period(of: key.act)
        let count = max(1, Int((period * CrowRig.framesPerSecond(of: key.act)).rounded()))
        return (0..<count).compactMap { index in
            frame(key.act, at: period * Double(index) / Double(count), side: key.side, look: key.look)
        }
    }

    nonisolated private static func frame(_ act: CrowAct, at time: Double, side: Int, look: CrowLook) -> CGImage? {
        guard
            side > 0,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        CrowRig.draw(act, at: time, in: context, side: CGFloat(side), look: look)
        return context.makeImage()
    }
}

/// One agent's crow, acting out its state.
struct CrowView: View {
    let state: AgentState
    let crowSize: CrowSize

    init(state: AgentState, size crowSize: CrowSize = .regular) {
        self.state = state
        self.crowSize = crowSize
    }

    var body: some View {
        CrowActView(act: .agent(state))
            .frame(width: crowSize.rawValue, height: crowSize.rawValue)
            .accessibilityElement()
            .accessibilityLabel(state.title)
    }
}

/// Raven, at rest or at work.
struct RavenView: View {
    let isWorking: Bool
    var crowSize = CrowSize.regular

    var body: some View {
        CrowActView(act: isWorking ? .ravenWorking : .ravenIdle)
            .frame(width: crowSize.rawValue, height: crowSize.rawValue)
            .accessibilityElement()
            .accessibilityLabel(isWorking ? "Raven, working" : "Raven")
    }
}

/// A crow in the theme's colors, its act played by the view below.
private struct CrowActView: NSViewRepresentable {
    let act: CrowAct
    @Environment(\.stageTheme) private var theme

    func makeNSView(context: Context) -> CrowAnimationView {
        let view = CrowAnimationView()
        view.show(act, look: CrowFrames.look(of: theme))
        return view
    }

    func updateNSView(_ view: CrowAnimationView, context: Context) {
        view.show(act, look: CrowFrames.look(of: theme))
    }
}

/// A view that plays a crow's loop in one layer: the still frame at once, then, once its frames are drawn,
/// a keyframe animation that steps the layer's contents through them in the render server, so the app does
/// no work while it loops. Drawn again for the screen's scale and the view's size; holds the still frame
/// under Reduce Motion and while the window is hidden.
final class CrowAnimationView: NSView {
    private static let animationKey = "frames"

    private let frameLayer = CALayer()
    private var act: CrowAct?
    private var look = CrowLook.light
    private var shownKey: CrowFrames.Key?
    private var loopTask: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.contentsGravity = .resize
        layer?.addSublayer(frameLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        loopTask?.cancel()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    /// Play an act in a theme's colors; a no-op when it is already playing.
    func show(_ act: CrowAct, look: CrowLook) {
        guard act != self.act || look != self.look else {
            return
        }
        self.act = act
        self.look = look
        play()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
        play()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncVisibility()
                }
            }
        }
        play()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        play()
    }

    /// Show the still frame for this size, scale and theme, then the loop once it is drawn.
    private func play() {
        guard let window, let act, bounds.width > 0 else {
            return
        }
        let scale = window.backingScaleFactor
        let key = CrowFrames.Key(act: act, side: Int((bounds.width * scale).rounded()), look: look)
        guard key != shownKey else {
            return
        }
        shownKey = key
        loopTask?.cancel()
        frameLayer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contentsScale = scale
        frameLayer.contents = CrowFrames.shared.still(key)
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return
        }
        loopTask = Task { [weak self] in
            let listFrames = await CrowFrames.shared.loop(key)
            guard !Task.isCancelled, let self, self.shownKey == key, listFrames.count > 1 else {
                return
            }
            let keyframes = CAKeyframeAnimation(keyPath: "contents")
            keyframes.values = listFrames
            keyframes.calculationMode = .discrete
            keyframes.keyTimes = (0...listFrames.count).map { NSNumber(value: Double($0) / Double(listFrames.count)) }
            keyframes.duration = CrowRig.period(of: key.act)
            keyframes.repeatCount = .infinity
            self.frameLayer.add(keyframes, forKey: Self.animationKey)
            self.syncVisibility()
        }
    }

    /// Hold the loop still while the window is hidden, and let it run again when it shows.
    private func syncVisibility() {
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        frameLayer.speed = isVisible ? 1 : 0
        if isVisible {
            frameLayer.timeOffset = 0
            frameLayer.beginTime = CACurrentMediaTime()
        }
    }
}
