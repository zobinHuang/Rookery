import SwiftUI

/// The screen saver: a wireframe Earth seen from orbit, turning beneath the user's text, which sits large and
/// centred in the sky above the horizon and shrinks to fit when it is long. A click anywhere on it closes it.
/// Only the stars and the grid redraw as it turns, on the GPU; the rest is drawn once. The scene holds still
/// when Reduce Motion is on.
struct ScreenSaverView: View {
    private static let margin: CGFloat = 48
    /// How far long text shrinks to fit before it is cut short.
    private static let minimumScale: CGFloat = 0.2
    private static let captionTop = Color.white
    private static let captionBottom = Color(red: 1, green: 0.62, blue: 0.88)
    private static let captionGlow = Color(red: 1, green: 0.18, blue: 0.71)
    private static let captionGlowRadius: CGFloat = 18

    let text: String
    let textSize: Double
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var isReducingMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Canvas { context, size in OrbitScene.drawBackdrop(in: context, size: size) }
                TimelineView(.animation(paused: isReducingMotion)) { timeline in
                    Canvas { context, size in
                        OrbitScene.drawMotion(
                            in: context,
                            size: size,
                            time: timeline.date.timeIntervalSinceReferenceDate
                        )
                    }
                }
                .drawingGroup()
                .blendMode(.plusLighter)
                Canvas { context, size in OrbitScene.drawForeground(in: context, size: size) }
                caption
                    .frame(
                        width: proxy.size.width,
                        height: max(proxy.size.height - OrbitScene.horizonRadius(in: proxy.size), 0)
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
    }

    private var caption: some View {
        Text(text)
            .font(.system(size: textSize, weight: .semibold))
            .fontWidth(.expanded)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(Self.minimumScale)
            .foregroundStyle(LinearGradient(
                colors: [Self.captionTop, Self.captionBottom],
                startPoint: .top,
                endPoint: .bottom
            ))
            .shadow(color: Self.captionGlow, radius: Self.captionGlowRadius)
            .padding(Self.margin)
    }
}
