import SwiftUI
import WebKit

/// The browser videos shown in the sidebar, above the world clock, as large as the room allows: stacked one
/// above another while the sidebar has height to spare, then side by side in more columns, each narrower,
/// as more are opened.
struct SidebarPicturesView: View {
    private static let spacing: CGFloat = 6
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 10
    private static let layoutAnimation = Animation.spring(response: 0.38, dampingFraction: 0.84)

    let pictures: BrowserPictures
    let browserTabs: BrowserTabMixer
    /// The width the pictures share.
    let width: CGFloat
    /// The most height the pictures may take.
    let heightBudget: CGFloat

    var body: some View {
        let listPictures = pictures.listPictures
        let usableWidth = width - Self.horizontalPadding * 2
        let tallestAspectRatio = listPictures.map(\.aspectRatio).min() ?? BrowserPictures.defaultAspectRatio
        let columns = Self.columns(
            count: listPictures.count,
            width: usableWidth,
            heightBudget: heightBudget - Self.verticalPadding * 2,
            aspectRatio: tallestAspectRatio
        )
        let tileWidth = (usableWidth - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
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
        .padding(.vertical, Self.verticalPadding)
        .animation(Self.layoutAnimation, value: listPictures.map(\.id))
        .animation(Self.layoutAnimation, value: columns)
    }

    /// The fewest columns, so the largest pictures, whose rows fit the height budget; as many columns as
    /// there are pictures when even one row does not fit.
    private static func columns(count: Int, width: CGFloat, heightBudget: CGFloat, aspectRatio: CGFloat) -> Int {
        guard count > 1 else {
            return 1
        }
        for columns in 1...count {
            let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let rows = (count + columns - 1) / columns
            let height = CGFloat(rows) * tileWidth / aspectRatio + spacing * CGFloat(rows - 1)
            if height <= heightBudget {
                return columns
            }
        }
        return count
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
                RookeryIconView(.pause)
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
                RookeryIconView(picture.isPaused ? .play : .pause)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(picture.isPaused ? "Play" : "Pause")
            Button(action: onClose) {
                RookeryIconView(.close)
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
