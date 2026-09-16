import CoreAudio
import Foundation

struct Microphone: Codable, Equatable, Identifiable, Sendable {
    let id: String // Core Audio UID persists across reconnects and restarts.
    var name: String
}

enum Microphones {
    struct Device: Equatable, Sendable {
        let microphone: Microphone
        let deviceID: AudioDeviceID
    }

    static func isInternalDevice(_ microphone: Microphone) -> Bool {
        microphone.name.hasPrefix("CADefaultDeviceAggregate-") || microphone.id.hasPrefix("CADefaultDeviceAggregate-")
    }

    static func available() throws -> [Device] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            throw AppFailure("Could not read the microphone list. Try again.")
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { throw AppFailure("Could not read the microphone list. Try again.") }
        let defaultID = integerProperty(system, kAudioHardwarePropertyDefaultInputDevice)
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id -> Device? in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0, integerProperty(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let microphone = Microphone(id: uid, name: name)
            guard integerProperty(id, kAudioDevicePropertyIsHidden) != 1,
                  !isInternalDevice(microphone) else { return nil }
            return Device(microphone: microphone, deviceID: id)
        }.sorted {
            if ($0.deviceID == defaultID) != ($1.deviceID == defaultID) { return $0.deviceID == defaultID }
            if $0.microphone.name != $1.microphone.name { return $0.microphone.name < $1.microphone.name }
            return $0.microphone.id < $1.microphone.id
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func integerProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
