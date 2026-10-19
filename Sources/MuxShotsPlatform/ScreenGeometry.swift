import AppKit

/// Conversions between AppKit's screen coordinates (origin at the bottom-left of the main display, y up) and
/// the window server's (origin at the top-left of the main display, y down), which Accessibility also uses.
@MainActor
public enum ScreenGeometry {
    private static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    public static func windowServerPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    public static func windowServerFrame(fromAppKit frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    public static func appKitFrame(fromWindowServer frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Every display's full frame, in window-server coordinates.
    public static var listDisplayFrames: [CGRect] {
        NSScreen.screens.map { windowServerFrame(fromAppKit: $0.frame) }
    }

    /// The usable area, without menu bar and Dock, of the display showing most of a frame.
    ///
    /// - Parameter frame: a window frame, in window-server coordinates
    /// - Returns: the usable area, in window-server coordinates
    public static func visibleDisplayFrame(containing frame: CGRect) -> CGRect? {
        let screen = NSScreen.screens.max { lhs, rhs in
            overlapArea(windowServerFrame(fromAppKit: lhs.frame), frame)
                < overlapArea(windowServerFrame(fromAppKit: rhs.frame), frame)
        }
        return screen.map { windowServerFrame(fromAppKit: $0.visibleFrame) }
    }

    /// The display frame showing most of a frame, in window-server coordinates.
    public static func displayFrame(containing frame: CGRect) -> CGRect? {
        listDisplayFrames.max { overlapArea($0, frame) < overlapArea($1, frame) }
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
