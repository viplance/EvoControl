import CoreAudio
import Foundation

final class CoreAudioDeviceService: @unchecked Sendable {
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

    func getOutputVolume(deviceID: AudioObjectID, channel: UInt32) -> Float32? {
        getFloatProperty(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar,
                         scope: kAudioDevicePropertyScopeOutput, element: channel)
    }

    func getMute(deviceID: AudioObjectID, output: Bool, channel: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? (value != 0) : nil
    }

    typealias PropertyChangeHandler = @Sendable (AudioObjectID, AudioObjectPropertyAddress) -> Void

    @discardableResult
    func addVolumeListener(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                           channel: UInt32, handler: @escaping PropertyChangeHandler) -> Bool {
        addListener(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar,
                    scope: scope, element: channel, handler: handler)
    }

    @discardableResult
    func addMuteListener(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                         channel: UInt32, handler: @escaping PropertyChangeHandler) -> Bool {
        addListener(deviceID: deviceID, selector: kAudioDevicePropertyMute,
                    scope: scope, element: channel, handler: handler)
    }

    func removeAllListeners(deviceID: AudioObjectID) {
        listenersLock.lock()
        let toRemove = activeListeners.filter { $0.deviceID == deviceID }
        activeListeners.removeAll { $0.deviceID == deviceID }
        listenersLock.unlock()

        for entry in toRemove {
            var address = AudioObjectPropertyAddress(
                mSelector: entry.selector, mScope: entry.scope, mElement: entry.element
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, entry.block)
        }
    }

    private struct ListenerEntry {
        let deviceID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: UInt32
        let block: AudioObjectPropertyListenerBlock
    }

    private let listenersLock = NSLock()
    private var activeListeners: [ListenerEntry] = []

    @discardableResult
    private func addListener(deviceID: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope, element: UInt32,
                             handler: @escaping PropertyChangeHandler) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        let block: AudioObjectPropertyListenerBlock = { count, addresses in
            for i in 0..<Int(count) {
                handler(deviceID, addresses[i])
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
        guard status == noErr else { return false }

        let entry = ListenerEntry(deviceID: deviceID, selector: selector, scope: scope,
                                  element: element, block: block)
        listenersLock.lock()
        activeListeners.append(entry)
        listenersLock.unlock()
        return true
    }

    private func getFloatProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
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
