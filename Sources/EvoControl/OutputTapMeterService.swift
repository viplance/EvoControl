import CEvoAudioTap
import CoreAudio
import Foundation

final class OutputTapMeterService: @unchecked Sendable {
    private let onOutputLevels: @MainActor @Sendable ([Double]) -> Void
    private var meter: OpaquePointer?
    private var callbackCount = 0
    private var sawNonZeroSignal = false
    private var peakPerChannel: [Double] = []

    init(onOutputLevels: @escaping @MainActor @Sendable ([Double]) -> Void) {
        self.onOutputLevels = onOutputLevels
    }

    deinit {
        stop()
    }

    func start(deviceID: AudioObjectID) -> ControlResult {
        stop()
        callbackCount = 0
        sawNonZeroSignal = false
        peakPerChannel = []

        guard #available(macOS 14.2, *) else {
            return ControlResult(applied: false, message: "Output software levels require macOS 14.2 or newer.")
        }

        let uid = deviceUID(deviceID: deviceID)
        guard !uid.isEmpty else {
            return ControlResult(applied: false, message: "Could not read EVO device UID for output tap.")
        }

        guard let meter = evo_audio_tap_create() else {
            return ControlResult(applied: false, message: "Could not allocate output tap meter.")
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let started = uid.withCString { uidPointer in
            evo_audio_tap_start(
                meter,
                uidPointer,
                outputTapLevelCallback,
                outputTapLogCallback,
                context
            )
        }

        guard started else {
            evo_audio_tap_destroy(meter)
            return ControlResult(applied: false, message: "Could not start output software level tap.")
        }

        self.meter = meter
        log("Output tap meter started for uid=\(uid)")
        return ControlResult(applied: true, message: "Software output levels enabled.")
    }

    func stop() {
        guard let meter else { return }
        log("Stopping output tap meter callbacks=\(callbackCount), sawNonZeroSignal=\(sawNonZeroSignal)")
        evo_audio_tap_destroy(meter)
        self.meter = nil
    }

    fileprivate func receiveLevels(_ pointer: UnsafePointer<Float>?, count: Int32) {
        guard let pointer, count > 0 else { return }
        let levels = (0..<Int(count)).map { min(1, max(0, Double(pointer[$0]))) }
        callbackCount += 1
        let hasSignal = levels.contains { $0 > 0.005 }
        let isFirstSignal = hasSignal && !sawNonZeroSignal
        if hasSignal {
            sawNonZeroSignal = true
        }

        if peakPerChannel.count != levels.count {
            peakPerChannel = Array(repeating: 0, count: levels.count)
        }
        for (index, level) in levels.enumerated() {
            peakPerChannel[index] = max(peakPerChannel[index], level)
        }

        if callbackCount <= 5 || isFirstSignal || callbackCount % 250 == 0 {
            log("output tap levels callback=\(callbackCount), hasSignal=\(hasSignal), levels=\(levels)")
        }
        if callbackCount % 250 == 0 {
            let summary = peakPerChannel.enumerated()
                .map { "ch\($0.offset + 1)=\(String(format: "%.1f", 20 * log10(max($0.element, 0.0000001))))dB" }
                .joined(separator: " ")
            log("output tap peak-since-start \(summary)")
        }

        Task { @MainActor [onOutputLevels, levels] in
            onOutputLevels(levels)
        }
    }

    fileprivate func receiveLog(_ pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return }
        log(String(cString: pointer))
    }

    private func deviceUID(deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString>.size,
            alignment: MemoryLayout<CFString>.alignment
        )
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            log("Could not read device UID OSStatus=\(status)")
            return ""
        }
        return buffer.load(as: CFString.self) as String
    }

    private func log(_ message: String) {
        DebugLog.write("OutputTapMeter", message)
    }
}

private let outputTapLevelCallback: EvoAudioTapLevelCallback = { levels, count, context in
    guard let context else { return }
    let service = Unmanaged<OutputTapMeterService>.fromOpaque(context).takeUnretainedValue()
    service.receiveLevels(levels, count: count)
}

private let outputTapLogCallback: EvoAudioTapLogCallback = { message, context in
    guard let context else { return }
    let service = Unmanaged<OutputTapMeterService>.fromOpaque(context).takeUnretainedValue()
    service.receiveLog(message)
}
