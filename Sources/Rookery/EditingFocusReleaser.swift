import AppKit

/// Ends text editing when the user clicks anywhere outside the field being edited, in any of Rookery's
/// windows, as a click on empty space does in a Mac app's forms. AppKit keeps a field focused until another
/// control takes the focus, so a click on a list, a label or the background left the field, and a view
/// waiting for it to lose focus, editing.
@MainActor
final class EditingFocusReleaser {
    private var monitor: Any?

    func start() {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                Self.releaseFocus(awayFrom: event)
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Take the focus from the field being edited if the click falls outside it, once the click has done
    /// whatever else it does, and only if the field still has the focus by then: a click into another field
    /// has moved it there.
    private static func releaseFocus(awayFrom event: NSEvent) {
        guard
            let window = event.window,
            let responder = window.firstResponder as? NSTextView,
            responder.isEditable
        else {
            return
        }
        let editedView: NSView = responder.isFieldEditor
            ? (responder.delegate as? NSView ?? responder)
            : (responder.enclosingScrollView ?? responder)
        let point = editedView.convert(event.locationInWindow, from: nil)
        guard !editedView.bounds.contains(point) else {
            return
        }
        DispatchQueue.main.async {
            if window.firstResponder === responder {
                window.makeFirstResponder(nil)
            }
        }
    }
}
