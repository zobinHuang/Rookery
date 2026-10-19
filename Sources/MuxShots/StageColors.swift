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
    static let selectedTab = color(light: .white, dark: NSColor(white: 0.13, alpha: 1))
    static let idleTab = color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
    static let separator = color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07))

    private static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
