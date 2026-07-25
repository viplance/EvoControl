import CEvoUsb
import Foundation

/// Serialises every libusb call onto a background executor.
///
/// The previous design opened and closed the device on each call from the main
/// actor, so UI interactions paid the full init/open/transfer/close cost and any
/// USB stall froze the window. All hardware access now goes through this actor;
/// the main thread only ever awaits a result.
actor EvoUsbConnection {
    static let shared = EvoUsbConnection()

    /// Whether the vendor control endpoint answered the last probe.
    private(set) var isControlAvailable = false
    private var didProbe = false
    private var lastFailureMessage: String?

    /// Opens the device and checks whether control transfers actually work.
    /// Cached: the expensive part runs once.
    @discardableResult
    func probe() -> (available: Bool, message: String?) {
        if didProbe {
            return (isControlAvailable, lastFailureMessage)
        }
        didProbe = true

        var error = [CChar](repeating: 0, count: 256)
        let status = evo_usb_probe(&error, Int32(error.count))
        isControlAvailable = status == 0
        lastFailureMessage = status == 0 ? nil : Self.string(from: error)

        DebugLog.write(
            "EvoUsb",
            "probe: available=\(isControlAvailable) status=\(status) message=\(lastFailureMessage ?? "none")"
        )
        return (isControlAvailable, lastFailureMessage)
    }

    /// Sends a control write. Never gated behind a probe: the device accepts
    /// SET transfers even though it answers no reads, so the write itself is
    /// the only reliable indicator of success.
    func set(wValue: UInt16, wIndex: UInt16, data: [UInt8]) -> ControlResult {
        var payload = data
        var error = [CChar](repeating: 0, count: 256)
        let count = payload.count
        let status = payload.withUnsafeMutableBufferPointer { buffer in
            evo_usb_control_set(wValue, wIndex, buffer.baseAddress, Int32(count), &error, Int32(error.count))
        }

        guard status == 0 else {
            let message = Self.string(from: error)
            return ControlResult(
                applied: false,
                message: message.isEmpty ? "EVO USB command failed with status \(status)." : "EVO USB command failed: \(message)."
            )
        }
        return ControlResult(applied: true, message: nil)
    }

    func get(wValue: UInt16, wIndex: UInt16, length: Int) -> [UInt8]? {
        var payload = [UInt8](repeating: 0, count: length)
        var error = [CChar](repeating: 0, count: 256)
        let count = payload.count
        let status = payload.withUnsafeMutableBufferPointer { buffer in
            evo_usb_control_get(wValue, wIndex, buffer.baseAddress, Int32(count), &error, Int32(error.count))
        }
        return status == 0 ? payload : nil
    }

    func shutdown() {
        evo_usb_close()
        didProbe = false
        isControlAvailable = false
    }

    private static func string(from error: [CChar]) -> String {
        error.prefix { $0 != 0 }.withUnsafeBufferPointer { buffer in
            String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
