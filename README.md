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
- Candidate rendering, seekable playback, clip gain/start offsets, optional noise reduction, imports, and 24-bit/48 kHz FFmpeg mixdown.

Local generation and exports are source material for post-production. They are not Dolby Atmos masters. The app source is a single SwiftUI file at `Sources/CineScope/App.swift`; the model runtime and generated audio are installed or stored outside the repository.
