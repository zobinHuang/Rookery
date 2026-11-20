import AppKit
import RookeryCore
import SwiftUI
import UniformTypeIdentifiers

/// A file an agent presented to the user, as a conversation shows it: its icon, its name and where it is,
/// and, while it is on this Mac, buttons to open it and to show it in the Finder.
struct TranscriptFileCard: View {
    private static let iconSize: CGFloat = 30
    private static let cornerRadius: CGFloat = 10
    /// How often, and how many times, a file not there yet is looked for: the card can show before the
    /// file is written.
    private static let lookInterval: Duration = .milliseconds(500)
    private static let lookLimit = 20

    let entry: TranscriptEntry

    @State private var isPresent = false
    @State private var isHovered = false

    private var url: URL {
        URL(fileURLWithPath: entry.filePath ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            fileLabel
                .frame(maxWidth: .infinity, alignment: .leading)
            if isPresent {
                revealButton
                openButton
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            StageColors.tile.opacity(isHovered ? 1 : 0.75),
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(StageColors.separator, lineWidth: 1)
        )
        .textSelection(.disabled)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = isHovering
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresent)
        .task(id: entry.filePath) {
            await lookForFile()
        }
        .help(url.path)
    }

    private var fileLabel: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .opacity(isPresent ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StageColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isPresent ? Self.shownFolder(of: url) : "Not on this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(StageColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private var revealButton: some View {
        Button {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        } label: {
            RookeryIconView(.folder)
        }
        .fixedSize()
        .help("Show \(url.lastPathComponent) in the Finder")
    }

    private var openButton: some View {
        Button("Open") {
            NSWorkspace.shared.open(url)
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(StageButtonStyle(kind: .prominent))
        .fixedSize()
        .help("Open \(url.lastPathComponent)")
    }

    private var icon: NSImage {
        if isPresent {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    private func lookForFile() async {
        for _ in 0..<Self.lookLimit {
            if FileManager.default.fileExists(atPath: url.path) {
                isPresent = true
                return
            }
            do {
                try await Task.sleep(for: Self.lookInterval)
            } catch {
                return
            }
        }
    }

    /// The folder a file is in, the home folder written `~`.
    static func shownFolder(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// A file or folder offered for a mention: its icon, its name, and the folder it is in.
struct MentionedFileLabel: View {
    let file: MentionedFile
    var iconSize: CGFloat = 16
    var fontSize: CGFloat = 12

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
            .resizable()
            .interpolation(.high)
            .frame(width: iconSize, height: iconSize)
        Text(file.isFolder ? file.name + "/" : file.name)
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
        Spacer(minLength: 4)
        Text(TranscriptFileCard.shownFolder(of: URL(fileURLWithPath: file.path)))
            .font(.system(size: fontSize - 1))
            .lineLimit(1)
            .truncationMode(.head)
            .opacity(0.6)
    }
}


/// A web page an agent opened in Chrome, as a conversation shows it in place of the tool call: its site,
/// its address, and a button to open it.
struct TranscriptPageCard: View {
    private static let cornerRadius: CGFloat = 10

    let entry: TranscriptEntry

    @State private var isHovered = false

    private var url: URL? {
        entry.pageURL.flatMap(URL.init(string:))
    }

    var body: some View {
        HStack(spacing: 10) {
            RookeryIconView(.globe, scale: 1.4)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.host() ?? entry.pageURL ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StageColors.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Opened in Chrome ·")
                        .fixedSize()
                    Text(url.map { $0.path().isEmpty ? "/" : $0.path() } ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 8)
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .help("Open \(url.absoluteString)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            StageColors.tile.opacity(isHovered ? 1 : 0.75),
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(StageColors.separator, lineWidth: 1)
        )
        .textSelection(.disabled)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = isHovering
            }
        }
        .help(entry.pageURL ?? "")
    }
}
