import SwiftUI

private let channelStripHeight: CGFloat = 280
private let bottomControlHeight: CGFloat = 58

struct MixerView: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach($store.inputs) { $input in
                        InputStrip(input: $input)
                    }

                    Divider()
                        .frame(height: channelStripHeight)
                        .padding(.horizontal, 2)

                    ForEach($store.outputs) { $output in
                        OutputStrip(output: $output)
                    }
                }
            }
            .padding(10)
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
                    .font(.system(size: 16, weight: .semibold))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(input.name)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    MuteIconButton(
                        isMuted: input.muted,
                        mutedIcon: "mic.slash.fill",
                        unmutedIcon: "mic.fill",
                        action: {
                        input.muted.toggle()
                        store.setInputMute(inputID: input.id, muted: input.muted)
                        }
                    )
                }

                MixerChannelControls(
                    meterTitle: "Level",
                    meterValue: input.level,
                    faderTitle: "Gain",
                    faderValue: input.gain,
                    muted: input.muted,
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
            }

            Spacer(minLength: 0)

            HorizontalValueSlider(
                title: "Output Mix",
                value: input.directMixToOutput,
                suffix: percent(input.directMixToOutput),
                muted: input.muted,
                onChange: {
                    input.directMixToOutput = $0
                    store.setDirectMix(inputID: input.id, value: $0)
                }
            )
            .frame(height: bottomControlHeight)
        }
        .padding(10)
        .frame(width: 132)
        .frame(minHeight: channelStripHeight, maxHeight: channelStripHeight, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OutputStrip: View {
    @EnvironmentObject private var store: MixerStore
    @Binding var output: OutputChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    Text(output.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(height: 24, alignment: .center)
                    Spacer(minLength: 8)
                    MuteIconButton(
                        isMuted: output.muted,
                        mutedIcon: "speaker.slash.fill",
                        unmutedIcon: "speaker.wave.2.fill",
                        action: {
                        output.muted.toggle()
                        store.setOutputMute(outputID: output.id, muted: output.muted)
                        }
                    )
                }

                MixerChannelControls(
                    meterTitle: "Level",
                    meterValue: output.level,
                    meterAvailable: output.hasLevelMeter,
                    faderTitle: "Volume",
                    faderValue: output.volume,
                    muted: output.muted,
                    onFaderChange: {
                        output.volume = $0
                        store.setOutputVolume(outputID: output.id, value: $0)
                    }
                )
            }

            Spacer(minLength: 0)

            MicOutputBalanceLever(
                value: store.monitorBalance,
                muted: output.muted,
                onChange: { store.setMonitorBalance($0) }
            )
            .frame(height: bottomControlHeight)
        }
        .padding(10)
        .frame(width: 132)
        .frame(minHeight: channelStripHeight, maxHeight: channelStripHeight, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MuteIconButton: View {
    let isMuted: Bool
    let mutedIcon: String
    let unmutedIcon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? mutedIcon : unmutedIcon)
                .font(.system(size: 13, weight: .semibold))
                .symbolVariant(.none)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .help(isMuted ? "Unmute" : "Mute")
    }
}

private struct MicOutputBalanceLever: View {
    let value: Double
    var muted = false
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Mic", systemImage: "mic.fill")
                    .labelStyle(.iconOnly)
                    .help("Mic")
                Spacer()
                Label("Output", systemImage: "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
                    .help("Output")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: 0...1)
            .controlSize(.small)
            .tint(muted ? .gray : nil)

            HStack {
                Text("Mic")
                Spacer()
                Text("Output")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help("Balance between direct microphone monitoring and DAW output")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mic Output Balance")
        .accessibilityValue("\(Int((value * 100).rounded()))% output")
    }
}

private struct MixerChannelControls: View {
    let meterTitle: String
    let meterValue: Double
    var meterAvailable = true
    let faderTitle: String
    let faderValue: Double
    var muted = false
    let onFaderChange: (Double) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VerticalLevelMeter(title: meterTitle, value: meterValue, isAvailable: meterAvailable)
            VerticalFader(title: faderTitle, value: faderValue, muted: muted, onChange: onFaderChange)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HorizontalValueSlider: View {
    let title: String
    let value: Double
    let suffix: String
    var muted = false
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(suffix)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(
                get: { value },
                set: { newValue in onChange(newValue) }
            ), in: 0...1)
            .controlSize(.small)
            .tint(muted ? .gray : nil)
        }
    }
}

private struct VerticalFader: View {
    let title: String
    let value: Double
    var muted = false
    let onChange: (Double) -> Void

    private var fillColor: Color {
        muted ? Color.gray.opacity(0.5) : Color.accentColor.opacity(0.8)
    }

    var body: some View {
        VStack(spacing: 4) {
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
                                .fill(fillColor)
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
            .frame(width: 46, height: 110)

            Text(title)
                .font(.system(size: 11, weight: .medium))
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
        VStack(spacing: 4) {
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
            .frame(width: 24, height: 110)

            Text(title)
                .font(.system(size: 11, weight: .medium))
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
