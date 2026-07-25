import CEvoUsb
import Foundation

enum EvoUsbProtocol {
    static func getPhantom(input: Int) -> Bool? {
        getPhantomState(input: input).value
    }

    static func getPhantomState(input: Int) -> (value: Bool?, error: String?) {
        let result = read(
            wValue: 0x0000 + UInt16(max(0, input - 1)),
            wIndex: 0x3A00,
            length: 4
        )
        guard let data = result.data else {
            return (value: nil, error: result.error ?? "USB read failed")
        }
        return (value: (data.first ?? 0) != 0, error: nil)
    }

    static func getInputGain(input: Int) -> Double? {
        let result = read(
            wValue: 0x0100 + UInt16(max(0, input - 1)),
            wIndex: 0x3A00,
            length: 4
        )
        guard let data = result.data, let step = gainStep(bytes: data) else {
            return nil
        }

        return Double(step) / 117.0
    }

    static func setPhantom(input: Int, enabled: Bool) -> ControlResult {
        send(
            wValue: 0x0000 + UInt16(max(0, input - 1)),
            wIndex: 0x3A00,
            data: [enabled ? 0x01 : 0x00, 0x00, 0x00, 0x00]
        )
    }

    static func setInputGain(input: Int, percent: Double) -> ControlResult {
        let step = Int((clamped(percent) * 117).rounded())
        return send(
            wValue: 0x0100 + UInt16(max(0, input - 1)),
            wIndex: 0x3A00,
            data: gainBytes(step: step)
        )
    }

    static func setOutputVolume(output: Int, percent: Double) -> ControlResult {
        let step = Int((clamped(percent) * 160).rounded())
        return send(
            wValue: 0x0000 + UInt16(max(0, output - 1)),
            wIndex: 0x3B00,
            data: outputBytes(step: step)
        )
    }

    static func setDirectMonitor(input: Int, output: Int, percent: Double) -> ControlResult {
        let step = Int((clamped(percent) * 180).rounded())
        return send(
            wValue: 0x0100 + UInt16(max(0, input - 1) * 4 + max(0, output - 1)),
            wIndex: 0x3C00,
            data: monitorBytes(step: step)
        )
    }

    private static func send(wValue: UInt16, wIndex: UInt16, data: [UInt8]) -> ControlResult {
        var payload = data
        var error = Array(repeating: CChar(0), count: 256)
        let payloadCount = payload.count
        let status = payload.withUnsafeMutableBufferPointer { buffer in
            evo_usb_control_set(
                wValue,
                wIndex,
                buffer.baseAddress,
                Int32(payloadCount),
                &error,
                Int32(error.count)
            )
        }

        guard status == 0 else {
            let message = errorMessage(error)
            return ControlResult(
                applied: false,
                message: message.isEmpty ? "EVO USB command failed with status \(status)." : "EVO USB command failed: \(message)."
            )
        }

        return ControlResult(applied: true, message: nil)
    }

    private static func read(wValue: UInt16, wIndex: UInt16, length: Int) -> (data: [UInt8]?, error: String?) {
        var payload = Array(repeating: UInt8(0), count: length)
        var error = Array(repeating: CChar(0), count: 256)
        let payloadCount = payload.count
        let status = payload.withUnsafeMutableBufferPointer { buffer in
            evo_usb_control_get(
                wValue,
                wIndex,
                buffer.baseAddress,
                Int32(payloadCount),
                &error,
                Int32(error.count)
            )
        }

        guard status == 0 else {
            let message = errorMessage(error)
            return (data: nil, error: message.isEmpty ? "status \(status)" : message)
        }

        return (data: payload, error: nil)
    }

    private static func errorMessage(_ error: [CChar]) -> String {
        error.prefix { $0 != 0 }.withUnsafeBufferPointer { buffer in
            String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func clamped(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private static func gainBytes(step rawStep: Int) -> [UInt8] {
        var step = max(0, min(117, rawStep))
        let base: Int
        let tail: [UInt8]

        if step < 16 {
            base = 248
            tail = [0xFF, 0xFF]
        } else {
            base = 0
            step -= 16
            tail = [0x00, 0x00]
        }

        return [
            step.isMultiple(of: 2) ? 0x00 : 0x80,
            UInt8((base + (step / 2)) & 0xFF),
            tail[0],
            tail[1]
        ]
    }

    private static func gainStep(bytes: [UInt8]) -> Int? {
        let steps = (0...117).map { gainBytes(step: $0) }
        return steps.firstIndex { Array($0.prefix(4)) == Array(bytes.prefix(4)) }
    }

    private static func outputBytes(step rawStep: Int) -> [UInt8] {
        let steps = generateOutputBytes()
        return steps[max(0, min(steps.count - 1, rawStep))]
    }

    private static func monitorBytes(step rawStep: Int) -> [UInt8] {
        let steps = generateMonitorBytes()
        return steps[max(0, min(steps.count - 1, rawStep))]
    }

    private static func generateOutputBytes() -> [[UInt8]] {
        var steps: [[UInt8]] = []
        func add(_ b0: UInt8, _ b1: UInt8) {
            steps.append([b0, b1, 0xFF, 0xFF])
        }

        add(0x00, 0x80)
        add(0x00, 0x81)
        for b1 in 0x84...0xE0 {
            add(0x00, UInt8(b1))
        }
        for b1 in 0xE0...0xFE {
            add(0x00, UInt8(b1))
            add(0x80, UInt8(b1))
        }
        add(0x00, 0xFF)
        add(0x80, 0xFF)
        add(0x00, 0x00)
        return steps
    }

    private static func generateMonitorBytes() -> [[UInt8]] {
        var steps: [[UInt8]] = []
        func add(_ b0: UInt8, _ b1: UInt8) {
            steps.append([b0, b1, 0xFF, 0xFF])
        }

        stride(from: 0x80, to: 0xD0, by: 0x06).forEach { add(0x00, UInt8($0)) }
        for b1 in 0xD0..<0xE4 {
            add(0x00, UInt8(b1))
            add(0x80, UInt8(b1))
        }
        for b1 in 0xE4..<0xF3 {
            [0x00, 0x40, 0x80, 0xC0].forEach { add(UInt8($0), UInt8(b1)) }
        }
        for b1 in 0xF3..<0x100 {
            [0x00, 0x34, 0x67, 0x9A, 0xCD].forEach { add(UInt8($0), UInt8(b1)) }
        }
        steps.append([0x00, 0x00, 0xFF, 0xFF])
        return steps
    }
}
