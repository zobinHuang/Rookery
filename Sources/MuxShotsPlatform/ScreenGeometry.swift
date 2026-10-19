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

    /// The position in `listDisplayFrames` of the display showing most of a frame.
    public static func displayIndex(containing frame: CGRect) -> Int? {
        let listFrames = listDisplayFrames
        guard let best = listFrames.indices.max(by: { overlapArea(listFrames[$0], frame) < overlapArea(listFrames[$1], frame) }),
            overlapArea(listFrames[best], frame) > 0
        else {
            return nil
        }
        return best
    }

    /// The display frame showing most of a frame, in window-server coordinates.
    public static func displayFrame(containing frame: CGRect) -> CGRect? {
        listDisplayFrames.max { overlapArea($0, frame) < overlapArea($1, frame) }
    }

    /// Where to park a window so that it is out of sight: past a bottom corner of its display with a single
    /// point still on screen, which keeps macOS from moving it back. The corner chosen is one that does not
    /// border another display.
    ///
    /// - Parameter frame: the window's frame, in window-server coordinates
    /// - Returns: the parked frame, in window-server coordinates
    public static func offscreenFrame(for frame: CGRect) -> CGRect {
        guard let display = displayFrame(containing: frame) else {
            return frame
        }
        let listCandidates = [
            CGRect(x: display.maxX - 1, y: display.maxY - 1, width: frame.width, height: frame.height),
            CGRect(x: display.minX - frame.width + 1, y: display.maxY - 1, width: frame.width, height: frame.height),
        ]
        let listOtherDisplays = listDisplayFrames.filter { $0 != display }
        return listCandidates.first { candidate in
            !listOtherDisplays.contains { $0.intersects(candidate) }
        } ?? listCandidates[0]
    }

    /// The share of a frame that lies on some display, from 0 to 1.
    public static func visibleShare(of frame: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else {
            return 0
        }
        let visibleArea = listDisplayFrames.reduce(0) { $0 + overlapArea($1, frame) }
        return min(visibleArea / (frame.width * frame.height), 1)
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
