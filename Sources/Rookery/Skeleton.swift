import SwiftUI

/// The shape of content still on its way: a block in the theme's groove with a soft light sweeping across
/// it, still when the user asks for less motion.
struct SkeletonBlock: View {
    private static let sweepDuration = 1.3
    private static let sweepShare: CGFloat = 0.6

    var width: CGFloat?
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 5

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var isMotionReduced

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(StageColors.skeleton)
            .overlay {
                if !isMotionReduced {
                    GeometryReader { proxy in
                        let sweepWidth = proxy.size.width * Self.sweepShare
                        Rectangle()
                            .fill(StageColors.skeletonLight)
                            .mask {
                                LinearGradient(
                                    colors: [.clear, .black, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                            .frame(width: sweepWidth)
                            .offset(x: -sweepWidth + phase * (proxy.size.width + sweepWidth))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.linear(duration: Self.sweepDuration).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

/// Lines of text still on their way, the last one shorter, as a paragraph ends.
struct SkeletonLines: View {
    var count = 3
    var lineHeight: CGFloat = 9
    var spacing: CGFloat = 8
    /// The share of the width the last line takes.
    var lastShare: CGFloat = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                if index == count - 1 {
                    SkeletonBlock(height: lineHeight)
                        .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                            width * lastShare
                        }
                } else {
                    SkeletonBlock(height: lineHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
