# RDPKit

Pure Swift RDP library for Apple platforms, built around Apple media, security,
and networking primitives instead of FreeRDP.

- RDPGFX video path with AVC420/H.264, AVC444/H.264, AVC444v2, and HEVC/H.265
- VideoToolbox-backed decode helpers, CoreVideo frame output, and
  AVFoundation-ready presentation plumbing
- SwiftNIO and SwiftNIO SSL transport, including TLS upgrade on an existing RDP
  socket
- Keyboard, pointer, display control, clipboard, remote file transfer, audio,
  certificate trust, and live render metrics
- Pure Swift protocol implementation with no FreeRDP, no C/C++/Rust RDP core,
  and no non-Apple package dependencies
- Swift 6 package for macOS, iOS, tvOS, Mac Catalyst, and visionOS clients

## Requirements

- macOS 13.0+, iOS 16.0+, tvOS 16.0+, Mac Catalyst 16.0+, or visionOS 1.0+
- Swift 6.0+
- XcodeGen for the included macOS example app

## Installation

Add RDPKit as a dependency in your `Package.swift`.

Use `master` for current development builds:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/RDPKit.git", branch: "master"),
]
```

Or use the latest release tag for a pinned build:

```swift
dependencies: [
    .package(url: "https://github.com/steelbrain/RDPKit.git", from: "0.1.0"),
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
import RDPKit

let credentials = try RDPCredentials.validated(
    username: "aneesi",
    domain: nil,
    password: ProcessInfo.processInfo.environment["KRDP_PASSWORD"] ?? ""
)

let configuration = RDPConnectionConfiguration(
    host: "192.168.1.126",
    credentials: credentials,
    graphicsFrameCaptureLimit: nil,
    desktopWidth: 1920,
    desktopHeight: 1080,
    clipboardEnabled: true,
    audioPlaybackEnabled: true
)

let client = RDPPreflightClient()
let metricsStore = RDPRenderMetricsStore()

let report = client.run(
    configuration: configuration,
    onGraphicsFrame: { frame in
        let metadata = RDPFrameMetadata(frame)
        print("\(metadata.codecName) \(metadata.width)x\(metadata.height)")
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

`RDPPreflightClient` exposes callbacks for graphics frames, input readiness,
display control, clipboard messages, audio samples, wire bandwidth samples, and
cancellation. The macOS example app builds a full viewer on top of those hooks.

## Features

### Graphics

- RDP Graphics Pipeline (RDPGFX) capability negotiation and frame parsing
- AVC420/H.264 and AVC444/H.264 bitmap streams
- AVC444v2 layout handling
- HEVC/H.265 Annex B sample preparation
- H.264/H.265 NAL unit metadata extraction
- VideoToolbox decode helpers with hardware-acceleration reporting
- Latest-frame decode queue for dropping stale frames when decode falls behind
- Frame metadata, frame acknowledgements, render metrics, and wire bandwidth
  samples

### Session

- TPKT and X.224 connection negotiation
- TLS upgrade through SwiftNIO SSL
- CredSSP negotiation reporting and credential-aware Client Info PDUs
- MCS connect, channel join, static virtual channels, and dynamic virtual
  channels
- Certificate SHA-256 reporting and configurable certificate warning visibility

### Input And Display

- Keyboard scancodes and Unicode input
- Pointer motion, buttons, extended buttons, vertical wheel, and horizontal wheel
- Display control channel support for resize and monitor layout updates
- HiDPI-aware display scale models for Apple clients

### Clipboard And Files

- Unicode text clipboard
- File Group Descriptor W parsing and encoding
- File contents requests and responses
- Local-to-remote and remote-to-local clipboard file transfer plumbing

### Audio

- RDPSND static channel support
- PCM format negotiation
- Wave info, wave data, Wave2, training, quality mode, and wave confirm PDUs
- Optional audio playback support in the macOS example

### Testing And Diagnostics

- Mock KRdp server tests for graphics and clipboard flows
- First-frame capture tooling for live server validation
- Preflight tooling for connection, security, channel, graphics, clipboard, and
  audio inspection
- Stats for Nerds window in the macOS example app

## Run The Example App

Generate the Xcode project:

```sh
xcodegen generate --spec Examples/RDPClient/project.yml
```

Run from Xcode:

```sh
open Examples/RDPClient/RDPKitExamples.xcodeproj
```

Select the `RDPClient` scheme, choose `My Mac`, and press Run. The included app
lets you save connections, store credentials in Keychain, review certificate
warnings, control a remote desktop, toggle clipboard and audio support, and open
the Stats for Nerds window while a session is running.

### Example App Performance

In one 4K RDP session on an M3 Pro, the `RDPClient` example app using RDPKit was
observed at about 70 MB of memory and 20% of one CPU core. In the same scenario,
Microsoft's Windows RDP client was observed at about 900 MB of memory and 30% of
one CPU core.

You can also build and launch it from the command line:

```sh
xcodebuild -project Examples/RDPClient/RDPKitExamples.xcodeproj -scheme RDPClient -destination 'platform=macOS' -derivedDataPath DerivedData build
open "DerivedData/Build/Products/Debug/RDP Client.app"
```

The `RDPPreflight` and `RDPFirstFrameCapture` targets are included as lower-level
diagnostic tools, but the native `RDPClient` app is the recommended starting
point.

## Architecture

```text
Package.swift                         SwiftPM library manifest
Sources/RDPKit/                       Reusable RDP protocol, transport, media,
                                      input, clipboard, audio, and metrics code
Tests/RDPKitTests/                    Unit and mock-server integration tests
Examples/RDPClient/                   Native macOS viewer shell
Examples/RDPPreflight/                Connection and protocol inspection tool
Examples/RDPFirstFrameCapture/        Live graphics capture and decode tool
```

Keep reusable behavior in `Sources/RDPKit`. Keep AppKit, SwiftUI, Keychain,
menus, windows, and macOS preferences in the example app.

## Testing

Run the Swift package tests:

```sh
swift test
```

Run the Swift style gate:

```sh
swiftlint lint --strict
```

The mock server tests exercise the library without a live desktop. Live
compatibility should still be validated against KRdp or another real RDP server
when changing negotiation, graphics, input, clipboard, display, audio, or TLS
behavior.

## Status

RDPKit is active, KRdp-focused, and not yet a full replacement for mature
desktop clients. The goal is a reusable Apple-platform RDP library that can power
macOS, iOS, tvOS, Mac Catalyst, visionOS, and third-party clients without
embedding a native RDP stack.

## License

MIT. See [LICENSE](LICENSE).
