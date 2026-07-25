import AudioToolbox
import CoreAudio
import Foundation

final class SoftwareMonitorService: @unchecked Sendable {
    fileprivate var audioUnit: AudioUnit?
    private var isRunning = false
    fileprivate var input1Volume: Float = 0
    fileprivate var input2Volume: Float = 0
    fileprivate var inputChannelCount: UInt32 = 4
    fileprivate var renderCount = 0
    fileprivate var renderErrorCount = 0

    func start(deviceID: AudioObjectID) -> ControlResult {
        stop()
        renderCount = 0
        renderErrorCount = 0

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            return ControlResult(applied: false, message: "HAL AudioUnit not found.")
        }

        var unit: AudioUnit?
        var s = AudioComponentInstanceNew(comp, &unit)
        guard s == noErr, let unit else {
            return ControlResult(applied: false, message: "AudioUnit create failed: \(s)")
        }

        var one: UInt32 = 1
        s = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &one, 4)
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Enable input failed: \(s)")
        }

        // Output is enabled by default on bus 0, but be explicit
        s = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0, &one, 4)
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Enable output failed: \(s)")
        }

        var devID = deviceID
        s = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &devID,
                                 UInt32(MemoryLayout<AudioObjectID>.size))
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Bind device failed: \(s)")
        }

        let rate = nominalSampleRate(deviceID)
        let bufferResult = requestLowLatencyBuffer(deviceID: deviceID, sampleRate: rate)
        inputChannelCount = max(1, channelCount(deviceID, scope: kAudioDevicePropertyScopeInput))
        log("device sampleRate=\(rate), inputChannels=\(inputChannelCount), \(bufferResult)")

        // Capture every host-visible EVO input channel. The later channels can
        // include loopback/mix content, so the monitor path only uses the first
        // pair below to avoid feeding our own output back into itself.
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: inputChannelCount, mBitsPerChannel: 32, mReserved: 0
        )
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )

        s = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, &inputFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Set input bus format failed: \(s)")
            return ControlResult(applied: false, message: "Input format failed: \(s)")
        }

        s = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0, &outputFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            log("Set output bus format failed: \(s)")
            return ControlResult(applied: false, message: "Output format failed: \(s)")
        }

        var cb = AURenderCallbackStruct(
            inputProc: monitorCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        s = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Input, 0, &cb,
                                 UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Callback install failed: \(s)")
        }

        s = AudioUnitInitialize(unit)
        guard s == noErr else {
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Initialize failed: \(s)")
        }

        s = AudioOutputUnitStart(unit)
        guard s == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return ControlResult(applied: false, message: "Start failed: \(s)")
        }

        audioUnit = unit
        isRunning = true
        log("Started for device \(deviceID)")
        return ControlResult(applied: true, message: nil)
    }

    func stop() {
        guard isRunning, let unit = audioUnit else { return }
        log("Stopping")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        isRunning = false
    }

    func setVolume(inputID: Int, volume: Float) {
        let clamped = max(0, min(1, volume))
        if inputID == 1 {
            input1Volume = clamped
        } else if inputID == 2 {
            input2Volume = clamped
        }
        log("setVolume input=\(inputID) volume=\(clamped)")
    }

    private func nominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(48000)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return rate
    }

    private func requestLowLatencyBuffer(deviceID: AudioObjectID, sampleRate: Double) -> String {
        var requestedFrames: UInt32 = 64
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &requestedFrames
        )

        var actualFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actualFrames)
        let requestedMs = Double(requestedFrames) / sampleRate * 1000
        let actualMs = readStatus == noErr ? Double(actualFrames) / sampleRate * 1000 : 0
        if status == noErr, readStatus == noErr {
            return String(format: "bufferFrames=%u requested=%.2fms actual=%.2fms", actualFrames, requestedMs, actualMs)
        }
        return "bufferFrameSize request failed setStatus=\(status) readStatus=\(readStatus)"
    }

    private func channelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 2
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else {
            return 2
        }

        return UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func log(_ message: String) {
        DebugLog.write("SoftwareMonitor", message)
    }
}

// Render callback: read from input bus 1, scale by volume, write to ioData (output bus 0).
private let monitorCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
    let svc = Unmanaged<SoftwareMonitorService>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = svc.audioUnit, let ioData else { return noErr }

    let frames = Int(inNumberFrames)
    let inputChannels = Int(svc.inputChannelCount)
    let byteSize = UInt32(frames * MemoryLayout<Float32>.size)
    let inputBuffers = AudioBufferList.allocate(maximumBuffers: inputChannels)
    defer {
        for index in 0..<inputChannels {
            inputBuffers[index].mData?.deallocate()
        }
        free(inputBuffers.unsafeMutablePointer)
    }

    for index in 0..<inputChannels {
        inputBuffers[index] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer.allocate(
                byteCount: Int(byteSize),
                alignment: MemoryLayout<Float32>.alignment
            )
        )
    }

    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, inputBuffers.unsafeMutablePointer)
    guard status == noErr else {
        svc.renderErrorCount += 1
        if svc.renderErrorCount <= 5 || svc.renderErrorCount % 100 == 0 {
            DebugLog.write("SoftwareMonitor", "AudioUnitRender failed OSStatus=\(status) count=\(svc.renderErrorCount)")
        }
        let outBufs = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in outBufs {
            if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
        }
        return noErr
    }

    svc.renderCount += 1
    let source1 = 0
    let source2 = min(1, max(0, inputChannels - 1))
    let input1 = inputBuffers[source1].mData?.assumingMemoryBound(to: Float32.self)
    let input2 = inputBuffers[source2].mData?.assumingMemoryBound(to: Float32.self)
    let monitorGain: Float = 0.75
    let volume1 = svc.input1Volume * monitorGain
    let volume2 = svc.input2Volume * monitorGain

    let outBufs = UnsafeMutableAudioBufferListPointer(ioData)
    for bufferIndex in 0..<outBufs.count {
        guard let data = outBufs[bufferIndex].mData else { continue }
        let output = data.assumingMemoryBound(to: Float32.self)
        for frame in 0..<frames {
            let mixed = (input1?[frame] ?? 0) * volume1 + (input2?[frame] ?? 0) * volume2
            output[frame] = tanhf(mixed)
        }
    }
    if svc.renderCount <= 5 || svc.renderCount % 250 == 0 {
        DebugLog.write("SoftwareMonitor", "render count=\(svc.renderCount) source1=ch\(source1 + 1) source2=ch\(source2 + 1) volume1=\(volume1) volume2=\(volume2) outputs=\(outBufs.count)")
    }
    return noErr
}
