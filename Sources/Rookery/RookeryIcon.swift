import AppKit
import os
import SwiftUI

/// Rookery's interface icons, drawn by `branding/` in the logo's pixel style, one point a pixel. A badge
/// keeps the logo's colors, a dark silhouette in a yellow outline; a glyph is one color, tinted like text.
enum RookeryIcon: String, CaseIterable {
    // Badges, 16 pixels square.
    case agent
    case board
    case command
    case crown
    case gauge
    case gear
    case globe
    case hand
    case machine
    case memory
    case mixer
    case moon
    case newStage = "new-stage"
    case person
    case playbook
    case roost
    case screenSaver = "screen-saver"
    case sidebar
    case skill
    case sparkles
    case sun
    case windows

    // Glyphs, 12 pixels square.
    case appPlaceholder = "app-placeholder"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case arrowUp = "arrow-up"
    case book
    case branch
    case bubble
    case check
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case chip
    case clear
    case clock
    case close
    case copy
    case crow
    case drop
    case ellipsis
    case failed
    case filter
    case folder
    case hourglass
    case link
    case lock
    case minus
    case offline
    case pause
    case pin
    case pip
    case pipEnter = "pip-enter"
    case play
    case plus
    case radio
    case refresh
    case release
    case search
    case send
    case speaker
    case speakerLow = "speaker-low"
    case speakerOff = "speaker-off"
    case stop
    case terminal
    case tool
    case undo
    case unlock
    case warning
    case width
    case window

    private static let setBadges: Set<RookeryIcon> = [
        .agent, .board, .command, .crown, .gauge, .gear, .globe, .hand, .machine, .memory, .mixer, .moon,
        .newStage, .person, .playbook, .roost, .screenSaver, .sidebar, .skill, .sparkles, .sun, .windows,
    ]
    private static let badgeSize: CGFloat = 16
    private static let glyphSize: CGFloat = 12

    /// Whether the icon keeps its own colors rather than taking the text's.
    var isBadge: Bool {
        Self.setBadges.contains(self)
    }

    /// The icon's side in points at one point a pixel.
    var size: CGFloat {
        isBadge ? Self.badgeSize : Self.glyphSize
    }

    /// The badge for a kind of resource rookd manages.
    static func kind(_ kind: String) -> RookeryIcon {
        switch kind {
        case "agent": .agent
        case "skill": .skill
        case "playbook": .playbook
        case "memory": .memory
        case "rook": .machine
        case "person": .person
        default: .board
        }
    }
}

/// The icons' images in the app's resources, read once each.
@MainActor
enum RookeryIconArt {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "stage")
    private static let directory = "Icons"
    private static var mapImages: [RookeryIcon: NSImage] = [:]

    /// The icon's image, a template for a glyph; an empty image when the resource is missing.
    static func image(_ icon: RookeryIcon) -> NSImage {
        if let image = mapImages[icon] {
            return image
        }
        let image: NSImage
        if
            let url = Bundle.main.url(forResource: icon.rawValue, withExtension: "png", subdirectory: directory),
            let loaded = NSImage(contentsOf: url)
        {
            image = loaded
            image.size = NSSize(width: icon.size, height: icon.size)
        } else {
            logger.error("no icon named \(icon.rawValue)")
            image = NSImage(size: NSSize(width: icon.size, height: icon.size))
        }
        image.isTemplate = !icon.isBadge
        mapImages[icon] = image
        return image
    }

    /// The menu bar's mark: the crow's head as a one-color template, which the menu bar tints.
    static func menuBarImage() -> NSImage {
        guard let image = image(.agent).copy() as? NSImage else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }
}

/// An icon at a whole number of points a pixel, never smoothed; a glyph takes the foreground style.
struct RookeryIconView: View {
    let icon: RookeryIcon
    /// Points a pixel: 1 for the interface, 2 for a large mark.
    var scale: CGFloat = 1

    init(_ icon: RookeryIcon, scale: CGFloat = 1) {
        self.icon = icon
        self.scale = scale
    }

    var body: some View {
        Image(nsImage: RookeryIconArt.image(icon))
            .renderingMode(icon.isBadge ? .original : .template)
            .interpolation(.none)
            .resizable()
            .frame(width: icon.size * scale, height: icon.size * scale)
            .accessibilityHidden(true)
    }
}

/// A label with a pixel icon before its title, as `Label` lays out a symbol.
struct RookeryLabel: View {
    let title: String
    let icon: RookeryIcon
    var spacing: CGFloat = 6

    init(_ title: String, icon: RookeryIcon, spacing: CGFloat = 6) {
        self.title = title
        self.icon = icon
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            RookeryIconView(icon)
            Text(title)
        }
    }
}
