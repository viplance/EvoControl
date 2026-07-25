import Foundation

protocol EvoHardwareControlling: Sendable {
    func setPhantomPower(device: EvoDevice?, input: Int, enabled: Bool) -> ControlResult
    func setDirectMonitorMix(device: EvoDevice?, input: Int, output: Int, value: Double) -> ControlResult
}

final class EvoHardwareController: EvoHardwareControlling {
    func setPhantomPower(device: EvoDevice?, input: Int, enabled: Bool) -> ControlResult {
        return EvoUsbProtocol.setPhantom(input: input, enabled: enabled)
    }

    func setDirectMonitorMix(device: EvoDevice?, input: Int, output: Int, value: Double) -> ControlResult {
        return EvoUsbProtocol.setDirectMonitor(input: input, output: output, percent: value)
    }
}
