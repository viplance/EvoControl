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
