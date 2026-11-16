import ApplicationServices

/// A failed Accessibility call.
public enum AccessibilityError: Error, Sendable, CustomStringConvertible {
    case callFailed(code: Int32, operation: String)
    case unexpectedValueType(attribute: String)

    /// Whether the element no longer exists, as when its window has closed.
    public var isInvalidElement: Bool {
        if case .callFailed(let code, _) = self {
            return code == AXError.invalidUIElement.rawValue
        }
        return false
    }

    /// Whether the application did not answer in time: the request may still reach it and be carried out
    /// later.
    public var isUnanswered: Bool {
        if case .callFailed(let code, _) = self {
            return code == AXError.cannotComplete.rawValue
        }
        return false
    }

    public var description: String {
        switch self {
        case .callFailed(let code, let operation):
            "\(operation) failed with AXError \(code)"
        case .unexpectedValueType(let attribute):
            "\(attribute) has an unexpected value type"
        }
    }
}
