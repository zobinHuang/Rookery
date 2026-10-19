import AppKit

/// Sees every key press before the system acts on it, through a session event tap, and swallows the ones
/// its handler claims. This is how a shortcut the system reserves, such as ⌘⇥, can be taken over.
@MainActor
public final class KeyInterceptor {
    /// Decides about one key press: return true to swallow it.
    public typealias Handler = @MainActor (_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Start intercepting key presses.
    ///
    /// - Returns: whether the system allowed the tap, which needs Accessibility access
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else {
            return true
        }
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { _, type, event, context in
                    guard let context else {
                        return Unmanaged.passUnretained(event)
                    }
                    let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(context).takeUnretainedValue()
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    let rawFlags = event.flags.rawValue
                    let isSwallowed = MainActor.assumeIsolated {
                        interceptor.isSwallowed(type: type, keyCode: keyCode, rawFlags: rawFlags)
                    }
                    return isSwallowed ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            return false
        }
        let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), createdSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = createdSource
        return true
    }

    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        source = nil
    }

    /// Whether to swallow an event, re-enabling the tap if the system turned it off.
    private func isSwallowed(type: CGEventType, keyCode: Int, rawFlags: UInt64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        guard type == .keyDown else {
            return false
        }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
            .intersection([.command, .option, .control, .shift])
        return handler(keyCode, modifiers)
    }
}
