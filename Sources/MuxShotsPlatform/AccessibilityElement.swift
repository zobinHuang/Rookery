import ApplicationServices
import MuxShotsCore

/// A typed view of an Accessibility element: an application or one of its windows.
struct AccessibilityElement {
    private static let fullscreenAttribute = "AXFullScreen"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let remoteTokenLength = 20
    private static let remoteTokenCocoaTag: Int32 = 0x636f_636f
    private static let remoteElementIdLimit: UInt64 = 500_000
    private static let listWindowSubroles = [kAXStandardWindowSubrole, kAXDialogSubrole]

    let element: AXUIElement

    /// The root element of an application.
    static func application(processId: pid_t) -> AccessibilityElement {
        AccessibilityElement(element: AXUIElementCreateApplication(processId))
    }

    /// Bound how long any Accessibility call waits on an unresponsive application.
    static func applyGlobalMessagingTimeout(seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Find the elements of windows `kAXWindowsAttribute` omits, as it does for windows on other Spaces,
    /// by probing the element identifiers the application has handed out until every target is found.
    /// A window's descendants report the window's identifier too, so only the window element itself matches.
    ///
    /// - Parameters:
    ///   - processId: the application's process identifier
    ///   - setTargetIds: the windows to find
    /// - Returns: the found windows' elements
    static func discoverWindows(processId: pid_t, setTargetIds: Set<WindowId>) -> [WindowId: AccessibilityElement] {
        var mapFound: [WindowId: AccessibilityElement] = [:]
        var token = Data(count: remoteTokenLength)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: processId) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: remoteTokenCocoaTag) { Data($0) })
        for elementId in 0..<remoteElementIdLimit where mapFound.count < setTargetIds.count {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })
            guard let created = axUIElementCreateWithRemoteToken(token as CFData) else {
                continue
            }
            let candidate = AccessibilityElement(element: created.takeRetainedValue())
            guard
                let windowId = try? candidate.windowId(),
                setTargetIds.contains(windowId),
                mapFound[windowId] == nil,
                (try? candidate.isWindow) == true
            else {
                continue
            }
            mapFound[windowId] = candidate
        }
        return mapFound
    }

    /// Whether this element is a window MuxShots manages, as opposed to a sheet, popover or panel.
    var isWindow: Bool {
        get throws {
            guard let subrole = try string(kAXSubroleAttribute) else {
                return false
            }
            return Self.listWindowSubroles.contains(subrole)
        }
    }

    /// The window-server identifier of this window element.
    func windowId() throws -> WindowId {
        var rawId: CGWindowID = 0
        try Self.check(axUIElementGetWindow(element, &rawId), operation: "_AXUIElementGetWindow")
        return WindowId(rawValue: rawId)
    }

    func windows() throws -> [AccessibilityElement] {
        guard let value = try copyAttribute(kAXWindowsAttribute) else {
            return []
        }
        guard let listElements = value as? [AXUIElement] else {
            throw AccessibilityError.unexpectedValueType(attribute: kAXWindowsAttribute)
        }
        return listElements.map { AccessibilityElement(element: $0) }
    }

    func title() throws -> String {
        try string(kAXTitleAttribute) ?? ""
    }

    func frame() throws -> CGRect {
        let origin = try value(kAXPositionAttribute, type: .cgPoint, default: CGPoint.zero)
        let size = try value(kAXSizeAttribute, type: .cgSize, default: CGSize.zero)
        return CGRect(origin: origin, size: size)
    }

    func isMinimized() throws -> Bool {
        try bool(kAXMinimizedAttribute) ?? false
    }

    func isFullscreen() throws -> Bool {
        try bool(Self.fullscreenAttribute) ?? false
    }

    /// Move and resize this window.
    ///
    /// - Parameter frame: the frame in global screen coordinates, origin at the top-left of the main display
    func applyFrame(_ frame: CGRect) throws {
        var origin = frame.origin
        var size = frame.size
        guard
            let originValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            throw AccessibilityError.unexpectedValueType(attribute: kAXPositionAttribute)
        }
        try write(kAXSizeAttribute, value: sizeValue)
        try write(kAXPositionAttribute, value: originValue)
        try write(kAXSizeAttribute, value: sizeValue)
    }

    /// Bring this window to the front of its application and make it the main window.
    func raise() throws {
        try write(kAXMainAttribute, value: kCFBooleanTrue)
        try Self.check(AXUIElementPerformAction(element, kAXRaiseAction as CFString), operation: kAXRaiseAction)
    }

    func applyMinimized(_ isMinimized: Bool) throws {
        try write(kAXMinimizedAttribute, value: isMinimized as CFBoolean)
    }

    func applyFullscreen(_ isFullscreen: Bool) throws {
        try write(Self.fullscreenAttribute, value: isFullscreen as CFBoolean)
    }

    /// Whether this application runs its enhanced interface for assistive clients, which makes Chromium and
    /// Electron applications animate and lag when their windows are moved.
    func isEnhancedUserInterface() throws -> Bool {
        try bool(Self.enhancedUserInterfaceAttribute) ?? false
    }

    func applyEnhancedUserInterface(_ isEnabled: Bool) throws {
        try write(Self.enhancedUserInterfaceAttribute, value: isEnabled as CFBoolean)
    }

    private func write(_ attribute: String, value: CFTypeRef) throws {
        try Self.check(
            AXUIElementSetAttributeValue(element, attribute as CFString, value),
            operation: attribute
        )
    }

    private func string(_ attribute: String) throws -> String? {
        guard let value = try copyAttribute(attribute) else {
            return nil
        }
        guard let string = value as? String else {
            throw AccessibilityError.unexpectedValueType(attribute: attribute)
        }
        return string
    }

    private func bool(_ attribute: String) throws -> Bool? {
        guard let value = try copyAttribute(attribute) else {
            return nil
        }
        guard let flag = value as? Bool else {
            throw AccessibilityError.unexpectedValueType(attribute: attribute)
        }
        return flag
    }

    private func value<Value>(_ attribute: String, type: AXValueType, default defaultValue: Value) throws -> Value {
        guard let value = try copyAttribute(attribute) else {
            return defaultValue
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityError.unexpectedValueType(attribute: attribute)
        }
        let axValue = value as! AXValue
        var result = defaultValue
        let isConverted = withUnsafeMutablePointer(to: &result) { pointer in
            AXValueGetValue(axValue, type, pointer)
        }
        guard isConverted else {
            throw AccessibilityError.unexpectedValueType(attribute: attribute)
        }
        return result
    }

    /// Read an attribute, treating "no value" and "not supported" as absent.
    private func copyAttribute(_ attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            /* element */     element,
            /* attribute */   attribute as CFString,
            /* value */       &value
        )
        switch error {
        case .success:
            return value
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw AccessibilityError.callFailed(code: error.rawValue, operation: attribute)
        }
    }

    static func check(_ error: AXError, operation: String) throws {
        guard error == .success else {
            throw AccessibilityError.callFailed(code: error.rawValue, operation: operation)
        }
    }
}
