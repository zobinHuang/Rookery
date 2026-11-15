import CoreAudio
import Foundation

/// A Core Audio call that failed, with the status it returned.
public struct AudioError: Error, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        "\(operation) failed with status \(status)"
    }

    /// Throw unless a Core Audio call succeeded.
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioError(operation: operation, status: status)
        }
    }
}

/// Reading the properties of Core Audio objects, which come back as raw bytes of a type the property
/// implies.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// A fixed-size property, such as a number or an object id.
    static func value<Value>(_ selector: AudioObjectPropertySelector, of objectId: AudioObjectID, as _: Value.Type) throws -> Value {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<Value>.alignment)
        defer {
            pointer.deallocate()
        }
        try AudioError.check(AudioObjectGetPropertyData(objectId, &address, 0, nil, &size, pointer), "Reading property \(selector)")
        return pointer.load(as: Value.self)
    }

    /// A property holding a list of fixed-size values.
    static func list<Value>(_ selector: AudioObjectPropertySelector, of objectId: AudioObjectID, as _: Value.Type) throws -> [Value] {
        var address = address(selector)
        var size: UInt32 = 0
        try AudioError.check(AudioObjectGetPropertyDataSize(objectId, &address, 0, nil, &size), "Sizing property \(selector)")
        let count = Int(size) / MemoryLayout<Value>.stride
        guard count > 0 else {
            return []
        }
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: count)
        defer {
            pointer.deallocate()
        }
        try AudioError.check(AudioObjectGetPropertyData(objectId, &address, 0, nil, &size, pointer), "Reading property \(selector)")
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<Value>.stride))
    }

    /// A property holding a string, which Core Audio hands over retained.
    static func string(_ selector: AudioObjectPropertySelector, of objectId: AudioObjectID) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try AudioError.check(AudioObjectGetPropertyData(objectId, &address, 0, nil, &size, &value), "Reading property \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }
}
