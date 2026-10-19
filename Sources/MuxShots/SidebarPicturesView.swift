import SwiftUI
import WebKit

/// The browser videos shown in the sidebar, above the world clock: side by side, sharing the sidebar's
/// width evenly so each gets narrower as more are opened, and wrapping onto a new row past a few.
struct SidebarPicturesView: View {
    private static let maxColumns = 4
    private static let spacing: CGFloat = 6
    private static let horizontalPadding: CGFloat = 10
    private static let layoutAnimation = Animation.spring(response: 0.38, dampingFraction: 0.84)

    let pictures: BrowserPictures
    let browserTabs: BrowserTabMixer
    /// The width the pictures share.
    let width: CGFloat

    var body: some View {
        let listPictures = pictures.listPictures
        let columns = min(max(listPictures.count, 1), Self.maxColumns)
        let tileWidth = (width - Self.horizontalPadding * 2 - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let listRows = stride(from: 0, to: listPictures.count, by: columns).map { start in
            Array(listPictures[start..<min(start + columns, listPictures.count)])
        }
        VStack(spacing: Self.spacing) {
            ForEach(listRows.indices, id: \.self) { rowIndex in
                HStack(alignment: .center, spacing: Self.spacing) {
                    ForEach(listRows[rowIndex]) { picture in
                        SidebarPictureTile(
                            picture: picture,
                            width: tileWidth,
                            onFocus: { browserTabs.focus(picture.key) },
                            onClose: { browserTabs.closePicture(picture.key) },
                            onPlay: { isPlaying in browserTabs.playPicture(picture.key, isPlaying: isPlaying) }
                        )
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 10)
        .animation(Self.layoutAnimation, value: listPictures.map(\.id))
    }
}

/// One video in the sidebar: its stream playing, and on hover its title, play or pause and close.
/// Clicking it brings its tab to the front.
private struct SidebarPictureTile: View {
    private static let cornerRadius: CGFloat = 8
    /// Below these widths the tile is too narrow to show its title or a large play button.
    private static let titleMinimumWidth: CGFloat = 96
    private static let playMinimumWidth: CGFloat = 56

    let picture: BrowserPicture
    let width: CGFloat
    let onFocus: () -> Void
    let onClose: () -> Void
    let onPlay: (Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        let height = width / picture.aspectRatio
        ZStack {
            Color.black
            PictureVideoView(receiver: picture.receiver)
                .allowsHitTesting(false)
                .opacity(picture.isStreaming ? 1 : 0)
            if !picture.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            if isHovered {
                hoverOverlay
                    .transition(.opacity)
            } else if picture.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(StageColors.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .onHover { isInside in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = isInside
            }
        }
        .animation(.easeInOut(duration: 0.2), value: picture.aspectRatio)
        .help(picture.title)
    }

    private var hoverOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            Button {
                onPlay(picture.isPaused)
            } label: {
                Image(systemName: picture.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: width >= Self.playMinimumWidth ? 16 : 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(picture.isPaused ? "Play" : "Pause")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop showing this video")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(4)
            if width >= Self.titleMinimumWidth {
                Text(picture.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
        }
    }
}

/// The web view a video's stream plays in, inside the tile.
private struct PictureVideoView: NSViewRepresentable {
    let receiver: PictureReceiver

    func makeNSView(context: Context) -> WKWebView {
        receiver.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
