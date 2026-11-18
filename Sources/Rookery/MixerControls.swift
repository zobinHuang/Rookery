import AppKit
import SwiftUI

/// A slim horizontal slider drawn for the mixer: a groove filled from its rest value to the current one,
/// and a round thumb. Double-clicking puts it back at its rest value.
struct MixerSlider: View {
    private static let grooveHeight: CGFloat = 4
    private static let thumbDiameter: CGFloat = 13

    @Binding var value: Float
    let range: ClosedRange<Float>
    /// The value it rests at, which the fill starts from and a double-click returns to.
    let restValue: Float
    var tint: Color = .accentColor
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = width - Self.thumbDiameter
            let thumbX = Self.thumbDiameter / 2 + usable * fraction(of: value)
            let restX = Self.thumbDiameter / 2 + usable * fraction(of: restValue)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StageColors.groove)
                    .frame(height: Self.grooveHeight)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: abs(thumbX - restX) + Self.grooveHeight, height: Self.grooveHeight)
                    .offset(x: min(thumbX, restX) - Self.grooveHeight / 2)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: isDragging ? 3 : 1.5, y: 0.5)
                    .overlay {
                        Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
                    }
                    .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(x: thumbX - Self.thumbDiameter / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let share = (drag.location.x - Self.thumbDiameter / 2) / max(usable, 1)
                        value = self.value(at: share)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                value = restValue
            })
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragging)
        }
        .frame(height: Self.thumbDiameter + 4)
    }

    private func fraction(of value: Float) -> CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// The value at a share of the groove, snapping onto the rest value when close to it.
    private func value(at share: CGFloat) -> Float {
        let clampedShare = Float(min(max(share, 0), 1))
        let raw = range.lowerBound + clampedShare * (range.upperBound - range.lowerBound)
        let snapDistance = (range.upperBound - range.lowerBound) * 0.025
        return abs(raw - restValue) < snapDistance ? restValue : raw
    }
}

/// A vertical slider for one equalizer band, filled from its zero line.
struct EqualizerBandSlider: View {
    private static let grooveWidth: CGFloat = 3
    private static let thumbSize = CGSize(width: 12, height: 6)

    @Binding var gain: Float
    let range: ClosedRange<Float>
    let isEnabled: Bool
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let usable = height - Self.thumbSize.height
            let thumbY = Self.thumbSize.height / 2 + usable * (1 - fraction(of: gain))
            let zeroY = Self.thumbSize.height / 2 + usable * (1 - fraction(of: 0))
            let tint = isEnabled ? Color.accentColor : Color.secondary
            ZStack(alignment: .top) {
                Capsule()
                    .fill(StageColors.groove)
                    .frame(width: Self.grooveWidth)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: Self.grooveWidth, height: abs(thumbY - zeroY) + Self.grooveWidth)
                    .offset(y: min(thumbY, zeroY) - Self.grooveWidth / 2)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: isDragging ? 2.5 : 1, y: 0.5)
                    .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(y: thumbY - Self.thumbSize.height / 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let share = 1 - (drag.location.y - Self.thumbSize.height / 2) / max(usable, 1)
                        let clampedShare = Float(min(max(share, 0), 1))
                        let raw = range.lowerBound + clampedShare * (range.upperBound - range.lowerBound)
                        // Whole decibels, settling on zero when near it.
                        gain = abs(raw) < 0.6 ? 0 : raw.rounded()
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                gain = 0
            })
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragging)
        }
    }

    private func fraction(of value: Float) -> CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// The meters on screen, drawn again each time levels are read, outside SwiftUI: levels change thirty times
/// a second, and as SwiftUI state they laid out and drew the whole stage window each time.
@MainActor
final class MeterTicker {
    private let setMeterViews = NSHashTable<StereoMeterView>.weakObjects()

    func add(_ view: StereoMeterView) {
        setMeterViews.add(view)
    }

    /// Draw every meter shown with its latest levels.
    func tick() {
        for view in setMeterViews.allObjects {
            view.refresh()
        }
    }
}

/// Where the environment keeps the mixer's meter ticker, for the meters deep in its strips.
private struct MeterTickerKey: EnvironmentKey {
    static let defaultValue: MeterTicker? = nil
}

extension EnvironmentValues {
    /// The ticker that draws the meters again, set at the root of the mixer.
    var meterTicker: MeterTicker? {
        get { self[MeterTickerKey.self] }
        set { self[MeterTickerKey.self] = newValue }
    }
}

/// A stereo meter that reads its levels itself whenever the mixer's ticker says they changed, drawn in
/// layers of its own, so a new level never touches the views around it.
struct LiveStereoMeter: NSViewRepresentable {
    let readLevels: () -> MixerLevels

    func makeNSView(context: Context) -> StereoMeterView {
        let view = StereoMeterView()
        context.environment.meterTicker?.add(view)
        return view
    }

    func updateNSView(_ view: StereoMeterView, context: Context) {
        view.readLevels = readLevels
        view.grooveColor = StageColors.groove.color(in: context.environment.stageTheme)
        view.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StereoMeterView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? StereoMeterView.defaultWidth, height: StereoMeterView.height)
    }
}

/// Two thin bars, left channel over right, lit green through amber to red as the sound gets louder.
final class StereoMeterView: NSView {
    private static let barHeight: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    static let height = barHeight * 2 + barSpacing
    static let defaultWidth: CGFloat = 30
    /// The quietest level shown, in decibels; anything quieter leaves the bar empty.
    private static let floorDecibels: Float = -54
    private static let stepDuration: CFTimeInterval = 1.0 / 30

    var readLevels: () -> MixerLevels = { MixerLevels() }
    var grooveColor = NSColor.quaternaryLabelColor {
        didSet {
            if grooveColor != oldValue {
                applyColors()
            }
        }
    }

    private var listGrooves: [CALayer] = []
    private var listFills: [CAGradientLayer] = []
    private var listMasks: [CALayer] = []
    private var levels = MixerLevels()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<2 {
            let groove = CALayer()
            let fill = CAGradientLayer()
            fill.startPoint = CGPoint(x: 0, y: 0.5)
            fill.endPoint = CGPoint(x: 1, y: 0.5)
            fill.locations = [0, 0.65, 0.85, 1]
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.anchorPoint = .zero
            fill.mask = mask
            layer?.addSublayer(groove)
            layer?.addSublayer(fill)
            listGrooves.append(groove)
            listFills.append(fill)
            listMasks.append(mask)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<2 {
            let frame = CGRect(
                x: 0,
                y: CGFloat(index) * (Self.barHeight + Self.barSpacing),
                width: bounds.width,
                height: Self.barHeight
            )
            listGrooves[index].frame = frame
            listGrooves[index].cornerRadius = Self.barHeight / 2
            listFills[index].frame = frame
        }
        placeMasks()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Read the levels and move the bars to them, while the meter can be seen.
    func refresh() {
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else {
            return
        }
        show(readLevels())
    }

    /// Move the bars to levels, gliding there over one reading.
    func show(_ newLevels: MixerLevels) {
        guard newLevels != levels else {
            return
        }
        levels = newLevels
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.stepDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        placeMasks()
        CATransaction.commit()
    }

    private func placeMasks() {
        for (index, level) in [levels.left, levels.right].enumerated() {
            let width = bounds.width * Self.share(of: level)
            listMasks[index].frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: Self.barHeight
            )
            listMasks[index].cornerRadius = min(Self.barHeight, width) / 2
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let listStops = [NSColor.systemGreen, .systemGreen, .systemYellow, .systemRed].map(\.cgColor)
            for index in 0..<2 {
                listGrooves[index].backgroundColor = grooveColor.cgColor
                listFills[index].colors = listStops
            }
        }
    }

    /// How much of the bar a level fills, on a decibel scale so quiet sound still shows.
    private static func share(of level: Float) -> CGFloat {
        guard level > 0 else {
            return 0
        }
        let decibels = 20 * log10(level)
        return CGFloat(min(max((decibels - floorDecibels) / -floorDecibels, 0), 1))
    }
}

/// A small capsule that switches a setting on and off, lit in the accent color while on.
struct MixerChip: View {
    let title: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(StageColors.secondaryText))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(isHovered ? StageColors.hoveredRow : StageColors.groove.opacity(0.6)))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .help(help)
    }
}

/// A small on/off switch drawn in the accent color, which stays colored while the stage is not the key
/// window, unlike the system switch.
struct MixerSwitch: View {
    private static let size = CGSize(width: 30, height: 17)
    private static let inset: CGFloat = 2

    @Binding var isOn: Bool
    let help: String

    var body: some View {
        let knobDiameter = Self.size.height - Self.inset * 2
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(StageColors.groove))
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: knobDiameter, height: knobDiameter)
                        .padding(Self.inset)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isOn)
        .help(help)
    }
}

/// The round button that mutes a track in one click, lit red while the track is muted.
struct MixerMuteButton: View {
    private static let diameter: CGFloat = 22

    let isMuted: Bool
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RookeryIconView(isMuted ? .speakerOff : .speaker)
                .foregroundStyle(isMuted ? AnyShapeStyle(Color.red) : AnyShapeStyle(StageColors.secondaryText))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.diameter, height: Self.diameter)
                .background {
                    Circle()
                        .fill(isMuted ? AnyShapeStyle(Color.red.opacity(0.16)) : AnyShapeStyle(isHovered ? StageColors.hoveredRow : .clear))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isMuted)
        .help(help)
    }
}

/// A capsule naming an equalizer preset, lit in the accent color while the equalizer is set to it.
struct EqualizerPresetChip: View {
    let title: String
    let symbol: RookeryIcon
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RookeryLabel(title, icon: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(StageColors.secondaryText))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background {
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(isHovered ? StageColors.hoveredRow : StageColors.groove.opacity(0.6)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .help(isSelected ? "Set the equalizer back to flat" : "Set the equalizer to \(title)")
    }
}
