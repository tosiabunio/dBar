import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "\(operation) failed (\(status.fourCharDescription))." }
}

extension OSStatus {
    /// Throws a `CoreAudioError` unless the status is `noErr`.
    func check(_ operation: @autoclosure () -> String) throws {
        guard self != noErr else { return }
        throw CoreAudioError(operation: operation(), status: self)
    }

    /// Core Audio errors are usually four-character codes such as `'!obj'`.
    var fourCharDescription: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: self).bigEndian, Array.init)
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(self) }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try system.read(kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    func read<Value: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, defaultValue: Value) throws -> Value {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = defaultValue
        try AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
            .check("Reading audio property \(OSStatus(bitPattern: selector).fourCharDescription)")
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
            .check("Reading audio property \(OSStatus(bitPattern: selector).fourCharDescription)")
        guard let value else { throw CoreAudioError(operation: "Reading audio property", status: kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
