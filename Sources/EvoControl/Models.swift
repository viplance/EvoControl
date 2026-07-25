import Foundation

enum InputMode: String, CaseIterable, Identifiable {
    case microphone = "Mic"
    case instrument = "Inst"

    var id: String { rawValue }
}

struct InputChannel: Identifiable, Equatable {
    let id: Int
    var name: String
    var mode: InputMode
    var gain: Double
    var phantomPower: Bool
    var muted: Bool
    var directMixToOutput: Double
    var level: Double
}

struct OutputChannel: Identifiable, Equatable {
    let id: Int
    var name: String
    var volume: Double
    var muted: Bool
    var level: Double
    var hasLevelMeter: Bool
}

struct EvoDevice: Identifiable, Equatable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let manufacturer: String

    var displayName: String {
        manufacturer.isEmpty ? name : "\(manufacturer) \(name)"
    }
}

struct ControlResult: Sendable {
    let applied: Bool
    let message: String?
}
