# RDPKit

Pure Swift RDP library for Apple platforms, built around Apple media, security,
and networking primitives instead of FreeRDP.

- RDPGFX rendering with AVC420/H.264, AVC444/AVC444v2, RemoteFX Progressive,
  classic RemoteFX, ClearCodec, NSCodec, and RDP bitmap codecs
- Persistent mapped-surface composition, VideoToolbox decode, Metal AVC444
  reconstruction, and zero-copy CoreVideo presentation where available
- HEVC/H.265 Annex B parsing and VideoToolbox decode helpers
- SwiftNIO and SwiftNIO SSL transport, including TLS upgrade on an existing RDP
  socket
- Keyboard, pointer, display control, clipboard, remote file transfer, audio,
  certificate trust, and live render metrics
- Pure Swift protocol implementation with no FreeRDP, no C/C++/Rust RDP core,
  and no non-Apple package dependencies
- Swift 6 package for macOS, iOS, tvOS, Mac Catalyst, and visionOS clients

## Requirements

- macOS 13.0+, iOS 17.0+, tvOS 17.0+, Mac Catalyst 17.0+, or visionOS 1.0+
- Swift 6.0+
- macOS 14.0+ for the SwiftPM example app and diagnostic tools

## Installation

Add RDPKit as a dependency in your `Package.swift`.

Use `main` for current development builds:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/RDPKit.git", branch: "main"),
]
```

Or use the latest release tag for a pinned build:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/RDPKit.git", from: "0.3.1"),
]
```

Then add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["RDPKit"]
)
```

## Usage

```swift
import Foundation
import RDPKit

let credentials = try RDPCredentials.validated(
    username: "rdp-user",
    domain: nil,
    password: ProcessInfo.processInfo.environment["RDP_PASSWORD"] ?? ""
)

let configuration = RDPConnectionConfiguration(
    host: "rdp.example.com",
    credentials: credentials,
    graphicsFrameCaptureLimit: nil,
    desktopWidth: 1920,
    desktopHeight: 1080,
    clipboardEnabled: true,
    audioPlaybackEnabled: true
)

let client = RDPSessionClient()
let metricsStore = RDPRenderMetricsStore()

let report = client.run(
    configuration: configuration,
    onGraphicsFrame: { frame in
        let metadata = RDPFrameMetadata(frame)
        print("\(metadata.codecName) \(metadata.width)x\(metadata.height)")
    },
    onRemotePointer: { update in
        print("remote pointer: \(update)")
    },
    onCertificate: { certificate in
        print("certificate trusted: \(certificate.trusted)")
        print("certificate sha256: \(certificate.sha256 ?? "unavailable")")
    },
    onWireReceive: { sample in
        metricsStore.recordWireReceive(sample)
        if let mbps = metricsStore.metrics.rollingWireMegabitsPerSecond {
            print("rx \(mbps) Mbps")
        }
    }
)

print(report.status)
```

`RDPSessionClient` exposes callbacks for graphics frames, remote pointer
updates, input readiness, display control, clipboard messages, audio
samples, TLS certificate inspection, wire bandwidth samples, and cancellation.
It also accepts an `RDPWireTranscript` for recording the connection flow. The
macOS example app builds a full viewer on top of these APIs.

`run` and `connect` block the calling thread until the session ends, so call
them from a dedicated thread, never from a SwiftNIO event loop or a Swift
concurrency executor. Handlers run on that thread, except `onWireReceive`,
which runs on the SwiftNIO event loop and must not block. Cancelling from
`onCertificate` rejects the server before any credential is sent. A wire
transcript keeps server PDUs in full, so store it as you would the session
itself.

## Features

### Graphics

- RDP Graphics Pipeline capability negotiation for RDPGFX 8.0, 8.1, and 10.0
  through 10.7, with automatic, AVC thin-client, AVC420, and legacy profiles
- Persistent mapped and scaled surface composition, including partial updates,
  multiple surfaces, caches, solid fills, alpha bitmaps, and graphics resets
- AVC420/H.264 rendering through per-surface VideoToolbox decoders, presented
  as full-range BT.709 as MS-RDPEGFX specifies, and KRdp's limited-range
  x264 video corrected
- AVC444/H.264 and AVC444v2 layout parsing, persistent luma/chroma subframes,
  reverse filtering, and CPU or Metal chroma reconstruction
- RemoteFX Progressive and classic RemoteFX decoding
- ClearCodec, NSCodec, RDP 6.0 bitmap compression, and Interleaved RLE decoding
- Zero-copy CoreVideo presentation for directly presentable decoded video frames
- H.264 and HEVC/H.265 Annex B sample preparation and NAL unit metadata
- A shared VideoToolbox decoder with hardware-acceleration reporting
- In-order background decode that lets a client acknowledge each frame only
  after it is presented
- Frame metadata, frame acknowledgements, render metrics, and wire bandwidth
  samples

### Session

- TPKT and X.224 connection negotiation
- TLS upgrade through SwiftNIO SSL
- CredSSP with NTLM Network Level Authentication and Early User Authorization
- MCS connect, channel join, static virtual channels, and dynamic virtual
  channels
- Connect-time and continuous bandwidth auto-detection, and reactivation after
  Deactivate All
- Server redirection to a routing token or target host
- New, upgraded, and stored RDP client license handling
- System trust evaluation of the server's certificate chain, certificate
  SHA-256 reporting, early TLS certificate callbacks, and configurable
  certificate warning visibility
- A connection timeout for every milestone before the first frame, TCP
  keepalive during live sessions, and cancellation from any thread

### Input And Display

- Slow-path and fast-path keyboard scancodes and Unicode input
- Pointer motion, buttons, extended buttons, vertical wheel, and horizontal wheel
- Remote pointer shapes, system pointers, and pointer-cache updates
- Display control channel support for resize and monitor layout updates
- HiDPI-aware display scale models for Apple clients

### Clipboard And Files

- Unicode text clipboard
- File Group Descriptor W parsing and encoding
- File contents requests and responses
- Local-to-remote and remote-to-local clipboard file transfer plumbing

### Audio

- RDPSND over the `rdpsnd` static channel and the `AUDIO_PLAYBACK_DVC` dynamic
  channel
- PCM format negotiation
- Wave info, wave data, Wave2, training, quality mode, and wave confirm PDUs
- Optional audio playback support in the macOS example

### Testing And Diagnostics

- Mock server tests for graphics, clipboard, audio, security, Windows, and KRdp
  compatibility flows
- First-frame capture tooling with configurable geometry, settle windows, and
  optional wire-transcript recording
- Preflight tooling for connection, security, channel, graphics, clipboard, and
  audio inspection plus input, clipboard, display, and audio probes
- Frame benchmark tooling for live capture measurements and pixel-buffer or
  Core Graphics decode strategies
- Captured negotiation fixtures and offline transcript replay tests
- Stats for Nerds window in the macOS example app

### Compatibility

Live compatibility is validated against Microsoft Windows RDP and KDE KRdp.
Mock-server tests cover Windows and KRdp compatibility, while captured KRdp and
GNOME Remote Desktop transcripts replay connection and graphics flows without
a live host.

## Run The Example App

Run the native macOS viewer:

```sh
cd Examples
swift run RDPClient
```

Run the diagnostic tools:

```sh
cd Examples
swift run RDPPreflight --host <host> --username <name> --password-env RDP_PASSWORD
swift run RDPFirstFrameCapture --host <host> --username <name> --password-env RDP_PASSWORD --output frame.png
swift run RDPFrameBenchmark --host <host> --username <name> --password-env RDP_PASSWORD --frames 120
```

The included app lets you save connections, store credentials and issued RDP
client licenses in Keychain, review certificate warnings, control a remote
desktop, toggle clipboard and audio support, and open the Stats for Nerds window
while a session is running.

### Performance Measurement

Use `RDPFrameBenchmark` to measure a specific host, desktop size, graphics
profile, frame count, and optional display resize. Pass `--json` when collecting
results for comparison so the complete configuration and measurements can be
retained together.

You can also build without launching:

```sh
swift build --package-path Examples --product RDPClient
swift build --package-path Examples --product RDPPreflight
swift build --package-path Examples --product RDPFirstFrameCapture
swift build --package-path Examples --product RDPFrameBenchmark
```

The `RDPPreflight`, `RDPFirstFrameCapture`, and `RDPFrameBenchmark` products are
lower-level diagnostic tools, but the native `RDPClient` app is the recommended
starting point.

## Architecture

```text
Package.swift                         SwiftPM library manifest
Sources/RDPKit/                       Reusable RDP protocol, transport, media,
                                      input, clipboard, audio, and metrics code
Tests/RDPKitTests/                    Unit and mock-server integration tests
Examples/Package.swift                SwiftPM example app and tool manifest
Examples/RDPClient/                   Native macOS viewer shell
Examples/RDPPreflight/                Connection and protocol inspection tool
Examples/RDPFirstFrameCapture/        Live graphics capture and decode tool
Examples/RDPFrameBenchmark/           Live capture and decode benchmark tool
Examples/RDPCommandLineSupport/       Argument parsing shared by the tools
```

Keep reusable behavior in `Sources/RDPKit`. Keep AppKit, SwiftUI, Keychain,
menus, windows, and macOS preferences in the example app.

## Testing

Run the Swift package tests:

```sh
swift test
swift test --package-path Examples
```

Run the Swift style gate:

```sh
swiftlint lint --strict
```

The mock server tests exercise the library without a live desktop. Live
compatibility should still be validated against real RDP servers when changing
negotiation, graphics, input, clipboard, display, audio, or TLS behavior.

## License

MIT. See [LICENSE](LICENSE).
