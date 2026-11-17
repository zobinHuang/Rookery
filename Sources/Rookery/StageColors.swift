import AppKit
import SwiftUI

/// The stage's colors, each following the theme: near black in the dark theme, soft greys in the light one,
/// and in the high-contrast themes pure black or white, with every panel outlined in one color and the
/// selected one in another, as the editors' high-contrast themes draw.
enum StageColors {
    /// Behind everything, around the content area.
    static let window = StageColor(
        light: slate(0xF4F5F8),
        dark: slate(0x0A0B0E),
        highContrastLight: .white,
        highContrastDark: .black
    )
    static let sidebar = StageColor(
        light: slate(0xEDEFF3),
        dark: slate(0x0D0F13),
        highContrastLight: .white,
        highContrastDark: .black
    )
    /// The empty content area, before a window covers it.
    static let content = StageColor(
        light: slate(0xE7E9EE),
        dark: slate(0x111318),
        highContrastLight: .white,
        highContrastDark: .black
    )
    static let selectedTab = StageColor(
        light: .white,
        dark: slate(0x1E222B),
        highContrastLight: .white,
        highContrastDark: .black
    )
    static let idleTab = StageColor(
        light: slate(0x1A2233, alpha: 0.05),
        dark: slate(0xC8D2E6, alpha: 0.05),
        highContrastLight: .clear,
        highContrastDark: .clear
    )
    /// Lines between and around panels: faint in the regular themes, the outline in the high-contrast ones.
    static let separator = StageColor(
        light: slate(0x1A2233, alpha: 0.09),
        dark: slate(0xC8D2E6, alpha: 0.08),
        highContrastLight: contrastBorderLight,
        highContrastDark: contrastBorderDark
    )
    /// The outline of a panel that has none in the regular themes, where it is clear.
    static let contrastBorder = StageColor(
        light: .clear,
        dark: .clear,
        highContrastLight: contrastBorderLight,
        highContrastDark: contrastBorderDark
    )
    /// The outline of what is selected, clear in the regular themes, which fill it instead.
    static let contrastActiveBorder = StageColor(
        light: .clear,
        dark: .clear,
        highContrastLight: contrastActiveBorderLight,
        highContrastDark: contrastActiveBorderDark
    )
    /// The chosen segment of a segmented switch or a row of tabs: a raised white tinted with the accent in
    /// the light theme, a lit accent wash in the dark one.
    static let selectedSegment = StageColor(
        light: NSColor.white.blended(withFraction: 0.1, of: .controlAccentColor) ?? .white,
        dark: NSColor.controlAccentColor.withAlphaComponent(0.26),
        highContrastLight: .white,
        highContrastDark: .black
    )
    /// The groove a segmented switch or a row of tabs sits in.
    static let segmentGroove = StageColor(
        light: slate(0x1A2233, alpha: 0.06),
        dark: slate(0xC8D2E6, alpha: 0.07),
        highContrastLight: .white,
        highContrastDark: .black
    )
    /// A button's face, and under the pointer.
    static let control = StageColor(
        light: NSColor(white: 1, alpha: 0.95),
        dark: slate(0xC8D2E6, alpha: 0.1),
        highContrastLight: .white,
        highContrastDark: .black
    )
    static let controlHovered = StageColor(
        light: .white,
        dark: slate(0xC8D2E6, alpha: 0.16),
        highContrastLight: contrastActiveBorderLight.withAlphaComponent(0.12),
        highContrastDark: contrastActiveBorderDark.withAlphaComponent(0.2)
    )
    static let controlBorder = StageColor(
        light: slate(0x1A2233, alpha: 0.12),
        dark: slate(0xC8D2E6, alpha: 0.1),
        highContrastLight: contrastBorderLight,
        highContrastDark: contrastBorderDark
    )
    /// The lines of a calendar's grid: as faint as the separators in the regular themes, and in the
    /// high-contrast ones a quiet grey of the text's color rather than the panels' outline, so the hours
    /// read without caging the events.
    static let gridLine = StageColor(
        light: slate(0x1A2233, alpha: 0.08),
        dark: slate(0xC8D2E6, alpha: 0.07),
        highContrastLight: NSColor(white: 0, alpha: 0.16),
        highContrastDark: NSColor(white: 1, alpha: 0.2)
    )
    /// A sidebar row under the pointer: a faint wash, tinted with the selected outline's color in the
    /// high-contrast themes.
    static let hoveredRow = StageColor(
        light: slate(0x1A2233, alpha: 0.05),
        dark: slate(0xC8D2E6, alpha: 0.055),
        highContrastLight: contrastActiveBorderLight.withAlphaComponent(0.14),
        highContrastDark: contrastActiveBorderDark.withAlphaComponent(0.22)
    )
    /// The square a group's application icons sit in.
    static let tile = StageColor(
        light: NSColor(white: 1, alpha: 0.9),
        dark: slate(0xC8D2E6, alpha: 0.07),
        highContrastLight: .white,
        highContrastDark: .black
    )
    /// A raised panel in the sidebar, such as a mixer track.
    static let card = StageColor(
        light: NSColor(white: 1, alpha: 0.75),
        dark: slate(0xC8D2E6, alpha: 0.05),
        highContrastLight: .white,
        highContrastDark: .black
    )
    /// The groove of a slider or a meter.
    static let groove = StageColor(
        light: slate(0x1A2233, alpha: 0.1),
        dark: slate(0xC8D2E6, alpha: 0.1),
        highContrastLight: NSColor(white: 0, alpha: 0.45),
        highContrastDark: NSColor(white: 1, alpha: 0.45)
    )
    /// Text and symbols, at the three levels of emphasis: the system's own in the regular themes, close to
    /// solid in the high-contrast ones, where even the quietest text must read clearly.
    static let primaryText = StageTextStyle(
        level: .primary,
        highContrastLight: .black,
        highContrastDark: .white
    )
    static let secondaryText = StageTextStyle(
        level: .secondary,
        highContrastLight: NSColor(white: 0, alpha: 0.82),
        highContrastDark: NSColor(white: 1, alpha: 0.85)
    )
    static let tertiaryText = StageTextStyle(
        level: .tertiary,
        highContrastLight: NSColor(white: 0, alpha: 0.66),
        highContrastDark: NSColor(white: 1, alpha: 0.7)
    )
    /// A lit segment of the world clock's display: warm yellow on dark, dark red on light, where it stands
    /// out on the pale sidebar. It follows only light and dark, so it is a plain color the displays take.
    static let clockSegment = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? clockSegmentDark : clockSegmentLight
    })

    /// A grey of the stage's: a neutral leaning faintly blue, so surfaces read cool and clean rather than
    /// flat, from its sRGB hex.
    private static func slate(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static let clockSegmentLight = NSColor(srgbRed: 0.62, green: 0.07, blue: 0.07, alpha: 1)
    private static let clockSegmentDark = NSColor(srgbRed: 1, green: 0.78, blue: 0.12, alpha: 1)
    /// The outlines of the high-contrast themes: deep blue on white, light cyan on black.
    private static let contrastBorderLight = NSColor(srgbRed: 0.06, green: 0.29, blue: 0.52, alpha: 1)
    private static let contrastBorderDark = NSColor(srgbRed: 0.44, green: 0.76, blue: 0.87, alpha: 1)
    /// The selected outlines of the high-contrast themes: bright blue on white, orange on black.
    private static let contrastActiveBorderLight = NSColor(srgbRed: 0, green: 0.42, blue: 0.74, alpha: 1)
    private static let contrastActiveBorderDark = NSColor(srgbRed: 0.95, green: 0.52, blue: 0.09, alpha: 1)
}

/// One of the stage's colors in every theme. As a shape style it takes the theme of the view it fills,
/// from the environment, so a view drawn in a theme other than the one around it, as a preview of it, is
/// drawn in its own.
struct StageColor: ShapeStyle {
    let light: NSColor
    let dark: NSColor
    let highContrastLight: NSColor
    let highContrastDark: NSColor

    /// No color in any theme, for the other side of a choice with one of the stage's colors.
    static let clear = StageColor(
        light: .clear,
        dark: .clear,
        highContrastLight: .clear,
        highContrastDark: .clear
    )

    /// The same color, more transparent in every theme.
    ///
    /// - Parameter opacity: the fraction of the color's own opacity to keep
    func opacity(_ opacity: Double) -> StageColor {
        StageColor(
            light: light.withAlphaComponent(light.alphaComponent * opacity),
            dark: dark.withAlphaComponent(dark.alphaComponent * opacity),
            highContrastLight: highContrastLight.withAlphaComponent(highContrastLight.alphaComponent * opacity),
            highContrastDark: highContrastDark.withAlphaComponent(highContrastDark.alphaComponent * opacity)
        )
    }

    /// The color in a theme, for layers that draw it themselves.
    func color(in theme: Theme) -> NSColor {
        switch theme {
        case .light: light
        case .dark: dark
        case .highContrastLight: highContrastLight
        case .highContrastDark: highContrastDark
        }
    }

    /// The color in the theme of the view it fills.
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(nsColor: color(in: environment.stageTheme)).resolve(in: environment)
    }
}

/// One level of the stage's text: the system's hierarchical style in the regular themes, a fixed color in
/// the high-contrast ones.
struct StageTextStyle: ShapeStyle {
    let level: HierarchicalShapeStyle
    let highContrastLight: NSColor
    let highContrastDark: NSColor

    /// The level's style in the theme of the view it fills.
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        switch environment.stageTheme {
        case .light, .dark: AnyShapeStyle(level)
        case .highContrastLight: AnyShapeStyle(Color(nsColor: highContrastLight))
        case .highContrastDark: AnyShapeStyle(Color(nsColor: highContrastDark))
        }
    }
}

extension EnvironmentValues {
    /// The theme the user chose for Rookery, set at the root of each of its views; nil to follow the system.
    var chosenTheme: Theme? {
        get { self[ChosenThemeKey.self] }
        set { self[ChosenThemeKey.self] = newValue }
    }

    /// The theme Rookery draws in here: the chosen one, else the system's light or dark, at increased
    /// contrast when the system's accessibility setting asks for it.
    var stageTheme: Theme {
        if let chosenTheme {
            return chosenTheme
        }
        switch (colorScheme, colorSchemeContrast) {
        case (.dark, .increased): return .highContrastDark
        case (_, .increased): return .highContrastLight
        case (.dark, _): return .dark
        default: return .light
        }
    }
}

/// Where the environment keeps the chosen theme.
private struct ChosenThemeKey: EnvironmentKey {
    static let defaultValue: Theme? = nil
}
