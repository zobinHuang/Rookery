import AppKit
import MuxShotsCore

/// A window the user is dragging by its title bar.
public struct WindowDrag: Sendable {
    public let windowId: WindowId
    public let processId: pid_t
    /// The frame before the drag began, in global screen coordinates with the origin at the top-left of the
    /// main display.
    public let startFrame: CGRect
}

/// Receives the stages of a window drag; cursor locations are in AppKit screen coordinates.
@MainActor
public protocol WindowDragMonitorDelegate: AnyObject {
    func windowDragBegan(_ drag: WindowDrag, at cursorLocation: CGPoint)
    func windowDragMoved(_ drag: WindowDrag, to cursorLocation: CGPoint)
    func windowDragEnded(_ drag: WindowDrag, at cursorLocation: CGPoint)
}

/// Detects the user dragging any application's window, from global mouse events and the window server's
/// frames; it needs no per-application tracking.
@MainActor
public final class WindowDragMonitor {
    /// How far the cursor moves before the press counts as a drag attempt.
    private static let dragThreshold: CGFloat = 4
    /// How far the cursor may move without the window following before the press is treated as a drag
    /// inside the window's content.
    private static let giveUpDistance: CGFloat = 48

    public weak var delegate: WindowDragMonitorDelegate?
    private var monitor: Any?
    private var pressLocation: CGPoint?
    private var pressedWindow: WindowServerWindow?
    private var activeDrag: WindowDrag?

    public init() {}

    /// Start watching global mouse events.
    public func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let cursorLocation = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.handle(event.type, at: cursorLocation)
            }
        }
    }

    /// Stop watching global mouse events.
    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        reset()
    }

    private func handle(_ eventType: NSEvent.EventType, at cursorLocation: CGPoint) {
        switch eventType {
        case .leftMouseDown:
            reset()
            pressLocation = cursorLocation
            pressedWindow = WindowServer.frontmostWindow(
                at: ScreenGeometry.windowServerPoint(fromAppKit: cursorLocation),
                excluding: ProcessInfo.processInfo.processIdentifier
            )
        case .leftMouseDragged:
            if let activeDrag {
                delegate?.windowDragMoved(activeDrag, to: cursorLocation)
            } else {
                detectDrag(at: cursorLocation)
            }
        case .leftMouseUp:
            if let activeDrag {
                delegate?.windowDragEnded(activeDrag, at: cursorLocation)
            }
            reset()
        default:
            break
        }
    }

    /// Start a drag once the pressed window has moved without resizing.
    private func detectDrag(at cursorLocation: CGPoint) {
        guard let pressLocation, let pressedWindow else {
            return
        }
        let distance = hypot(cursorLocation.x - pressLocation.x, cursorLocation.y - pressLocation.y)
        guard distance >= Self.dragThreshold else {
            return
        }
        guard
            let currentWindow = WindowServer.window(withId: pressedWindow.windowId),
            currentWindow.frame.size == pressedWindow.frame.size,
            currentWindow.frame.origin != pressedWindow.frame.origin
        else {
            if distance >= Self.giveUpDistance {
                reset()
            }
            return
        }
        let drag = WindowDrag(
            windowId: pressedWindow.windowId,
            processId: pressedWindow.processId,
            startFrame: pressedWindow.frame
        )
        activeDrag = drag
        delegate?.windowDragBegan(drag, at: cursorLocation)
    }

    private func reset() {
        pressLocation = nil
        pressedWindow = nil
        activeDrag = nil
    }
}
