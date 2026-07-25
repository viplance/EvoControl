# Evo Control

SwiftUI macOS mixer app for Apple Silicon Macs and Audient EVO audio interfaces.

## Commands

```bash
pnpm build
pnpm dev
pnpm start
pnpm test
pnpm clean
```

The first version provides the macOS mixer shell, EVO device discovery through CoreAudio, and a hardware-control abstraction for volume/mute plus vendor-specific controls such as 48V phantom power and direct monitor mix.

## EVO 4 hardware notes

Findings below combine official EVO 4 documentation, USB captures and prior
reverse-engineering projects, and local probes against an EVO 4 (VID `0x2708`,
PID `0x0006`). They are recorded here because most USB-control details are not
documented anywhere public.

### USB access on macOS

Control writes use `bmRequestType` `0x21` (SET) with `bRequest = 0x01`.
Payloads are 2 or 4 bytes depending on the block.

**Do not detach the kernel driver or claim an interface.** SET transfers work
alongside the macOS USB-audio class driver. Calling
`libusb_detach_kernel_driver` as root can remove the device from CoreAudio
entirely — it vanishes from the audio device list until the cable is replugged
or `coreaudiod` is restarted. The Linux tools listed below detach because on
Linux that operation is routine and reversible; on macOS it is not.

Opening the device once and caching the handle matters: opening and closing per
call costs ~1.94 ms versus ~0.302 ms on a cached handle, and doing it on the
main thread made the UI visibly lag.

Current macOS probes did **not** find a reliable read path for vendor state:
`0xA1/0x01` and related GET variants returned `LIBUSB_ERROR_IO` for lengths
1/2/3/4/6/8, and the interrupt endpoint (`0x83`) cannot be claimed while the
Apple USB-audio class driver owns interface 0. As a result, hardware state
changed from the physical device (for example 48V) cannot currently be trusted
to sync back into the app through this path; app-initiated writes must be
tracked locally unless a new event/read path is found.

### Control blocks

| `wIndex` | Block | Payload |
| --- | --- | --- |
| `0x3A00` | Inputs: phantom power, preamp gain | 4 bytes |
| `0x3B00` | Output level | 2-byte Q8.8 dB |
| `0x3C00` | Monitor mix matrix | 2-byte Q8.8 dB |

Volume values are little-endian signed **Q8.8 dB**: `raw = dB * 256`, so
`0x0000` is 0 dB (unity) and `0x8000` is -128 dB (mute). An earlier
implementation sent hand-built 4-byte step tables to `0x3B00` and `0x3C00`;
the device ignores those.

### Output topology

The EVO 4 has a **single output pair**, shared by the speaker outputs and the
headphone jack:

```
0x3B00 / 0x0000 = left      always equal
0x3B00 / 0x0001 = right     always equal
0x3B00 / 0x0002..0x0008 = -127.5 dB   not implemented
```

The user manual and Audient's smart-muting support article agree: the Volume
control applies to both the monitor outputs and the headphone output, and EVO 4
does not provide independent speaker/headphone mixes. There is no independent
"Monitor" level — a separate Monitor strip in the UI would write the same
hardware control as Output. Both sides of the pair must be written together.

A CoreAudio control probe also exposes output volume controls only for elements
1 and 2 (the stereo pair). Elements 3/4 do not expose volume or mute controls,
so a separate Phone/Monitor balance cannot currently be implemented through
CoreAudio either.

### Monitor mix matrix (0x3C00) — not usable on macOS

Addressed as `wValue = 0x0100 + input * 4 + output`, so mic 1 occupies
`0x0100..0x0103` and mic 2 `0x0104..0x0107`. On the EVO 8 the source list runs
mic 1-4, DAW 1-4, loopback 1-2.

Diagnostic testing (July 2025) proved that **Unit 0x3C is not in the DAW
playback signal path on macOS**:

1. **Driver override test:** wrote -12 dB to MIC1→OUT1, read back at t=0,
   100ms, 500ms, 2000ms — the value persists. The macOS class driver does NOT
   overwrite mixer coefficients.
2. **Full matrix scan:** all 64 slots (0x0100..0x013F) are readable and return
   0 dB. Every write lands and reads back correctly.
3. **Mute-all test:** muted all 64 slots to -128 dB while playing music —
   **audio continued uninterrupted**. The mixer unit is not in the DAW→speaker
   path.
4. **Control test:** muting the output block (0x3B00) cuts audio immediately,
   confirming the test methodology works.

On Linux, `evoctl` claims interface 0 (detaching ALSA), which likely gives the
mixer unit control over routing. On macOS, the AppleUSBAudio class driver owns
the interface and routes DAW playback to the speaker output directly, bypassing
the mixer unit. Hardware direct monitoring via 0x3C00 is therefore not
achievable without detaching the class driver, which removes the device from
CoreAudio.

**Software monitoring** (routing input back to output via AVAudioEngine) is
used instead. This adds ~5–10 ms of latency at a 128-sample buffer but works
within the constraints of the macOS audio stack.

### Input channels and metering

CoreAudio exposes 4 input channels. The first two are named **"Mix 1"** and
**"Mix 2"** — these are an internal mix, not the raw preamps; the remaining two
are unnamed. Level metering currently reads digital silence (-140 dB) on all
four, while channel 1 shows an analogue noise floor around -81 dB. An
independent AVAudioEngine probe reads the same silence, so the signal is not
reaching the host rather than being lost in this app.

Output level metering is not implemented: the HAL unit is opened for input
only, and the device does not expose an output meter over these control blocks.

For Linux channel-topology context, see the ALSA UCM pull request listed below:
it describes EVO 4 as a 4-in/4-out USB device with 2 analogue mono inputs, one
analogue stereo output, and loopback/mixer channels occupying the remaining
host-visible channels.

## References

### Official documentation

- [EVO 4 product page and features](https://audient.com/products/audio-interfaces/evo-4/features/)
- [EVO 4 technical specifications](https://audient.com/products/audio-interfaces/evo-4/tech-specs/)
- [EVO 4 official downloads and user guides](https://audient.com/products/audio-interfaces/evo-4/downloads/)
- [Smart-muting monitor outputs on EVO 4](https://support.audient.com/hc/en-us/articles/360050410891-Smart-Muting-Monitor-Outputs-on-EVO-4)
- [EVO 4 driver and manual downloads](https://support.audient.com/hc/en-us/articles/360050548571-EVO-4-Driver-and-Manual-Downloads)
- [Why am I getting no signal from my inputs?](https://support.audient.com/hc/en-us/articles/360050419831-Why-am-I-getting-no-signal-from-my-Inputs)

### Reverse-engineering prior art

All three projects derived the protocol by capturing USB traffic from the
official EVO Control app with Wireshark.

- [soerenbnoergaard/evoctl](https://github.com/soerenbnoergaard/evoctl) — the
  most complete source for the mix matrix and the Q8.8 dB encoding; see
  `src/main.cxx` and
  [`doc/usb_control_messages.ods`](https://github.com/soerenbnoergaard/evoctl/blob/main/doc/usb_control_messages.ods).
- [vijay-prema/audient-evo-linux-tools](https://github.com/vijay-prema/audient-evo-linux-tools)
  — concise Python reference for phantom power, gain, and headphone volume; see
  [`evo-settings.py`](https://github.com/vijay-prema/audient-evo-linux-tools/blob/main/evo-settings.py).
- [subsubl/Evo4mixer](https://github.com/subsubl/Evo4mixer) — EVO 4 specific
  Linux mixer.

### Channel topology references

- [ALSA UCM pull request for Audient EVO 4](https://github.com/alsa-project/alsa-ucm-conf/pull/708)
  — useful independent note on EVO 4 host-visible channel topology.
- [ALSA-devel mirror of the same EVO 4 UCM discussion](https://www.spinics.net/lists/alsa-devel/msg180057.html)
  — easier to read without GitHub UI state.
