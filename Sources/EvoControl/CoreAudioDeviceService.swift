import CoreAudio
import Foundation

final class CoreAudioDeviceService: Sendable {
    func discoverEvoDevices() -> [EvoDevice] {
        allDevices()
            .map { deviceID in
                EvoDevice(
                    id: deviceID,
                    name: stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown Device",
                    manufacturer: stringProperty(deviceID, selector: kAudioObjectPropertyManufacturer) ?? ""
                )
            }
            .filter { device in
                let name = device.name.lowercased()
                let manufacturer = device.manufacturer.lowercased()
                guard !name.contains("evo control output meter") else { return false }
                return manufacturer.contains("audient") || name == "evo4"
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func setOutputVolume(deviceID: AudioObjectID, channel: UInt32, value: Float32) -> ControlResult {
        setFloatProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: channel,
            value: max(0, min(1, value)),
            successMessage: nil,
            unsupportedMessage: "Output \(channel) volume is not exposed by CoreAudio for this EVO device."
        )
    }

    func setInputGain(deviceID: AudioObjectID, channel: UInt32, value: Float32) -> ControlResult {
        setFloatProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput,
            element: channel,
            value: max(0, min(1, value)),
            successMessage: nil,
            unsupportedMessage: "Input \(channel) gain is not exposed by CoreAudio for this EVO device."
        )
    }

    func setMute(deviceID: AudioObjectID, output: Bool, channel: UInt32, muted: Bool) -> ControlResult {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return ControlResult(applied: false, message: "Mute is not exposed by CoreAudio for channel \(channel).")
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            return ControlResult(applied: false, message: "CoreAudio rejected mute change with OSStatus \(status).")
        }
        return ControlResult(applied: true, message: nil)
    }

    private func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = Array(repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard status == noErr else { return [] }
        return devices
    }

    private func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var size = UInt32(MemoryLayout<CFString>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString>.size,
            alignment: MemoryLayout<CFString>.alignment
        )
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer)
        guard status == noErr else { return nil }
        return buffer.load(as: CFString.self) as String
    }

    private func setFloatProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: Float32,
        successMessage: String?,
        unsupportedMessage: String
    ) -> ControlResult {
        var writeValue = value
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return ControlResult(applied: false, message: unsupportedMessage)
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &writeValue)
        guard status == noErr else {
            return ControlResult(applied: false, message: "CoreAudio rejected control change with OSStatus \(status).")
        }
        return ControlResult(applied: true, message: successMessage)
    }
}
