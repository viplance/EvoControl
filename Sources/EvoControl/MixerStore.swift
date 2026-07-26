import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class MixerStore: ObservableObject {
    @Published var devices: [EvoDevice] = []
    @Published var selectedDevice: EvoDevice?
    @Published var inputs: [InputChannel] = [
        InputChannel(id: 1, name: "Input 1", gain: 0.48, phantomPower: false, muted: false, directMixToOutput: 0.0, level: 0),
        InputChannel(id: 2, name: "Input 2", gain: 0.42, phantomPower: false, muted: false, directMixToOutput: 0.0, level: 0)
    ]
    // The EVO 4 has a single output level shared by the speaker outputs and the
    // headphone jack -- the manual states the Volume control applies to both,
    // and reading wIndex 0x3B00 confirms it: 0x0000 and 0x0001 are the left and
    // right of one pair and always hold the same value, while 0x0002..0x0008
    // sit permanently at -127.5 dB (not implemented). A separate "Monitor"
    // strip therefore duplicated the same hardware control.
    @Published var outputs: [OutputChannel] = [
        OutputChannel(id: 1, name: "Output", volume: 0.72, muted: false, level: 0, hasLevelMeter: true)
    ]
    @Published var monitorBalance: Double = 1.0
    @Published var statusMessage = "Searching for Audient EVO..."

    private let coreAudio = CoreAudioDeviceService()
    private let hardware: EvoHardwareControlling = EvoHardwareController()
    private lazy var levelMeter = AudioLevelMeterService { [weak self] levels in
        self?.applyInputLevels(levels)
    }
    private lazy var outputTapMeter = OutputTapMeterService { [weak self] levels in
        self?.applyOutputLevels(levels)
    }
    private let softwareMonitor = SoftwareMonitorService()
    private var hardwareSyncTask: Task<Void, Never>?
    private var applyCount = 0
    private var outputApplyCount = 0
    private var sawOutputSignal = false
    private var sawInputSignal = false
    private var hardwarePollCount = 0
    private var phantomReadFailures: [Int: Int] = [:]
    private var phantomReadDisabledInputs = Set<Int>()
    private var hardwareSyncInFlight = false
    private var suppressOutputVolumeListener = false
    private var suppressOutputMuteListener = false
    private var lastPollFoundChange = false
    private var idlePollCount = 0

    /// False when macOS refuses to release the USB-audio class driver, which
    /// makes every vendor control transfer (48V, gain, monitor mix) fail.
    @Published private(set) var isUsbControlAvailable = true
    private var usbControlMessage: String?

    init() {
        restorePersistedPhantomStates()
        restorePersistedMonitorBalance()
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
            outputTapMeter.stop()
            softwareMonitor.stop()
            removeCoreAudioListeners()
            stopHardwarePolling()
            statusMessage = "No Audient EVO device found."
            log("No selected device found.")
            return
        }

        log("Selected device: \(selectedDevice.displayName) (ID: \(selectedDevice.id)). Microphone auth: \(microphoneAuthorizationDescription)")
        installCoreAudioListeners(deviceID: selectedDevice.id)
        requestHardwareControlSync()
        startHardwarePolling()
        let meterResult: ControlResult
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            meterResult = levelMeter.start(deviceID: selectedDevice.id)
            log("Level meter start result: applied=\(meterResult.applied), message=\(String(describing: meterResult.message))")
            let outputMeterResult = outputTapMeter.start(deviceID: selectedDevice.id)
            log("Output tap meter start result: applied=\(outputMeterResult.applied), message=\(String(describing: outputMeterResult.message))")
            let monitorResult = softwareMonitor.start(deviceID: selectedDevice.id)
            log("Software monitor start result: applied=\(monitorResult.applied), message=\(String(describing: monitorResult.message))")
            if monitorResult.applied {
                pushDirectMixToSoftwareMonitor()
            }
            statusMessage = meterResult.applied
                ? "Connected: \(selectedDevice.displayName). \(meterResult.message ?? "Live levels enabled.")"
                : "Connected: \(selectedDevice.displayName). \(meterResult.message ?? "Live levels unavailable.")"
            if let message = outputMeterResult.message {
                statusMessage += " \(message)"
            }
        } else {
            levelMeter.stop()
            outputTapMeter.stop()
            softwareMonitor.stop()
            meterResult = ControlResult(applied: false, message: "Live levels waiting for microphone permission.")
            log("Level meter skipped until microphone permission is granted.")
            statusMessage = "Connected: \(selectedDevice.displayName). \(meterResult.message ?? "Live levels unavailable.")"
        }
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
        softwareMonitor.setMuted(inputID: inputID, muted: muted)
        guard let selectedDevice else { return }
        let result = coreAudio.setMute(deviceID: selectedDevice.id, output: false, channel: UInt32(inputID), muted: muted)
        if result.applied {
            publish(result)
        } else {
            statusMessage = muted ? "Input \(inputID) muted in Output Mix." : "Input \(inputID) unmuted in Output Mix."
            log("Input mute handled by software monitor. CoreAudio result: applied=\(result.applied) message=\(String(describing: result.message))")
        }
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
        softwareMonitor.setVolume(inputID: inputID, volume: Float(value))
    }

    private func pushDirectMixToSoftwareMonitor() {
        for input in inputs {
            softwareMonitor.setVolume(inputID: input.id, volume: Float(input.directMixToOutput))
            softwareMonitor.setMuted(inputID: input.id, muted: input.muted)
        }
        log("pushed direct monitor mix to software monitor")
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
        suppressOutputVolumeListener = true
        let coreAudio = self.coreAudio
        let device = selectedDevice
        Task.detached {
            let usbResult = EvoUsbProtocol.setOutputVolume(output: outputID, percent: value)
            let fallback = (!usbResult.applied && device != nil)
                ? coreAudio.setOutputVolume(deviceID: device!.id, channel: UInt32(outputID), value: Float32(value))
                : nil
            await self.applyControlOutcome(usbResult: usbResult, fallback: fallback)
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run { self.suppressOutputVolumeListener = false }
        }
    }

    func setOutputMute(outputID: Int, muted: Bool) {
        updateOutput(outputID) { $0.muted = muted }
        suppressOutputMuteListener = true
        guard let selectedDevice else {
            suppressOutputMuteListener = false
            return
        }
        publish(coreAudio.setMute(deviceID: selectedDevice.id, output: true, channel: UInt32(outputID), muted: muted))
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            suppressOutputMuteListener = false
        }
    }

    func setMonitorBalance(_ value: Double) {
        monitorBalance = max(0, min(1, value))
        UserDefaults.standard.set(monitorBalance, forKey: monitorBalanceDefaultsKey)
        Task.detached {
            let result = EvoUsbProtocol.setMonitorBalance(percent: value)
            await MainActor.run {
                if let msg = result.message { self.log("setMonitorBalance: \(msg)") }
            }
        }
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
        let isFirstSignal = hasSignal && !sawInputSignal
        if hasSignal {
            sawInputSignal = true
        }
        if applyCount <= 5 || isFirstSignal || applyCount % 100 == 1 {
            log("applyInputLevels hasSignal=\(hasSignal) count=\(applyCount) levels=\(levels)")
        }
        for index in inputs.indices {
            let sourceIndex = levelSourceIndex(forInputIndex: index, levelCount: levels.count)
            let rawLevel = sourceIndex < levels.count ? levels[sourceIndex] : 0
            let previous = inputs[index].level
            inputs[index].level = smoothLevel(previous: previous, next: rawLevel)
        }
    }

    private func applyOutputLevels(_ levels: [Double]) {
        outputApplyCount += 1
        let hasSignal = levels.contains { $0 > 0.005 }
        let isFirstSignal = hasSignal && !sawOutputSignal
        if hasSignal {
            sawOutputSignal = true
        }
        if outputApplyCount <= 5 || isFirstSignal || outputApplyCount % 100 == 1 {
            log("applyOutputLevels hasSignal=\(hasSignal) levels=\(levels)")
        }
        let rawLevel = levels.max() ?? 0
        for index in outputs.indices {
            let previous = outputs[index].level
            outputs[index].level = smoothLevel(previous: previous, next: rawLevel)
            outputs[index].hasLevelMeter = true
        }
    }

    private struct HardwareSnapshot: Sendable {
        var gains: [(Int, Double)] = []
        var phantoms: [(Int, Bool)] = []
        var outputVolume: Double?
        var monitorBalance: Double?
    }

    private func requestHardwareControlSync() {
        guard !hardwareSyncInFlight else { return }
        hardwareSyncInFlight = true
        let inputIDs = inputs.map(\.id)
        let disabledPhantomInputs = phantomReadDisabledInputs
        hardwarePollCount += 1
        let pollCount = hardwarePollCount
        Task.detached { [weak self] in
            var snapshot = HardwareSnapshot()
            for inputID in inputIDs {
                if let gain = EvoUsbProtocol.getInputGain(input: inputID) {
                    snapshot.gains.append((inputID, gain))
                }
                if !disabledPhantomInputs.contains(inputID) {
                    let state = EvoUsbProtocol.getPhantomState(input: inputID)
                    if let value = state.value {
                        snapshot.phantoms.append((inputID, value))
                    }
                }
            }
            snapshot.outputVolume = EvoUsbProtocol.getOutputVolume()
            snapshot.monitorBalance = EvoUsbProtocol.getMonitorBalance()
            await self?.applyHardwareSnapshot(snapshot, pollCount: pollCount)
        }
    }

    private func applyHardwareSnapshot(_ snapshot: HardwareSnapshot, pollCount: Int) {
        hardwareSyncInFlight = false
        var changed = false
        for (inputID, gain) in snapshot.gains {
            if let index = inputs.firstIndex(where: { $0.id == inputID }),
               abs(inputs[index].gain - gain) > 0.004 {
                inputs[index].gain = gain
                changed = true
            }
        }
        for (inputID, phantom) in snapshot.phantoms {
            if let index = inputs.firstIndex(where: { $0.id == inputID }),
               inputs[index].phantomPower != phantom {
                inputs[index].phantomPower = phantom
                persistPhantomState(inputID: inputID, enabled: phantom)
                changed = true
            }
        }
        if let vol = snapshot.outputVolume,
           let index = outputs.firstIndex(where: { $0.id == 1 }),
           abs(outputs[index].volume - vol) > 0.004 {
            outputs[index].volume = vol
            changed = true
        }
        if let bal = snapshot.monitorBalance,
           abs(monitorBalance - bal) > 0.004 {
            monitorBalance = bal
            UserDefaults.standard.set(monitorBalance, forKey: monitorBalanceDefaultsKey)
            changed = true
        }
        lastPollFoundChange = changed
        if changed {
            idlePollCount = 0
        } else {
            idlePollCount += 1
        }
        if changed || pollCount <= 3 {
            log("hardwareSync poll=\(pollCount) changed=\(changed) gains=\(snapshot.gains) phantoms=\(snapshot.phantoms) vol=\(String(describing: snapshot.outputVolume)) bal=\(String(describing: snapshot.monitorBalance))")
        }
    }

    private func startHardwarePolling() {
        stopHardwarePolling()
        idlePollCount = 0
        hardwareSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Int
                if let self, self.lastPollFoundChange {
                    interval = 150
                } else if let self, self.idlePollCount < 10 {
                    interval = 300
                } else {
                    interval = 800
                }
                try? await Task.sleep(for: .milliseconds(interval))
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

    private func restorePersistedMonitorBalance() {
        if UserDefaults.standard.object(forKey: monitorBalanceDefaultsKey) != nil {
            monitorBalance = UserDefaults.standard.double(forKey: monitorBalanceDefaultsKey)
        }
    }

    private var monitorBalanceDefaultsKey: String {
        "monitorBalance"
    }

    private var listenedDeviceID: AudioObjectID?

    private func installCoreAudioListeners(deviceID: AudioObjectID) {
        removeCoreAudioListeners()
        listenedDeviceID = deviceID
        let scope = kAudioDevicePropertyScopeOutput

        for ch: UInt32 in [0, 1, 2] {
            coreAudio.addVolumeListener(deviceID: deviceID, scope: scope, channel: ch) { [weak self] devID, _ in
                Task { @MainActor [weak self] in
                    self?.handleOutputVolumeChange(deviceID: devID)
                }
            }
            coreAudio.addMuteListener(deviceID: deviceID, scope: scope, channel: ch) { [weak self] devID, _ in
                Task { @MainActor [weak self] in
                    self?.handleOutputMuteChange(deviceID: devID)
                }
            }
        }
        log("Installed CoreAudio listeners for device \(deviceID)")
        handleOutputVolumeChange(deviceID: deviceID)
        handleOutputMuteChange(deviceID: deviceID)
    }

    private func removeCoreAudioListeners() {
        guard let devID = listenedDeviceID else { return }
        coreAudio.removeAllListeners(deviceID: devID)
        listenedDeviceID = nil
        log("Removed CoreAudio listeners for device \(devID)")
    }

    private func handleOutputVolumeChange(deviceID: AudioObjectID) {
        guard !suppressOutputVolumeListener else { return }
        let vol = coreAudio.getOutputVolume(deviceID: deviceID, channel: 1)
            ?? coreAudio.getOutputVolume(deviceID: deviceID, channel: 0)
        guard let vol else { return }
        let value = Double(vol)
        if let index = outputs.firstIndex(where: { $0.id == 1 }),
           abs(outputs[index].volume - value) > 0.004 {
            outputs[index].volume = value
            log("CoreAudio volume listener: \(value)")
        }
    }

    private func handleOutputMuteChange(deviceID: AudioObjectID) {
        guard !suppressOutputMuteListener else { return }
        let muted = coreAudio.getMute(deviceID: deviceID, output: true, channel: 1)
            ?? coreAudio.getMute(deviceID: deviceID, output: true, channel: 0)
        guard let muted else { return }
        if let index = outputs.firstIndex(where: { $0.id == 1 }),
           outputs[index].muted != muted {
            outputs[index].muted = muted
            log("CoreAudio mute listener: \(muted)")
        }
    }

    private func stopHardwarePolling() {
        hardwareSyncTask?.cancel()
        hardwareSyncTask = nil
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
