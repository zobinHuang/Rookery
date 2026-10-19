import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as a global shortcut.
public struct Hotkey: Hashable, Sendable {
    /// A virtual key code, such as `kVK_ANSI_1`.
    public let keyCode: UInt32
    public let modifiers: NSEvent.ModifierFlags

    public init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    public static func == (lhs: Hotkey, rhs: Hotkey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// The modifiers in Carbon's encoding.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }
        return flags
    }
}

/// Global shortcuts through Carbon's hot-key registry, which needs no permission, plus a watch on modifier
/// releases for hold-to-choose interactions.
@MainActor
public final class HotkeyCenter {
    private static let signature: OSType = 0x4d_53_48_4b
    private static let modifierPollInterval = Duration.milliseconds(30)

    private var eventHandler: EventHandlerRef?
    private var mapRegistrations: [UInt32: EventHotKeyRef] = [:]
    private var mapActions: [UInt32: @MainActor () -> Void] = [:]
    private var mapIdentifiers: [Hotkey: UInt32] = [:]
    private var nextIdentifier: UInt32 = 1
    private var listModifierMonitors: [Any] = []
    private var modifierPollTask: Task<Void, Never>?
    private var isWatchingModifiers = false

    public init() {}

    /// Start receiving hot-key presses.
    public func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            /* inTarget */         GetApplicationEventTarget(),
            /* inHandler */        { _, event, context in
                guard let event, let context else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyId = EventHotKeyID()
                GetEventParameter(
                    /* inEvent */           event,
                    /* inName */            EventParamName(kEventParamDirectObject),
                    /* inDesiredType */     EventParamType(typeEventHotKeyID),
                    /* outActualType */     nil,
                    /* inBufferSize */      MemoryLayout<EventHotKeyID>.size,
                    /* outActualSize */     nil,
                    /* outData */           &hotKeyId
                )
                let identifier = hotKeyId.id
                MainActor.assumeIsolated {
                    Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue().fire(identifier)
                }
                return noErr
            },
            /* inNumTypes */       1,
            /* inList */           &eventType,
            /* inUserData */       context,
            /* outRef */           &eventHandler
        )
    }

    /// Stop receiving hot-key presses and unregister every shortcut.
    public func stop() {
        for hotkey in Array(mapIdentifiers.keys) {
            unregister(hotkey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        stopWatchingModifiers()
    }

    /// Run an action whenever a shortcut is pressed, replacing any action it had.
    ///
    /// - Returns: whether the system accepted the shortcut; another application may already own it
    @discardableResult
    public func register(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) -> Bool {
        unregister(hotkey)
        let identifier = nextIdentifier
        nextIdentifier += 1
        var registration: EventHotKeyRef?
        let status = RegisterEventHotKey(
            /* inHotKeyCode */     hotkey.keyCode,
            /* inHotKeyModifiers */ hotkey.carbonModifiers,
            /* inHotKeyID */       EventHotKeyID(signature: Self.signature, id: identifier),
            /* inTarget */         GetApplicationEventTarget(),
            /* inOptions */        0,
            /* outRef */           &registration
        )
        guard status == noErr, let registration else {
            return false
        }
        mapRegistrations[identifier] = registration
        mapActions[identifier] = action
        mapIdentifiers[hotkey] = identifier
        return true
    }

    public func unregister(_ hotkey: Hotkey) {
        guard let identifier = mapIdentifiers.removeValue(forKey: hotkey) else {
            return
        }
        if let registration = mapRegistrations.removeValue(forKey: identifier) {
            UnregisterEventHotKey(registration)
        }
        mapActions[identifier] = nil
    }

    /// Call an action once none of the given modifiers is held any more, whichever application is in front.
    /// The keyboard's state is polled as well as observed, since a release can land between a hot-key press
    /// and the observers being installed.
    public func whenReleased(_ modifiers: NSEvent.ModifierFlags, action: @escaping @MainActor () -> Void) {
        stopWatchingModifiers()
        let check: @MainActor () -> Void = { [weak self] in
            guard let self, isWatchingModifiers, Self.heldModifiers.intersection(modifiers).isEmpty else {
                return
            }
            stopWatchingModifiers()
            action()
        }
        isWatchingModifiers = true
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { _ in
            MainActor.assumeIsolated {
                check()
            }
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated {
                check()
            }
            return event
        }
        listModifierMonitors = [globalMonitor, localMonitor].compactMap { $0 }
        modifierPollTask = Task { [weak self] in
            while !Task.isCancelled, self?.isWatchingModifiers == true {
                check()
                try? await Task.sleep(for: Self.modifierPollInterval)
            }
        }
    }

    public func stopWatchingModifiers() {
        isWatchingModifiers = false
        modifierPollTask?.cancel()
        modifierPollTask = nil
        for monitor in listModifierMonitors {
            NSEvent.removeMonitor(monitor)
        }
        listModifierMonitors.removeAll()
    }

    /// The modifiers held on the keyboard right now, from the system's combined event state.
    private static var heldModifiers: NSEvent.ModifierFlags {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) {
            modifiers.insert(.command)
        }
        if flags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }
        if flags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if flags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }

    private func fire(_ identifier: UInt32) {
        mapActions[identifier]?()
    }
}
