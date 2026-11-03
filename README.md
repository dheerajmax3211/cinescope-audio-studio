# CineScope Audio Studio

A native macOS workspace for AI-assisted film audio: speech, score, sound effects, clip editing, and mixdown.

## Build

Requirements: macOS 13 or later and Xcode Command Line Tools.

```sh
./build.sh
open build/CineScope.app
```

The app's Settings screen installs the local Stable Audio MLX runtime and model weights when needed. Speech generation connects to the local Fish Audio service at `127.0.0.1:5070`; the OpenRouter credential is entered in Settings and stored in macOS Keychain.

## Current capabilities

- Fish Audio S2.1 Pro speech through the local service, including emotion/direction controls and optional reference-audio voice cloning.
- Local Stable Audio 3 Small Music, Small SFX, and Medium music generation on Apple silicon.
- Audio-to-audio variation, selected-region inpainting, and cue continuation.
- Candidate rendering, seekable playback, and length-changing region replacement: the duration control sets the final cue length and the selected range is regenerated with nearby context.
- Multitrack arrangement with start offsets, clip trims, fades, pan or stereo balance, mute/solo, three-band EQ, compression, room echo, delay, and gain automation.
- Muted reference picture playback, audio/video sync preview, scene markers, timeline seeking, mixdown and category stems.
- Configurable PCM export at 48 or 96 kHz and 16-bit, 24-bit, or 32-bit float, with optional EBU R128 or streaming loudness normalization and a peak limiter.
- Optional noise cleanup and imported audio/video media.

Local generation and exports are source material for post-production. This workspace does not produce Dolby Atmos masters or multichannel stems. The app source is a single SwiftUI file at `Sources/CineScope/App.swift`; model weights and generated audio are installed or stored outside the repository.
