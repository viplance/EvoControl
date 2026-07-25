import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation

final class AudioLevelMeterService: @unchecked Sendable {
    private let onInputLevels: @MainActor @Sendable ([Double]) -> Void
    private var audioUnit: AudioUnit?
    private var channelCount: UInt32 = 2
    private var renderCount = 0
    private var renderErrorCount = 0
    private var sawNonZeroSignal = false
    private var peakPerChannel: [Double] = []

    init(onInputLevels: @escaping @MainActor @Sendable ([Double]) -> Void) {
        self.onInputLevels = onInputLevels
    }

    deinit {
        stop()
    }

    func start(deviceID: AudioObjectID) -> ControlResult {
        stop()
        renderCount = 0
        renderErrorCount = 0
        sawNonZeroSignal = false
        log("Starting HAL meter for deviceID=\(deviceID), name=\(deviceName(deviceID: deviceID))")

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            return ControlResult(applied: false, message: "HAL input AudioUnit was not found.")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            log("AudioComponentInstanceNew failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not create HAL input AudioUnit: OSStatus \(status).")
        }

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Enable input failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not enable HAL input: OSStatus \(status).")
        }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Disable output failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not disable HAL output: OSStatus \(status).")
        }

        var selectedDevice = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Bind device failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not bind HAL meter to EVO: OSStatus \(status).")
        }

        logChannelLayout(deviceID: deviceID)
        channelCount = max(1, inputChannelCount(deviceID: deviceID))
        let sampleRate = inputSampleRate(deviceID: deviceID)
        log("HAL meter device channels=\(channelCount), sampleRate=\(sampleRate)")
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Set stream format failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not configure HAL meter format: OSStatus \(status).")
        }

        var callback = AURenderCallbackStruct(
            inputProc: meterRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Install callback failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not install HAL meter callback: OSStatus \(status).")
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Initialize failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not initialize HAL meter: OSStatus \(status).")
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            log("Start failed OSStatus=\(status)")
            return ControlResult(applied: false, message: "Could not start HAL meter: OSStatus \(status).")
        }

        audioUnit = unit
        log("HAL meter started successfully")
        return ControlResult(applied: true, message: "Live levels enabled from \(deviceName(deviceID: deviceID)).")
    }

    func stop() {
        guard let audioUnit else { return }
        log("Stopping HAL meter after renderCount=\(renderCount), renderErrorCount=\(renderErrorCount), sawNonZeroSignal=\(sawNonZeroSignal)")
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
    }

    fileprivate func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let audioUnit else { return noErr }
        renderCount += 1

        let frames = Int(frameCount)
        let channels = Int(channelCount)
        let bufferByteSize = UInt32(frames * MemoryLayout<Float32>.size)
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: channels)
        defer {
            for index in 0..<channels {
                audioBufferList[index].mData?.deallocate()
            }
            free(audioBufferList.unsafeMutablePointer)
        }

        for index in 0..<channels {
            audioBufferList[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: bufferByteSize,
                mData: UnsafeMutableRawPointer.allocate(
                    byteCount: Int(bufferByteSize),
                    alignment: MemoryLayout<Float32>.alignment
                )
            )
        }

        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timestamp,
            1,
            frameCount,
            audioBufferList.unsafeMutablePointer
        )
        guard status == noErr else {
            renderErrorCount += 1
            if renderErrorCount <= 10 || renderErrorCount % 100 == 0 {
                log("AudioUnitRender failed OSStatus=\(status), count=\(renderErrorCount)")
            }
            return status
        }

        let levels = (0..<channels).map { channel in
            guard let data = audioBufferList[channel].mData else { return 0.0 }
            let samples = data.assumingMemoryBound(to: Float32.self)
            var peak = 0.0
            for index in 0..<frames {
                peak = max(peak, abs(Double(samples[index])))
            }
            return min(1, peak)
        }
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

        if renderCount <= 5 || isFirstSignal || renderCount % 250 == 0 {
            log("render count=\(renderCount), frames=\(frames), levels=\(levels), hasSignal=\(hasSignal)")
        }
        if renderCount % 250 == 0 {
            let summary = peakPerChannel.enumerated()
                .map { "ch\($0.offset)=\(String(format: "%.1f", 20 * log10(max($0.element, 0.0000001))))dB" }
                .joined(separator: " ")
            log("peak-since-start \(summary)")
        }

        Task { @MainActor [onInputLevels, levels] in
            onInputLevels(levels)
        }
        return noErr
    }

    private func inputSampleRate(deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : 48_000
    }

    private func logChannelLayout(deviceID: AudioObjectID) {
        for (scopeName, scope) in [
            ("input", kAudioDevicePropertyScopeInput),
            ("output", kAudioDevicePropertyScopeOutput)
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
                log("layout \(scopeName): no stream configuration")
                continue
            }

            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { buffer.deallocate() }

            let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else {
                log("layout \(scopeName): could not read stream configuration")
                continue
            }

            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let perBuffer = buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: " + ")
            let total = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
            log("layout \(scopeName): \(buffers.count) buffer(s) [\(perBuffer)] total=\(total)ch")

            for element in 1...max(1, Int(total)) {
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyElementName,
                    mScope: scope,
                    mElement: AudioObjectPropertyElement(element)
                )
                guard AudioObjectHasProperty(deviceID, &nameAddress) else { continue }
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                let nameBuffer = UnsafeMutableRawPointer.allocate(
                    byteCount: MemoryLayout<CFString>.size,
                    alignment: MemoryLayout<CFString>.alignment
                )
                defer { nameBuffer.deallocate() }
                guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, nameBuffer) == noErr else { continue }
                log("layout \(scopeName) ch\(element): \(nameBuffer.load(as: CFString.self) as String)")
            }
        }
    }

    private func inputChannelCount(deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 2 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list)
        guard status == noErr else { return 2 }

        return UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func deviceName(deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
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
        guard status == noErr else { return "EVO" }
        return buffer.load(as: CFString.self) as String
    }

    private func log(_ message: String) {
        DebugLog.write("AudioLevelMeter", message)
    }
}

private let meterRenderCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let meter = Unmanaged<AudioLevelMeterService>.fromOpaque(refCon).takeUnretainedValue()
    return meter.render(
        actionFlags: actionFlags,
        timestamp: timestamp,
        busNumber: busNumber,
        frameCount: frameCount
    )
}
