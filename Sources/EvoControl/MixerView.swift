import SwiftUI

struct MixerView: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach($store.inputs) { $input in
                        InputStrip(input: $input)
                    }

                    Divider()
                        .frame(height: 340)
                        .padding(.horizontal, 2)

                    ForEach($store.outputs) { $output in
                        OutputStrip(output: $output)
                    }
                }
            }
            .padding(18)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TopBar: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Evo Control")
                    .font(.system(size: 20, weight: .semibold))
                Text(store.statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Device", selection: deviceBinding) {
                if store.devices.isEmpty {
                    Text("No EVO device").tag(Optional<EvoDevice>.none)
                }
                ForEach(store.devices) { device in
                    Text(device.displayName).tag(Optional(device))
                }
            }
            .frame(width: 220)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var deviceBinding: Binding<EvoDevice?> {
        Binding(
            get: { store.selectedDevice },
            set: { store.selectedDevice = $0 }
        )
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InputStrip: View {
    @EnvironmentObject private var store: MixerStore
    @Binding var input: InputChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(input.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    input.muted.toggle()
                    store.setInputMute(inputID: input.id, muted: input.muted)
                } label: {
                    Image(systemName: input.muted ? "mic.slash.fill" : "mic.fill")
                }
                .help(input.muted ? "Unmute" : "Mute")
            }

            Picker("", selection: $input.mode) {
                ForEach(InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MixerChannelControls(
                meterTitle: "Level",
                meterValue: input.level,
                faderTitle: "Gain",
                faderValue: input.gain,
                onFaderChange: {
                    input.gain = $0
                    store.setGain(inputID: input.id, value: $0)
                }
            )

            Toggle(isOn: Binding(
                get: { input.phantomPower },
                set: { newValue in
                    input.phantomPower = newValue
                    store.setPhantom(inputID: input.id, enabled: newValue)
                }
            )) {
                Label("48V", systemImage: "bolt.fill")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(input.phantomPower ? .red : .gray)

            VStack(spacing: 8) {
                HorizontalValueSlider(
                    title: "Output Mix",
                    value: input.directMixToOutput,
                    suffix: percent(input.directMixToOutput),
                    onChange: {
                        input.directMixToOutput = $0
                        store.setDirectMix(inputID: input.id, value: $0)
                    }
                )
            }
        }
        .padding(12)
        .frame(width: 148, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OutputStrip: View {
    @EnvironmentObject private var store: MixerStore
    @Binding var output: OutputChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(output.name)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    output.muted.toggle()
                    store.setOutputMute(outputID: output.id, muted: output.muted)
                } label: {
                    Image(systemName: output.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(output.muted ? "Unmute" : "Mute")
            }

            MixerChannelControls(
                meterTitle: "Level",
                meterValue: output.level,
                meterAvailable: output.hasLevelMeter,
                faderTitle: "Volume",
                faderValue: output.volume,
                onFaderChange: {
                    output.volume = $0
                    store.setOutputVolume(outputID: output.id, value: $0)
                }
            )
        }
        .padding(12)
        .frame(width: 148, alignment: .topLeading)
        .frame(minHeight: 300, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MixerChannelControls: View {
    let meterTitle: String
    let meterValue: Double
    var meterAvailable = true
    let faderTitle: String
    let faderValue: Double
    let onFaderChange: (Double) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VerticalLevelMeter(title: meterTitle, value: meterValue, isAvailable: meterAvailable)
            VerticalFader(title: faderTitle, value: faderValue, onChange: onFaderChange)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HorizontalValueSlider: View {
    let title: String
    let value: Double
    let suffix: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(suffix)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ), in: 0...1)
        }
    }
}

private struct VerticalFader: View {
    let title: String
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(percent(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 42, height: 14)

            GeometryReader { proxy in
                let clamped = max(0, min(1, value))
                let trackHeight = proxy.size.height
                let thumbCenter = trackHeight * (1 - clamped)

                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.28))
                        .frame(width: 8)
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: 8, height: trackHeight * clamped)
                        }

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 42, height: 18)
                        .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                        .overlay {
                            Capsule()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 30, height: 2)
                        }
                        .offset(y: min(max(thumbCenter - 9, 0), trackHeight - 18))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let nextValue = 1 - (gesture.location.y / max(1, trackHeight))
                            onChange(max(0, min(1, nextValue)))
                        }
                )
            }
            .frame(width: 46, height: 160)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent(value))
    }
}

private struct VerticalLevelMeter: View {
    let title: String
    let value: Double
    var isAvailable = true

    var body: some View {
        VStack(spacing: 8) {
            // Fixed single line: the dB string changes width as the level
            // moves ("-inf" ... "-100 dB"), and any wrap or reflow would
            // change this row's height and shift every control below it.
            Text(isAvailable ? dbText(value) : "N/A")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor(value))
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 56, height: 14)

            GeometryReader { proxy in
                let visualLevel: Double = {
                    if !isAvailable { return 0.0 }
                    if value <= 0.000001 { return 0.0 }
                    let db = 20 * log10(value)
                    let minDb: Double = -60.0
                    return max(0.0, min(1.0, (db - minDb) / (-minDb)))
                }()
                let totalHeight = proxy.size.height
                let filledHeight = visualLevel > 0 ? max(2, totalHeight * visualLevel) : 0

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.32))
                        .overlay {
                            MeterTickMarks()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        }

                    VStack(spacing: 0) {
                        Color.red.frame(height: totalHeight * 0.16)
                        Color.yellow.frame(height: totalHeight * 0.20)
                        Color.green.frame(height: totalHeight * 0.64)
                    }
                    .frame(width: 24, height: totalHeight)
                    .mask(alignment: .bottom) {
                        Rectangle()
                            .frame(height: filledHeight)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: levelColor(value).opacity(0.3), radius: 5)
                }
            }
            .frame(width: 24, height: 160)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Level")
        .accessibilityValue(dbText(value))
    }
}

private struct MeterTickMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 1..<8 {
            let y = rect.minY + rect.height * CGFloat(index) / 8
            path.move(to: CGPoint(x: rect.minX + 3, y: y))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: y))
        }
        return path
    }
}

private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// Fixed-width dB readout. Padded so the string length never changes as the
/// level moves, which keeps the monospaced label from reflowing.
private func dbText(_ value: Double) -> String {
    let clamped = max(0.000001, min(1, value))
    let db = 20 * log10(clamped)
    let text = db <= -120 ? "-inf" : "\(Int(db.rounded()))"
    return String(repeating: " ", count: max(0, 4 - text.count)) + text + " dB"
}

private func levelColor(_ value: Double) -> Color {
    switch value {
    case 0.86...:
        return .red
    case 0.68..<0.86:
        return .yellow
    default:
        return .green
    }
}
