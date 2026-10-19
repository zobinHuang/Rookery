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

/// Two thin bars, left channel over right, lit green through amber to red as the sound gets louder.
struct StereoMeter: View {
    private static let barHeight: CGFloat = 3
    /// The quietest level shown, in decibels; anything quieter leaves the bar empty.
    private static let floorDecibels: Float = -54

    let levels: MixerLevels

    var body: some View {
        VStack(spacing: 2) {
            bar(level: levels.left)
            bar(level: levels.right)
        }
        .animation(.linear(duration: 1 / 30), value: levels)
    }

    private func bar(level: Float) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StageColors.groove)
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .green, location: 0),
                            .init(color: .green, location: 0.65),
                            .init(color: .yellow, location: 0.85),
                            .init(color: .red, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: proxy.size.width * share(of: level))
                    }
            }
        }
        .frame(height: Self.barHeight)
    }

    /// How much of the bar a level fills, on a decibel scale so quiet sound still shows.
    private func share(of level: Float) -> CGFloat {
        guard level > 0 else {
            return 0
        }
        let decibels = 20 * log10(level)
        return CGFloat(min(max((decibels - Self.floorDecibels) / -Self.floorDecibels, 0), 1))
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
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
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
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isMuted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.diameter, height: Self.diameter)
                .background {
                    Circle()
                        .fill(isMuted ? AnyShapeStyle(Color.red.opacity(0.16)) : AnyShapeStyle(isHovered ? StageColors.hoveredRow : Color.clear))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isMuted)
        .help(help)
    }
}
