import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class MixerStore: ObservableObject {
    @Published var devices: [EvoDevice] = []
    @Published var selectedDevice: EvoDevice?
    @Published var inputs: [InputChannel] = [
        InputChannel(id: 1, name: "Input 1", gain: 0.48, phantomPower: false, muted: false, directMixToOutput: 0.35, level: 0),
        InputChannel(id: 2, name: "Input 2", gain: 0.42, phantomPower: false, muted: false, directMixToOutput: 0.30, level: 0)
    ]
    @Published var outputs: [OutputChannel] = [
        OutputChannel(id: 1, name: "Output", volume: 0.72, muted: false, level: 0, hasLevelMeter: false),
        OutputChannel(id: 2, name: "Monitor", volume: 0.54, muted: false, level: 0, hasLevelMeter: false)
    ]
    @Published var statusMessage = "Searching for Audient EVO..."

    private let coreAudio = CoreAudioDeviceService()
    private let hardware: EvoHardwareControlling = EvoHardwareController()
    private lazy var levelMeter = AudioLevelMeterService { [weak self] levels in
        self?.applyInputLevels(levels)
    }
    private var hardwareSyncTask: Task<Void, Never>?
    private var applyCount = 0
    private var hardwarePollCount = 0
    private var phantomReadFailures: [Int: Int] = [:]
    private var phantomReadDisabledInputs = Set<Int>()
    private var hardwareSyncInFlight = false

    /// False when macOS refuses to release the USB-audio class driver, which
    /// makes every vendor control transfer (48V, gain, monitor mix) fail.
    @Published private(set) var isUsbControlAvailable = true
    private var usbControlMessage: String?

    init() {
        restorePersistedPhantomStates()
        probeUsbControl()
    }

    /// Runs the USB probe off the main actor so startup never blocks the UI.
    private func probeUsbControl() {
        Task { [weak self] in
            let result = await EvoUsbConnection.shared.probe()
            guard let self else { return }
            self.isUsbControlAvailable = result.available
            self.usbControlMessage = result.message
            self.log("USB control availability: \(result.available) message=\(result.message ?? "none")")
        }
    }

    func prepareAudioAndRefreshDevices() {
        log("Checking microphone authorization: \(microphoneAuthorizationDescription)")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            refreshDevices()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.log("Microphone requestAccess granted=\(granted). Refreshing HAL metering.")
                    self.refreshDevices()
                }
            }
        } else {
            refreshDevices()
        }
    }

    func refreshDevices() {
        devices = coreAudio.discoverEvoDevices()
        log("Discovered devices: \(devices.map { $0.displayName })")
        selectedDevice = devices.first
        guard let selectedDevice else {
            levelMeter.stop()
            stopHardwarePolling()
            statusMessage = "No Audient EVO device found."
            log("No selected device found.")
            return
        }

        log("Selected device: \(selectedDevice.displayName) (ID: \(selectedDevice.id)). Microphone auth: \(microphoneAuthorizationDescription)")
        requestHardwareControlSync()
        startHardwarePolling()
        let meterResult: ControlResult
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            meterResult = levelMeter.start(deviceID: selectedDevice.id)
            log("Level meter start result: applied=\(meterResult.applied), message=\(String(describing: meterResult.message))")
        } else {
            levelMeter.stop()
            meterResult = ControlResult(applied: false, message: "Live levels waiting for microphone permission.")
            log("Level meter skipped until microphone permission is granted.")
        }
        statusMessage = meterResult.applied
            ? "Connected: \(selectedDevice.displayName). \(meterResult.message ?? "Live levels enabled.")"
            : "Connected: \(selectedDevice.displayName). \(meterResult.message ?? "Live levels unavailable.")"
        log("Status message set: \(statusMessage)")
    }

    private func refreshDevicesWithoutMetering() {
        devices = coreAudio.discoverEvoDevices()
        log("refreshDevicesWithoutMetering. Discovered devices: \(devices.map { $0.displayName })")
        selectedDevice = devices.first
        requestHardwareControlSync()
        if selectedDevice != nil {
            log("refreshDevicesWithoutMetering. Selected: \(selectedDevice!.displayName)")
            startHardwarePolling()
        } else {
            log("refreshDevicesWithoutMetering. No device selected.")
            stopHardwarePolling()
        }
    }

    func setGain(inputID: Int, value: Double) {
        updateInput(inputID) { $0.gain = value }
        let coreAudio = self.coreAudio
        let device = selectedDevice
        Task.detached {
            let usbResult = EvoUsbProtocol.setInputGain(input: inputID, percent: value)
            let fallback = (!usbResult.applied && device != nil)
                ? coreAudio.setInputGain(deviceID: device!.id, channel: UInt32(inputID), value: Float32(value))
                : nil
            await self.applyControlOutcome(usbResult: usbResult, fallback: fallback)
        }
    }

    func setInputMute(inputID: Int, muted: Bool) {
        updateInput(inputID) { $0.muted = muted }
        guard let selectedDevice else { return }
        publish(coreAudio.setMute(deviceID: selectedDevice.id, output: false, channel: UInt32(inputID), muted: muted))
    }

    func setPhantom(inputID: Int, enabled: Bool) {
        // UI updates immediately; the USB write happens off the main actor so
        // the toggle never waits on the device.
        updateInput(inputID) { $0.phantomPower = enabled }
        persistPhantomState(inputID: inputID, enabled: enabled)
        Task { [weak self] in
            let result = await EvoUsbConnection.shared.set(
                wValue: 0x0000 + UInt16(max(0, inputID - 1)),
                wIndex: 0x3A00,
                data: [enabled ? 0x01 : 0x00, 0x00, 0x00, 0x00]
            )
            guard let self else { return }
            self.log("48V set: input=\(inputID) enabled=\(enabled) applied=\(result.applied) message=\(String(describing: result.message))")
            self.publish(result)
        }
    }

    func setDirectMix(inputID: Int, value: Double) {
        updateInput(inputID) { $0.directMixToOutput = value }
        let hardware = self.hardware
        let device = selectedDevice
        Task.detached {
            let left = hardware.setDirectMonitorMix(device: device, input: inputID, output: 1, value: value)
            let right = hardware.setDirectMonitorMix(device: device, input: inputID, output: 2, value: value)
            await self.applyControlOutcome(usbResult: left.applied ? right : left, fallback: nil)
        }
    }

    /// Publishes the outcome of an off-main-actor hardware write.
    private func applyControlOutcome(usbResult: ControlResult, fallback: ControlResult?) {
        if let fallback {
            publishBest(fallback: fallback, primaryFailure: usbResult)
        } else {
            publish(usbResult)
        }
    }

    func setOutputVolume(outputID: Int, value: Double) {
        updateOutput(outputID) { $0.volume = value }
        let coreAudio = self.coreAudio
        let device = selectedDevice
        Task.detached {
            let usbResult = EvoUsbProtocol.setOutputVolume(output: outputID, percent: value)
            let fallback = (!usbResult.applied && device != nil)
                ? coreAudio.setOutputVolume(deviceID: device!.id, channel: UInt32(outputID), value: Float32(value))
                : nil
            await self.applyControlOutcome(usbResult: usbResult, fallback: fallback)
        }
    }

    func setOutputMute(outputID: Int, muted: Bool) {
        updateOutput(outputID) { $0.muted = muted }
        guard let selectedDevice else { return }
        publish(coreAudio.setMute(deviceID: selectedDevice.id, output: true, channel: UInt32(outputID), muted: muted))
    }

    private func updateInput(_ id: Int, mutate: (inout InputChannel) -> Void) {
        guard let index = inputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&inputs[index])
    }

    private func updateOutput(_ id: Int, mutate: (inout OutputChannel) -> Void) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&outputs[index])
    }

    private func publish(_ result: ControlResult) {
        if let message = result.message {
            statusMessage = message
        } else if result.applied {
            statusMessage = "Hardware updated."
        }
    }

    private func publishBest(fallback: ControlResult, primaryFailure: ControlResult) {
        if fallback.applied {
            publish(fallback)
        } else {
            publish(primaryFailure)
        }
    }

    private func applyInputLevels(_ levels: [Double]) {
        applyCount += 1
        let hasSignal = levels.contains { $0 > 0.005 }
        if applyCount <= 5 || hasSignal || applyCount % 100 == 1 {
            log("applyInputLevels hasSignal=\(hasSignal) count=\(applyCount) levels=\(levels)")
        }
        for index in inputs.indices {
            let sourceIndex = levelSourceIndex(forInputIndex: index, levelCount: levels.count)
            let rawLevel = sourceIndex < levels.count ? levels[sourceIndex] : 0
            let previous = inputs[index].level
            inputs[index].level = smoothLevel(previous: previous, next: rawLevel)
        }
        clearUnavailableOutputLevels()
    }

    private func requestHardwareControlSync() {
        guard !hardwareSyncInFlight else { return }
        hardwareSyncInFlight = true
        let inputIDs = inputs.map(\.id)
        hardwarePollCount += 1
        let syncTask = Task.detached {
            let gains = inputIDs.compactMap { inputID -> (Int, Double)? in
                guard let gain = EvoUsbProtocol.getInputGain(input: inputID) else { return nil }
                return (inputID, gain)
            }
            return gains
        }
        Task { [weak self] in
            let gains = await syncTask.value
            guard let self else { return }
            self.hardwareSyncInFlight = false
            self.applyGainStates(gains)
        }
    }

    private func applyGainStates(_ gains: [(Int, Double)]) {
        for (inputID, gain) in gains {
            updateInput(inputID) { input in
                if abs(input.gain - gain) > 0.004 {
                    input.gain = gain
                }
            }
        }
    }

    private func startHardwarePolling() {
        stopHardwarePolling()
        hardwareSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.requestHardwareControlSync()
            }
        }
    }

    private func restorePersistedPhantomStates() {
        for index in inputs.indices {
            let key = phantomDefaultsKey(inputID: inputs[index].id)
            if UserDefaults.standard.object(forKey: key) != nil {
                inputs[index].phantomPower = UserDefaults.standard.bool(forKey: key)
            }
        }
    }

    private func persistPhantomState(inputID: Int, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: phantomDefaultsKey(inputID: inputID))
    }

    private func phantomDefaultsKey(inputID: Int) -> String {
        "phantomPower.input\(inputID)"
    }

    private func stopHardwarePolling() {
        hardwareSyncTask?.cancel()
        hardwareSyncTask = nil
    }

    private func clearUnavailableOutputLevels() {
        for index in outputs.indices {
            if !outputs[index].hasLevelMeter {
                outputs[index].level = 0
            }
        }
        if applyCount <= 5 || applyCount % 100 == 0 {
            log("outputLevels unavailable: physical EVO output/monitor meter is not exposed by current CoreAudio/USB read path")
        }
    }

    private func levelSourceIndex(forInputIndex inputIndex: Int, levelCount: Int) -> Int {
        inputIndex
    }

    private func smoothLevel(previous: Double, next: Double) -> Double {
        let clamped = max(0, min(1, next))
        return clamped > previous
            ? previous * 0.35 + clamped * 0.65
            : previous * 0.82 + clamped * 0.18
    }

    private var microphoneAuthorizationDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private func log(_ message: String) {
        DebugLog.write("MixerStore", message)
    }
}
