# CaptureStream

Native macOS low-latency capture card viewer & performance diagnostics tool.

## Features
- UVC/USB/Thunderbolt capture card discovery (AVFoundation)
- Zero-copy Metal rendering: CVPixelBuffer → CVMetalTextureCache → MTLTexture → shader
- YUV (NV12/YUV420 planar) → RGB in GPU shader, BT.709 limited/full range
- Scaling: Pixel Perfect (1:1), Integer (1x-4x), Fit/Fill/Stretch, Custom
- Filters: Nearest, Bilinear, Bicubic (Catmull-Rom), Lanczos-2, Sharpen
- Per-stage FPS: Capture / Decode / Process / Render / Present
- Frame drop attribution: capture vs transport vs decode vs render vs present
- Frame tracing (Frame ID + timestamps per stage), P50/P95/P99 frame times
- Performance recording → CSV / JSON export
- Audio via AVAudioEngine with delay compensation (-1000..+1000 ms)
- Test pattern source (1080p60 NV12) for CI / no-capture-card environments
- Auto reconnect on device hot-unplug

## Build (macOS 13+, Xcode 15+)
    swift build -c release
    # app bundle assembly in .github/workflows/build.yml

## Test
    swift test

## Keyboard shortcuts
- ⌘⇧F  Performance overlay
- ⌘⏎   Fullscreen
- ⌘,   Settings

## Download
- [Release v0.1.0](https://github.com/MazzyGi/CaptureStream/releases/tag/v0.1.0) — `CaptureStream.zip` (Apple Silicon, ad-hoc signed)
- CI artifact from latest `main`: Actions → CI → Build CaptureStream.app

## Architecture
```
AVCaptureSession (UVC) ──▶ BoundedFrameQueue (drop-oldest) ──▶ Render thread
TestPatternSource (CI) ──┘        │                              │
                                  ▼                              ▼
                        PerformanceMonitor ◀──── CVMetalTextureCache → MTLTexture
                        (per-stage FPS,          → shader: YUV→RGB / nearest /
                         frame ID traces,          bilinear / bicubic / lanczos
                         drop attribution)       → CAMetalLayer drawable
```
