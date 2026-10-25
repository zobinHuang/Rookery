import AppKit
import SwiftUI

/// The stage's colors, each following the light or dark theme: near black in the dark theme, soft greys in
/// the light one.
enum StageColors {
    /// Behind everything, around the content area.
    static let window = color(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.035, alpha: 1))
    static let sidebar = color(light: NSColor(white: 0.935, alpha: 1), dark: NSColor(white: 0.06, alpha: 1))
    /// The empty content area, before a window covers it.
    static let content = color(light: NSColor(white: 0.9, alpha: 1), dark: NSColor(white: 0.08, alpha: 1))
    static let selectedTab = Color(nsColor: selectedTabFill)
    /// The selected tab's background, for the layer that draws it.
    static let selectedTabFill = dynamicColor(light: .white, dark: NSColor(white: 0.13, alpha: 1))
    static let idleTab = color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
    static let separator = color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07))
    /// The chosen segment of a segmented switch.
    static let selectedSegment = color(light: .white, dark: NSColor(white: 0.22, alpha: 1))
    /// A lit segment of the world clock's display: warm yellow in the dark theme, dark red in the light one,
    /// where it stands out on the pale sidebar.
    static let clockSegment = color(
        light: NSColor(srgbRed: 0.62, green: 0.07, blue: 0.07, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 0.78, blue: 0.12, alpha: 1)
    )
    /// A sidebar row under the pointer.
    static let hoveredRow = color(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.05))
    /// The square a group's application icons sit in.
    static let tile = color(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.07))
    /// A raised panel in the sidebar, such as a mixer track.
    static let card = color(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.045))
    /// The groove of a slider or a meter.
    static let groove = color(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.1))

    private static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicColor(light: light, dark: dark))
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
