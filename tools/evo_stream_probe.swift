import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation

final class ProbeState {
    let sampleRate: Double
    let outputChannels: Int
    let inputChannels: Int
    var phase = 0.0
    var renderCount = 0
    var captureCount = 0
    var peak = [Double]()
    var rmsSum = [Double]()
    var rmsSamples = 0
    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?

    init(sampleRate: Double, inputChannels: Int, outputChannels: Int) {
        self.sampleRate = sampleRate
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.peak = Array(repeating: 0, count: inputChannels)
        self.rmsSum = Array(repeating: 0, count: inputChannels)
    }
}

private func allDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        return []
    }
    var devices = Array(repeating: AudioObjectID(0), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
        return []
    }
    return devices
}

private func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return "" }
    var size = UInt32(MemoryLayout<CFString>.size)
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<CFString>.size,
        alignment: MemoryLayout<CFString>.alignment
    )
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else { return "" }
    return buffer.load(as: CFString.self) as String
}

private func channelCount(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { buffer.deallocate() }
    let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list) == noErr else { return 0 }
    return Int(UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels })
}

private func sampleRate(deviceID: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = Float64(48_000)
    var size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return value
}

private func format(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func makeHALUnit() throws -> AudioUnit {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "HALOutput component not found"])
    }
    var unit: AudioUnit?
    let status = AudioComponentInstanceNew(component, &unit)
    guard status == noErr, let unit else {
        throw NSError(domain: "probe", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "AudioComponentInstanceNew failed \(status)"])
    }
    return unit
}

private let inputCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
    let state = Unmanaged<ProbeState>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = state.inputUnit else { return noErr }
    let frames = Int(frameCount)
    let bufferBytes = UInt32(frames * MemoryLayout<Float32>.size)
    let abl = AudioBufferList.allocate(maximumBuffers: state.inputChannels)
    defer {
        for index in 0..<state.inputChannels {
            abl[index].mData?.deallocate()
        }
        free(abl.unsafeMutablePointer)
    }
    for index in 0..<state.inputChannels {
        abl[index] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: bufferBytes,
            mData: UnsafeMutableRawPointer.allocate(byteCount: Int(bufferBytes), alignment: MemoryLayout<Float32>.alignment)
        )
    }
    let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, abl.unsafeMutablePointer)
    guard status == noErr else { return status }
    state.captureCount += 1
    state.rmsSamples += frames
    for channel in 0..<state.inputChannels {
        guard let data = abl[channel].mData else { continue }
        let samples = data.assumingMemoryBound(to: Float32.self)
        var peak = 0.0
        var sum = 0.0
        for frame in 0..<frames {
            let sample = Double(samples[frame])
            peak = max(peak, abs(sample))
            sum += sample * sample
        }
        state.peak[channel] = max(state.peak[channel], peak)
        state.rmsSum[channel] += sum
    }
    return noErr
}

private let outputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let state = Unmanaged<ProbeState>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let frequency = 997.0
    let increment = 2.0 * Double.pi * frequency / state.sampleRate
    for bufferIndex in 0..<buffers.count {
        guard let data = buffers[bufferIndex].mData else { continue }
        let samples = data.assumingMemoryBound(to: Float32.self)
        let frames = Int(frameCount)
        for frame in 0..<frames {
            let isAudibleChannel = bufferIndex < 2
            samples[frame] = isAudibleChannel ? Float32(sin(state.phase) * 0.18) : 0
            if bufferIndex == 0 {
                state.phase += increment
                if state.phase > 2.0 * Double.pi {
                    state.phase -= 2.0 * Double.pi
                }
            }
        }
    }
    state.renderCount += 1
    return noErr
}

private func db(_ value: Double) -> String {
    if value <= 0.0000001 { return "-inf" }
    return String(format: "%.1f", 20.0 * log10(value))
}

let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 6.0
guard let deviceID = allDevices().first(where: {
    let text = "\(stringProperty($0, selector: kAudioObjectPropertyName)) \(stringProperty($0, selector: kAudioObjectPropertyManufacturer))".lowercased()
    return text.contains("evo") || text.contains("audient")
}) else {
    fatalError("Audient EVO device not found")
}

let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
let manufacturer = stringProperty(deviceID, selector: kAudioObjectPropertyManufacturer)
let sr = sampleRate(deviceID: deviceID)
let inputChannels = max(1, channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput))
let outputChannels = max(1, channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput))
print("device=\(deviceID) \(manufacturer) \(name) sampleRate=\(sr) inputChannels=\(inputChannels) outputChannels=\(outputChannels)")
print("playing 997Hz sine to output ch1/ch2 and capturing all input channels for \(duration)s")

let state = ProbeState(sampleRate: sr, inputChannels: inputChannels, outputChannels: outputChannels)
let inputUnit = try makeHALUnit()
let outputUnit = try makeHALUnit()
state.inputUnit = inputUnit
state.outputUnit = outputUnit

func setUInt32(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: UInt32) {
    var value = value
    let status = AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<UInt32>.size))
    precondition(status == noErr, "AudioUnitSetProperty \(property) failed \(status)")
}

setUInt32(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 1)
setUInt32(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 0)
setUInt32(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 0)
setUInt32(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 1)

var inputDevice = deviceID
var status = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDevice, UInt32(MemoryLayout<AudioObjectID>.size))
precondition(status == noErr, "bind input device failed \(status)")
var outputDevice = deviceID
status = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputDevice, UInt32(MemoryLayout<AudioObjectID>.size))
precondition(status == noErr, "bind output device failed \(status)")

var inputFormat = format(sampleRate: sr, channels: inputChannels)
status = AudioUnitSetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
precondition(status == noErr, "set input stream format failed \(status)")

var outputFormat = format(sampleRate: sr, channels: outputChannels)
status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
precondition(status == noErr, "set output stream format failed \(status)")

var inputCB = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(state).toOpaque())
status = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
precondition(status == noErr, "install input callback failed \(status)")

var outputCB = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: Unmanaged.passUnretained(state).toOpaque())
status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
precondition(status == noErr, "install output callback failed \(status)")

status = AudioUnitInitialize(inputUnit)
precondition(status == noErr, "initialize input failed \(status)")
status = AudioUnitInitialize(outputUnit)
precondition(status == noErr, "initialize output failed \(status)")
status = AudioOutputUnitStart(inputUnit)
precondition(status == noErr, "start input failed \(status)")
status = AudioOutputUnitStart(outputUnit)
precondition(status == noErr, "start output failed \(status)")

let started = Date()
while Date().timeIntervalSince(started) < duration {
    Thread.sleep(forTimeInterval: 0.5)
    let peaks = state.peak.enumerated().map { "ch\($0.offset + 1)=\(db($0.element))dB" }.joined(separator: " ")
    print("live t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s \(peaks)")
}

AudioOutputUnitStop(outputUnit)
AudioOutputUnitStop(inputUnit)
AudioUnitUninitialize(outputUnit)
AudioUnitUninitialize(inputUnit)
AudioComponentInstanceDispose(outputUnit)
AudioComponentInstanceDispose(inputUnit)

let rms = state.rmsSum.enumerated().map { index, sum in
    let value = state.rmsSamples > 0 ? sqrt(sum / Double(state.rmsSamples)) : 0
    return "ch\(index + 1)=peak:\(db(state.peak[index]))dB rms:\(db(value))dB"
}.joined(separator: " ")
print("summary outputRenderCallbacks=\(state.renderCount) inputCaptureCallbacks=\(state.captureCount)")
print(rms)
