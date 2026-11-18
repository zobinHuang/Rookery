import AppKit
import os
import SwiftUI

/// Rookery's interface icons. A badge keeps the logo's colors, a dark body in a white outline; a glyph is
/// one color, tinted like text. The crow's head and the crow are the crow's pixel art; the rest are drawn.
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
    case camera
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
    case photo
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
    case chevronLeft = "chevron-left"
    case calendar
    case mail
    case sidebarRight = "sidebar-right"
    case video
    case expand
    case envelopeOpen = "envelope-open"
    case flag
    case sliders
    case draft

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

    /// Whether the icon is the crow's own pixel art, as the logo is, rather than a drawn shape.
    var isPixelArt: Bool {
        self == .agent || self == .crow
    }

    /// The icon's side in points at scale 1.
    var size: CGFloat {
        isBadge ? Self.badgeSize : Self.glyphSize
    }

    /// The shape an icon that is not pixel art is drawn from.
    var symbolName: String {
        switch self {
        case .agent, .crow: "bird.fill"
        case .board: "point.3.connected.trianglepath.dotted"
        case .command: "command"
        case .crown: "crown.fill"
        case .gauge: "gauge.with.dots.needle.67percent"
        case .gear: "gearshape.fill"
        case .globe: "globe.asia.australia.fill"
        case .hand: "hand.point.up.left.fill"
        case .machine: "desktopcomputer"
        case .memory: "brain.head.profile.fill"
        case .mixer: "slider.vertical.3"
        case .moon: "moon.fill"
        case .newStage: "macwindow.badge.plus"
        case .person: "person.fill"
        case .playbook: "book.closed.fill"
        case .roost: "server.rack"
        case .screenSaver: "sparkles.tv.fill"
        case .sidebar: "sidebar.left"
        case .skill: "wrench.adjustable.fill"
        case .sparkles: "sparkles"
        case .sun: "sun.max.fill"
        case .windows: "square.grid.2x2.fill"
        case .appPlaceholder: "app.dashed"
        case .arrowLeft: "arrow.left"
        case .arrowRight: "arrow.right"
        case .arrowUp: "arrow.up"
        case .book: "book"
        case .branch: "arrow.triangle.branch"
        case .bubble: "text.bubble"
        case .photo: "photo"
        case .camera: "camera.fill"
        case .check: "checkmark.circle.fill"
        case .chevronDown: "chevron.down"
        case .chevronRight: "chevron.right"
        case .chip: "cpu"
        case .clear: "clear"
        case .clock: "clock.fill"
        case .close: "xmark"
        case .copy: "doc.on.doc"
        case .drop: "arrow.down.circle.fill"
        case .ellipsis: "ellipsis"
        case .failed: "xmark.octagon.fill"
        case .filter: "line.3.horizontal.decrease"
        case .folder: "folder"
        case .hourglass: "hourglass"
        case .link: "link"
        case .lock: "lock.fill"
        case .minus: "minus.circle.fill"
        case .offline: "antenna.radiowaves.left.and.right.slash"
        case .pause: "pause.fill"
        case .pin: "mappin.circle.fill"
        case .pip: "pip.fill"
        case .pipEnter: "pip.enter"
        case .play: "play.fill"
        case .plus: "plus"
        case .radio: "dot.radiowaves.left.and.right"
        case .refresh: "arrow.clockwise"
        case .release: "arrow.up.forward.square"
        case .search: "magnifyingglass"
        case .send: "paperplane"
        case .speaker: "speaker.wave.2.fill"
        case .speakerLow: "speaker.wave.1.fill"
        case .speakerOff: "speaker.slash.fill"
        case .stop: "stop.fill"
        case .terminal: "terminal"
        case .tool: "wrench.and.screwdriver"
        case .undo: "arrow.uturn.backward"
        case .unlock: "lock.open"
        case .warning: "exclamationmark.triangle.fill"
        case .width: "arrow.left.and.right"
        case .window: "macwindow"
        case .chevronLeft: "chevron.left"
        case .calendar: "calendar"
        case .mail: "envelope"
        case .sidebarRight: "sidebar.right"
        case .video: "video.fill"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .envelopeOpen: "envelope.open"
        case .flag: "flag.fill"
        case .sliders: "slider.vertical.3"
        case .draft: "square.and.pencil"
        }
    }

    /// The badge for a kind of resource roost manages.
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

/// The icons as AppKit images: the crow's pixel art from the app's resources, read once each, and the
/// drawn icons as template symbols.
@MainActor
enum RookeryIconArt {
    private static let logger = Logger(subsystem: "io.github.zobinhuang.rookery", category: "stage")
    private static let directory = "Icons"
    private static var mapImages: [RookeryIcon: NSImage] = [:]

    /// The icon's image at scale 1, a template unless it is a badge's pixel art; empty when it is missing.
    static func image(_ icon: RookeryIcon) -> NSImage {
        if let image = mapImages[icon] {
            return image
        }
        var image = NSImage(size: NSSize(width: icon.size, height: icon.size))
        if icon.isPixelArt {
            if
                let url = Bundle.main.url(forResource: icon.rawValue, withExtension: "png", subdirectory: directory),
                let loaded = NSImage(contentsOf: url)
            {
                image = loaded
                image.size = NSSize(width: icon.size, height: icon.size)
            } else {
                logger.error("no icon named \(icon.rawValue)")
            }
            image.isTemplate = !icon.isBadge
        } else if let symbol = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: icon.size * 0.8, weight: .semibold))
        {
            image = symbol
            image.isTemplate = true
        }
        mapImages[icon] = image
        return image
    }
}

/// One of Rookery's icons. The crow's are its pixel art, never smoothed. The rest are drawn at the screen's
/// full resolution: a badge in the logo's colors, a dark body lit from the top left inside a white
/// outline, so it reads on light and dark alike; a glyph in one color, the text's.
struct RookeryIconView: View {
    /// The badge's outline, white as the logo's.
    private static let outlineColor = Color.white
    private static let bodyGradient = LinearGradient(
        colors: [Color(white: 0.42), Color(white: 0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// The outline's width against the badge's side.
    private static let outlineFraction: CGFloat = 1 / 16
    /// The directions the outline is drawn out in.
    private static let listOutlineDirections: [CGSize] = [
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0), CGSize(width: 0, height: -1), CGSize(width: 0, height: 1),
        CGSize(width: -0.7, height: -0.7), CGSize(width: 0.7, height: -0.7), CGSize(width: -0.7, height: 0.7), CGSize(width: 0.7, height: 0.7),
    ]

    let icon: RookeryIcon
    /// How many times its usual size it is drawn: 1 in the interface, 2 or 3 for a large mark.
    var scale: CGFloat = 1

    init(_ icon: RookeryIcon, scale: CGFloat = 1) {
        self.icon = icon
        self.scale = scale
    }

    var body: some View {
        let side = icon.size * scale
        Group {
            if icon.isPixelArt {
                Image(nsImage: RookeryIconArt.image(icon))
                    .renderingMode(icon.isBadge ? .original : .template)
                    .interpolation(.none)
                    .resizable()
            } else if icon.isBadge {
                badge(side: side)
            } else {
                Image(systemName: icon.symbolName)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .padding(side * 0.06)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func badge(side: CGFloat) -> some View {
        let outline = max(side * Self.outlineFraction, 1)
        let symbol = Image(systemName: icon.symbolName)
            .resizable()
            .scaledToFit()
            .fontWeight(.bold)
        return ZStack {
            ForEach(Self.listOutlineDirections.indices, id: \.self) { index in
                let direction = Self.listOutlineDirections[index]
                symbol
                    .foregroundStyle(Self.outlineColor)
                    .offset(x: direction.width * outline, y: direction.height * outline)
            }
            symbol
                .foregroundStyle(Self.bodyGradient)
        }
        .padding(outline)
    }
}

/// A label with an icon before its title, as `Label` lays out a symbol.
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

/// A short fact set apart in a thin rounded box, as a row of them stands in for words joined by dots: a
/// state, a repository, a branch. A tint colors one that calls for attention.
struct InfoTag: View {
    let text: String
    var tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(StageColors.secondaryText))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (tint ?? Color.gray).opacity(0.1),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.35)) } ?? AnyShapeStyle(StageColors.separator))
            }
    }
}
