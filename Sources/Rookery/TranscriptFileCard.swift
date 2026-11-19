import AppKit
import RookeryCore
import SwiftUI
import UniformTypeIdentifiers

/// A file an agent wrote or changed, as a conversation shows it in place of the tool call: its icon, its
/// name, what was done and where it is, and, while it is on this Mac, buttons to open it and to show it in
/// the Finder.
struct TranscriptFileCard: View {
    private static let iconSize: CGFloat = 30
    private static let cornerRadius: CGFloat = 10
    /// How often, and how many times, a file not there yet is looked for: the card shows as the tool
    /// call starts, before the file is written.
    private static let lookInterval: Duration = .milliseconds(500)
    private static let lookLimit = 20

    let entry: TranscriptEntry

    @State private var isPresent = false
    @State private var isHovered = false

    private var url: URL {
        URL(fileURLWithPath: entry.filePath ?? "")
    }

    private var verb: String {
        guard case .tool(let name) = entry.role else {
            return "Changed"
        }
        return TranscriptEntry.setCreatingTools.contains(name) ? "Wrote" : "Edited"
    }

    var body: some View {
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
                HStack(spacing: 4) {
                    Text("\(verb) ·")
                        .fixedSize()
                    Text(isPresent ? Self.shownFolder(of: url) : "not on this Mac")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.system(size: 11))
                .foregroundStyle(StageColors.secondaryText)
            }
            Spacer(minLength: 8)
            if isPresent {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(StageButtonStyle(kind: .prominent))
                .help("Open \(url.lastPathComponent)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    RookeryIconView(.folder)
                        .foregroundStyle(StageColors.secondaryText)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .transition(.opacity)
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
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = isHovering
            }
        }
        .onTapGesture(count: 2) {
            if isPresent {
                NSWorkspace.shared.open(url)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresent)
        .task(id: entry.filePath) {
            await lookForFile()
        }
        .help(url.path)
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

