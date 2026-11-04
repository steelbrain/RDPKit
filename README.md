# RDPKit

Pure Swift RDP library for Apple platforms, built around Apple media, security,
and networking primitives instead of FreeRDP.

- RDPGFX rendering with AVC420/H.264, AVC444/AVC444v2, RemoteFX Progressive,
  classic RemoteFX, ClearCodec, planar, and alpha codecs
- Surface command and bitmap update rendering with RemoteFX, NSCodec, planar,
  and Interleaved RLE
- Persistent mapped-surface composition, VideoToolbox decode, Metal AVC444
  reconstruction, and zero-copy CoreVideo presentation where available
- HEVC/H.265 Annex B parsing and VideoToolbox decode helpers
- SwiftNIO and SwiftNIO SSL transport, including TLS upgrade on an existing RDP
  socket
- Keyboard, pointer, display control, clipboard, remote file transfer, drive
  redirection, audio, certificate trust, and live render metrics
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
    .package(url: "https://github.com/steelbrain/RDPKit.git", from: "0.7.0"),
]
```

Then add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["RDPKit"]
)
```

A macOS client can add `RDPKitAppKit`, whose `RDPRemoteInputView` sends the
Mac's keyboard, mouse and scroll input to the server, with the keyboard mapping
behind it (`RDPMacKeyboardLayout.current()` picks the Windows keyboard to
announce):

```swift
.target(
    name: "YourMacApp",
    dependencies: ["RDPKit", .product(name: "RDPKitAppKit", package: "RDPKit")]
)
```

`RDPKitTesting` holds in-memory stand-ins for a server, for your own tests:

```swift
.testTarget(
    name: "YourTargetTests",
    dependencies: ["YourTarget", .product(name: "RDPKitTesting", package: "RDPKit")]
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
        if let mbps = metricsStore.metrics.rollingWireMegabitsPerSecond(at: sample.receivedAt) {
            print("rx \(mbps) Mbps")
        }
    }
)

print(report.status)
```

When a run fails, `report.failure` says why without matching text, for example
`.credSSP(status: .logonFailure)`, `.connect(error:)` with the errno and its
category, `.tlsKeyUsageIncorrect` (`legacyRSAKeyExchange: .fallback` retries
within the run), or
`.legacyCredSSPVersion(version:)`: the server answered Network Level
Authentication with a CredSSP version from before the CVE-2018-0886 fix, and
no credential was sent. Ask the user, and retry with `legacyCredSSP` only if
they agree; `RDPLegacyCredSSPConsent` keeps that agreement to the server and
the one connection it was given for, never a redirection's target.
`report.error` describes the failure in words.
`report.remoteTermination?.category` says how the server ended a session:
logoff, an administrator, an idle limit, another connection, and so on.
`connect` throws `RDPConnectionError` with the same `failure`, and its `report`
is the one `run` would have returned. After a Server Redirection,
`redirectionDepth` above 0, on the report and on the error, together with
`target`, says the failure belongs to the redirection target, not to the
configured server.

`RDPSessionClient` exposes callbacks for graphics frames, remote pointer
updates, input readiness, display control, clipboard messages, audio
samples, TLS certificate inspection, wire bandwidth samples, and cancellation.
It also accepts an `RDPWireTranscript` for recording the connection flow, and
an `RDPLiveConnectionReport` whose `snapshot` any thread can read for
diagnostics while the session runs. The macOS example app builds a full viewer
on top of these APIs.

`run` and `connect` block the calling thread until the session ends, so call
them from a dedicated thread, never from a SwiftNIO event loop or a Swift
concurrency executor. Handlers run on that thread, except `onWireReceive`,
which runs on the SwiftNIO event loop and must not block. Cancelling from
`onCertificate` rejects the server before any credential is sent. A wire
transcript keeps server PDUs in full, so store it as you would the session
itself.

An app whose interface lives on the main thread can leave that to
`RDPLiveSession`. It calls `run` on a thread of its own, decodes each frame
off it, and hands decoded frames, decode failures and wire samples to the main
queue in order. Work handed to `deliver(_:)` keeps its place among them, and
none of it runs once `cancel()` has returned. The main queue has to run on the
main thread, as it does under an app's run loop, `RunLoop.main.run()` or an
`async` `@main`; under `dispatchMain()` it runs on another thread, and the
first delivery stops the process saying so. `recipient(_:)` hands such work to
an object, such as a view controller, that the session holds weakly:

```swift
let session = RDPLiveSession()
session.start(
    events: RDPLiveSession.Events(
        onFrameDecoded: { presentation, _, _, _ in
            // The app's own, such as RDPFramePresenter.present(_:) on macOS.
            show(presentation)
        },
        onFrameDecodeFailed: { _, error in print("not shown: \(error)") },
        onEnd: { report in
            session.deliver { print("ended: \(report.status)") }
        }
    )
) { run in
    RDPSessionClient().run(
        configuration: configuration,
        onGraphicsFrame: run.onGraphicsFrame,
        onInputReady: { input in session.deliver { inputView.inputSession = input } },
        onWireReceive: run.onWireReceive,
        liveReport: run.liveReport,
        cancellation: run.cancellation
    )
}
// Leaving the session: nothing delivered runs after this.
session.cancel()
// Before quitting: the session thread tells the server and closes the connection.
_ = await session.waitUntilEnded(timeout: 2)
```

The configuration also sets the keyboard the server assumes and the folders it
can see, and `onClipboardContent` receives every format of a remote copy, with
its number, which `hasPublished(since:)` and `downloadRemoteFiles` take:

```swift
var configuration = RDPConnectionConfiguration(host: "rdp.example.com", credentials: credentials)
// Windows keyboard layout identifier (KLID): German.
configuration.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0407)
// Shown on the server as \\tsclient\Shared.
configuration.sharedDrives = [
    RDPSharedDrive(name: "Shared", url: URL(fileURLWithPath: "/Users/me/Shared")),
]
// Start at a Retina Mac's scale, under a name the server's session list shows.
configuration.scaleFactors = RDPDisplayScaleFactors(backingScaleFactor: 2)
configuration.clientName = "Studio-Mac"

let report = client.run(
    configuration: configuration,
    onClipboardReady: { clipboard in
        clipboard.publishLocalContent(RDPClipboardContent(text: "Hello", html: "<b>Hello</b>"))
    },
    onClipboardContent: { content, _ in
        print(content.text ?? "", content.html ?? "", content.bitmap.flatMap(RDPClipboardBitmap.image(fromDeviceIndependentBitmap:)) as Any)
    }
)
```

## Features

### Graphics

- RDP Graphics Pipeline capability negotiation for RDPGFX 8.0, 8.1, and 10.0
  through 10.7, with automatic, AVC thin-client, AVC420, and legacy profiles
- Persistent mapped and scaled surface composition, including partial updates,
  multiple surfaces, caches, solid fills, alpha bitmaps, and graphics resets
- The server's monitor layout on every RDPGFX frame (`RDPRemoteMonitor`), so a
  client can show a single remote monitor
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
- TLS upgrade through SwiftNIO SSL, with opt-in RSA key exchange
  (`legacyRSAKeyExchange`, from the start or as a fallback) for servers whose
  certificate lacks digitalSignature
- CredSSP with NTLM Network Level Authentication and Early User Authorization;
  CredSSP versions 2 to 4 only with `legacyCredSSP`
- MCS connect, channel join, static virtual channels, and dynamic virtual
  channels
- Connect-time and continuous bandwidth auto-detection, and reactivation after
  Deactivate All
- Server redirection to a routing token or target host, with RDSTLS
  authentication when the redirection's password is PK-encrypted, as GNOME
  Remote Login's handover sends it
- New, upgraded, and stored RDP client license handling
- System trust evaluation of the server's certificate chain, certificate
  SHA-256 reporting, early TLS certificate callbacks, configurable
  certificate warning visibility, and `RDPTrustedServerCertificates` to trust
  a server's certificate on first use, per host and port
- A connection timeout for every milestone before the first frame, TCP
  connect retries (`connectAttempts`, `connectRetryDelay`) for the first
  connection into the local network while Apple platforms ask for access, TCP
  keepalive during live sessions, and cancellation from any thread
- Typed failure reasons (`RDPConnectionFailure`) and named, categorized server
  termination codes (`RDPRemoteTermination`)
- A configurable client name, and the server's auto-reconnect cookie, which a
  later connection can send back to rejoin the same session

### Input And Display

- Slow-path and fast-path keyboard scancodes and Unicode input
- Configurable keyboard layout (KLID), type, subtype, and function key count,
  announced in the Client Core Data and the Input Capability Set. Windows
  applies the layout only to a session it creates; connecting to an existing
  session keeps its layout, while the type and subtype apply.
  `RDPKeyboard.character(for:shift:capsLock:)` says what Windows types for a
  scancode with each layout a Mac input source announces, so a client can send
  a character as its scancode only where the server types the same one.
- Pointer motion, buttons, extended buttons, vertical wheel, and horizontal wheel
- `RDPKitAppKit`'s `RDPRemoteInputView` for macOS: keys go as scancodes where
  the server's layout types what the Mac's does and as Unicode otherwise, with
  dead keys, Option's characters and Japanese input; Command goes as the
  Windows key without tapping it for Mac shortcuts; modifiers, held keys and
  toggle keys stay in step with the Mac across focus changes and menus.
  `RDPMacKeyboardLayout` maps Mac input sources to Windows layouts, and
  `RDPMacKeyboardMapping`, `RDPMacModifierKey`, `RDPMacDeferredModifierKeys` and
  `RDPMacDeadKeys` are the pieces the view is built from
- Remote pointer shapes, system pointers, and pointer-cache updates, with
  `RDPRemotePointerBitmap` to turn a shape into premultiplied RGBA or a
  `CGImage` and a hot spot for a native cursor
- Display control channel support for resize and multi-monitor layouts
  (`RDPMonitorLayout`), checked against the server's capabilities
- Keyframe recovery: once the frame handler reports video it could not decode,
  the session resends the layout as it is (`recoversVideoWithLayoutResend`),
  which Windows and gnome-remote-desktop answer with a keyframe;
  `requestKeyframe()` does the same for an app that asks itself
- Connect-time multi-monitor layouts in Client Monitor Data and Client Monitor
  Extended Data, up to 32,766 x 32,766 pixels, and the server's Monitor Layout
  PDU in the report, live through `RDPLiveConnectionReport`, also without a
  layout through `receivesServerMonitorLayout`
- The server's monitors in each frame, with `monitorLayoutIssues` for a layout
  RDPKit cut to the graphics output or that overlaps, lacks one primary
  monitor, or leaves part of the output uncovered
- Connect-time desktop and device scale factors and physical size, for servers
  without display control
- HiDPI-aware display scale models for Apple clients
- `RDPKitAppKit`'s `RDPRemoteDesktopVideoView`, which shows decoded frames on
  macOS on a whole screen pixel and recovers a failed display layer, and
  `RDPFramePresenter`, which paces them to the display's refresh without
  waking an idle main thread
- Showing one monitor of a multi-monitor desktop: `RDPRemoteDisplayViewport`
  maps input within a `sourceRect` such as an `RDPRemoteMonitor`'s, and
  `RDPFrameSampleBufferFactory.sourceRect` crops the picture to it

### Clipboard And Files

- Unicode text clipboard. Joining the clipboard channel announces the client's
  clipboard, empty until it publishes something, and Windows then empties the
  server's clipboard; leave `clipboardEnabled` off to keep it untouched.
  `withdrawLocalCopy()` takes the client's copy back off the server only while
  `serverHoldsLocalCopy`, leaving a copy the server's user made since alone.
  With `fetchesRemoteCopies` off, the client fetches none of the server's
  copies; turning it on again fetches one announced meanwhile, unless the
  client has published since.
- HTML (CF_HTML), RTF, and bitmap (CF_DIB) clipboard content in both
  directions through `RDPClipboardContent`, with `RDPClipboardBitmap` to
  convert a DIB to and from `CGImage`. Windows 11 passes text, RTF, and
  bitmaps but drops HTML in both directions.
- File Group Descriptor W parsing and encoding
- `onClipboardRemoteCopyUnavailable` reports a server copy nothing is fetched
  of: an emptied clipboard (an empty Format List, which Windows sends and
  gnome-remote-desktop does not) or only formats the session does not fetch.
- `deliveredRemoteCopyNumber` and `hasPublished(since:)` let a client that
  applies remote copies on another thread drop one its own publish replaced on
  the way.
- Remote file downloads: `downloadPlan(limits:)` plans a remote copy's files
  within `RDPClipboardDownloadLimits` (32 MiB, 1000 files, two minutes per
  request by default), and `RDPClipboardSession.downloadRemoteFiles` fetches
  them into a folder, asking again for the rest of a range the server answers
  short, and ends once a newer copy replaces the one downloading or the
  connection closes.
- `RDPKitAppKit`'s `RDPPasteboardClipboard` for macOS bridges the pasteboard
  and a session's clipboard: it publishes the user's text and files as they
  copy them, puts the server's text and downloaded files (quarantined) on the
  pasteboard, shares for a while with `startTemporarySharing()`, and reports
  what happened as `Event`s for the app to word. An emptied server clipboard
  clears the copy it sent here, also while sharing is off.
- File contents requests and responses, for an app that makes its own: they
  have no timeout, so to give one up, ignore answers for its stream ID and use
  a new one, below `RDPClipboardSession.firstDownloadStreamID`, for the next
  request.
- Local file copies: `RDPClipboardLocalFile.read(contentsOf:)` reads files
  within a byte limit, and `beginLocalCopy()` with
  `publishLocalFiles(_:forCopy:)` replaces the server's copy at once while they
  are read, then offers them unless a newer copy came in between.
- Local-to-remote and remote-to-local clipboard file transfer plumbing. Local
  file names are relative paths (`\` or `/` separates folders) made valid on
  Windows before they are offered: forbidden characters, device names such as
  `CON`, trailing dots and spaces, components over 255 UTF-16 code units,
  paths over cFileName's 259, and duplicates that differ only in case. Remote
  file names are made valid for APFS: `:`, control characters, line
  separators and bidi overrides become `_`.
- Drive redirection: `sharedDrives` shows local folders on the server as
  `\\tsclient\<name>`. The server can read, write, create, rename, and delete
  inside a shared folder and nowhere else; links that point outside it are
  refused. The server hears when files are added, removed or renamed in a
  folder it watches. A file's Read-only attribute is its write permissions.

### Audio

- RDPSND over the `rdpsnd` static channel and the `AUDIO_PLAYBACK_DVC` dynamic
  channel
- PCM format negotiation
- Wave info, wave data, Wave2, training, quality mode, and wave confirm PDUs
- Wave confirms that report when each sample is heard: pass
  `audioPlaybackDelay: { player.playbackDelay }` with an `RDPAudioPlayer`, or
  your own output's delay, so the server can keep video in step with the sound
- Optional audio playback support in the macOS example

### Testing And Diagnostics

- `RDPKitTesting`'s `RDPClipboardTestServer`, the server's end of a clipboard
  channel in memory, to test an app's clipboard code against a real
  `RDPClipboardSession`. It copies text, files or other formats, empties or
  restarts its clipboard, and answers downloads in full, refused, cut short or
  late. It records the client's copies and pastes the client's text or files,
  and can hold its messages for a test to step through.
- `RDPKitTesting`'s `RDPDisplayControlTestServer`, a real
  `RDPDisplayControlSession` for an app's `onDisplayControlReady` code, whose
  server the test lays out as a ResetGraphics does and ends, and which records
  the layouts the session sent
- `RDPDiagnosticText`, which words what a diagnostics view shows: units, pixel
  formats, hex codes, and summaries of a report's channels, capabilities,
  messages, graphics failure, redirection and termination
- Mock server tests for graphics, clipboard, audio, security, Windows, and KRdp
  compatibility flows
- First-frame capture tooling with configurable geometry, settle windows, and
  optional wire-transcript recording
- Preflight tooling for connection, security, channel, graphics, display
  control, clipboard, and audio inspection plus input, clipboard, and audio
  probes
- Frame benchmark tooling for live capture measurements and pixel-buffer or
  Core Graphics decode strategies
- Captured negotiation fixtures and offline transcript replay tests
- Stats for Nerds window in the macOS example app

### Compatibility

Live compatibility is validated against Microsoft Windows RDP, KDE KRdp, and
GNOME Remote Desktop.
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
swift run RDPFrameBenchmark --host <host> --username <name> --password-env RDP_PASSWORD --frames 60
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
Sources/RDPKitAppKit/                 macOS input and video views, frame clock,
                                      keyboard mapping, and pasteboard bridge
Sources/RDPKitTesting/                In-memory server stand-ins for app tests
Tests/RDPKitTests/                    Unit and mock-server integration tests
Tests/RDPKitAppKitTests/              View, frame clock, keyboard and pasteboard
                                      tests
Tests/RDPKitTestMemoryLimit/          Memory limit for the test processes
Scripts/                              CI checks and keyboard table capture
Examples/Package.swift                SwiftPM example app and tool manifest
Examples/RDPClient/                   Native macOS viewer shell
Examples/RDPPreflight/                Connection and protocol inspection tool
Examples/RDPFirstFrameCapture/        Live graphics capture and decode tool
Examples/RDPFrameBenchmark/           Live capture and decode benchmark tool
Examples/RDPCommandLineSupport/       Argument parsing shared by the tools
```

Keep reusable behavior in `Sources/RDPKit`, and reusable AppKit views, Mac
keyboard handling and the pasteboard bridge in `Sources/RDPKitAppKit`. Keep
SwiftUI, Keychain, menus,
windows, and macOS preferences in the example app.

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

The whole suite stays under 2 GiB of memory, and a test process that passes
8 GiB stops, saying why: a test that grows without bound fails instead of
running the Mac out of memory. `RDPKIT_TEST_MEMORY_LIMIT_GIB` sets another
limit, and `0` turns it off.

The mock server tests exercise the library without a live desktop. Live
compatibility should still be validated against real RDP servers when changing
negotiation, graphics, input, clipboard, display, audio, or TLS behavior.

## License

MIT. See [LICENSE](LICENSE).
