import AppKit
import SwiftUI

/// Framing a picture for a person's round photo: the picture under a round window, dragged to place it
/// and zoomed with the slider or a pinch, the part outside the window dimmed. Use Photo hands back the
/// square inside the window, in the picture's points from its bottom left.
struct PhotoCropper: View {
    /// The side of the round window.
    static let windowSide: CGFloat = 200
    /// How far past the window the picture shows, dimmed, on each side.
    private static let margin: CGFloat = 36
    private static let maximumZoom: CGFloat = 5
    private static let dimOpacity = 0.55

    let image: NSImage
    let onDone: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize?
    @State private var pinchStartZoom: CGFloat?

    /// The scale at which the picture's shorter side just fills the window.
    private var baseScale: CGFloat {
        Self.windowSide / min(image.size.width, image.size.height)
    }

    private var shownSize: CGSize {
        CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom)
    }

    var body: some View {
        VStack(spacing: 14) {
            canvas
            HStack(spacing: 10) {
                RookeryIconView(.photo)
                    .foregroundStyle(StageColors.tertiaryText)
                    .scaleEffect(0.8)
                Slider(value: $zoom, in: 1...Self.maximumZoom)
                    .controlSize(.small)
                    .onChange(of: zoom) {
                        offset = clamped(offset)
                    }
                RookeryIconView(.photo)
                    .foregroundStyle(StageColors.tertiaryText)
                    .scaleEffect(1.2)
            }
            .frame(width: Self.windowSide + Self.margin * 2 - 20)
            HStack(spacing: 8) {
                Text("Drag to place, pinch or slide to zoom")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.tertiaryText)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                Button("Use Photo") {
                    onDone(cropRect)
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
            }
        }
    }

    private var canvas: some View {
        let canvasSide = Self.windowSide + Self.margin * 2
        return ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: shownSize.width, height: shownSize.height)
                .offset(offset)
            Color.black
                .opacity(Self.dimOpacity)
                .mask {
                    Rectangle()
                        .overlay {
                            Circle()
                                .frame(width: Self.windowSide, height: Self.windowSide)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                .frame(width: Self.windowSide, height: Self.windowSide)
                .allowsHitTesting(false)
        }
        .frame(width: canvasSide, height: canvasSide)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StageColors.separator)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture.simultaneously(with: pinchGesture))
        .onHover { isInside in
            if isInside {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStartOffset ?? offset
                dragStartOffset = start
                offset = clamped(CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                ))
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? zoom
                pinchStartZoom = start
                zoom = min(max(start * value.magnification, 1), Self.maximumZoom)
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    /// An offset kept so the picture always covers the window.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let reachX = max(0, (shownSize.width - Self.windowSide) / 2)
        let reachY = max(0, (shownSize.height - Self.windowSide) / 2)
        return CGSize(
            width: min(max(proposed.width, -reachX), reachX),
            height: min(max(proposed.height, -reachY), reachY)
        )
    }

    /// The square of the picture inside the window, in its points from its bottom left.
    private var cropRect: CGRect {
        let scale = baseScale * zoom
        let side = Self.windowSide / scale
        let centerX = image.size.width / 2 - offset.width / scale
        let centerYFromTop = image.size.height / 2 - offset.height / scale
        return CGRect(
            x: centerX - side / 2,
            y: image.size.height - centerYFromTop - side / 2,
            width: side,
            height: side
        )
    }
}
