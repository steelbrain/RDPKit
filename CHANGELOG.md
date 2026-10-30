# Changelog

## Unreleased

### Breaking changes

- `RDPConnectionFailure` has a new case, `rdSTLS(resultCode:)`: the server
  rejected the credentials a Server Redirection gave, with an
  `RDPRDSTLSResultCode` such as `.logonFailure`. `RDPConnectionStage` has a
  new stage, `rdSTLS`.

### Security

- A shared drive's handles stay inside its folder. A handle's path is checked
  again before each use, so a server can no longer reach outside the folder
  by renaming a directory under another case than an open handle spells it
  and moving a directory holding a link to outside into its place. A rename
  over an open file is refused, as NTFS refuses it.
- A server can no longer exhaust the app's file descriptors through a shared
  drive: all drives together hold at most 64. FIFOs, sockets and devices in a
  shared folder are neither opened nor listed, so opening one can't block the
  drive, and search patterns longer than a file name are refused.

### Compatibility and fixes

- A shared drive deletes what the server's handles had pending when the
  session ends, as closing them would, and refuses an undefined
  CreateDisposition instead of truncating the file.
- A Windows 11 graphics confirmation with both AVC_DISABLED and
  AVC_THINCLIENT set (0x62), which [MS-RDPEGFX] 2.2.3.6 forbids, no longer
  ends the session; AVC_DISABLED wins, as for FreeRDP.
- GNOME Remote Login gets past the system sign-in. After a Server
  Redirection whose password is flagged PK-encrypted, the reconnect offers
  RDSTLS beside TLS and CredSSP and, when the server selects it, sends the
  redirection's user name and password as given, as FreeRDP does. It used
  to run CredSSP with the redirection's user name and the configured
  password, which gnome-remote-desktop's handover daemon rejects
  (`STATUS_LOGON_FAILURE`); a target that does not take RDSTLS still gets
  that. gnome-remote-desktop 50 flags its
  one-time password this way for every client but iOS and Android ones.
  Checked live on Ubuntu 26.04.1 from the system sign-in through the GDM
  greeter to the user's desktop.

## 0.5.0

### Breaking changes

- `RDPConnectionError` is a struct with `failure` (`RDPConnectionFailure`)
  and `description` instead of an enum; match `error.failure`. `connect`
  throws only `RDPConnectionError`.
- `RDPCredentialValidationError` has a new case, `fieldTooLong(_:)`.
- Once the graphics have opened, a session that an administrator, a time
  limit or another connection ends is an ended session (`status` "success",
  `remoteTermination` set), not a failure.
- `error` names RDP_NEG_FAILURE codes and more Set Error Info codes, as
  [MS-RDPBCGR] 2.2.5.1.1 names them, such as `ERRINFO_CONNECTFAILED` instead
  of `ERRINFO_0x000010d3`. 0xB is now
  `ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER`.

### Additions

- Errors and reports:
  - `RDPConnectionReport.failure` (`RDPConnectionFailure`) says why a run
    failed without matching text: socket errors, RDP_NEG_FAILURE codes, TLS
    failures (`tlsKeyUsageIncorrect`: retry with `legacyRSAKeyExchange`),
    CredSSP NTSTATUS codes, licensing, server termination, timeouts,
    cancellation, a configuration RDPKit cannot send and more.
  - `report.connectionStage` returns the now public `RDPConnectionStage`, and
    `report.remoteTermination` (`RDPRemoteTermination`) gives the Set Error
    Info code and its category.
  - `RDPConnectionError.report` carries the failure's report, so a `connect`
    caller keeps the stage reached and the negotiation details.
  - `RDPLiveConnectionReport`, passed as `liveReport`, gives a `snapshot` of
    the report from any thread while `run` or `connect` runs.
  - `redirectionDepth` counts the Server Redirections that led to `target`,
    also on `RDPConnectionError`, and `rdpGraphicsFrameAcknowledgeCount`
    counts every frame acknowledgement sent.
- `RDPConnectionConfiguration`:
  - `clientName` is the name servers show for the client instead of
    `RDPKIT`: in session lists, licensing and as the NTLM workstation.
  - `scaleFactors` and `physicalSize` go in the Client Core Data, so a
    session starts at the client's scale, even without Display Control.
  - `autoReconnectCookie` sends back `report.rdpAutoReconnectCookie` to
    reconnect to the same session. The cookie is kept out of report
    encodings and wire transcripts.
  - `monitorLayout` (`RDPMonitorLayout`) starts a session with up to 16
    monitors, and `RDPDisplayControlSession.send(_:)` sends one later. A
    layout is checked against the [MS-RDPEDISP] rules
    (`RDPMonitorLayoutError`). At connect, a layout whose monitors form
    separate groups is dropped: Windows 11 would start a single monitor
    instead. The server's Monitor Layout PDU is kept in
    `report.rdpMonitorLayout`.
    `RDPDisplayControlMonitorLayout.isPrimary` sets the primary flag.
- `RDPCredentials.validated` throws `fieldTooLong(_:)`, naming the
  `RDPCredentialField` over `maximumFieldLength` (255 UTF-16 code units), so
  an app can report it before connecting.
- `RDPConnectionIdentity.legacyCredentialAccountNames` gives the names RDPKit
  0.1 to 0.3 saved passwords under, so a client can move them.
- Clipboard:
  - `fetchesRemoteCopies` off joins cliprdr without fetching the server's
    copies; turned back on, it fetches the last one announced.
    `isAwaitingRemoteCopy` tells whether a fetch is under way. Joining still
    empties a Windows 11 server's clipboard; `clipboardEnabled` off does not
    join.
  - `onClipboardRemoteCopyUnavailable` is called when a server copy replaces
    the delivered one but brings nothing: `isEmpty` for an empty Format
    List, as Windows 11 sends when its clipboard is emptied, and not for
    formats the session does not fetch or that all failed.
  - In a clipboard handler, `deliveredRemoteCopyNumber` and
    `hasPublished(since:)` tell whether a later publish replaced the copy.
- `RDPRemotePointerBitmap(_:)` turns an `RDPRemotePointerImage` into
  premultiplied RGBA and a `cgImage` for `NSCursor` or UIKit, matching
  Windows 11's own drawing of its cursors. It is nil for 4 and 8 bpp and
  malformed images.
- `RDPRemoteDisplayViewport.remotePoint(from:contentRect:)` maps a point
  with the desktop drawn in a given rect.
- `RDPRenderMetrics.rollingFramesPerSecond(at:)`,
  `rollingWireMegabitsPerSecond(at:)` and `averageWireMegabitsPerSecond(at:)`
  read the rates at a given time, so they fall to 0 once traffic stops. The
  properties of those names are deprecated.
- `onGraphicsFrame` can throw `RDPGraphicsFrameNotPresented` for a frame it
  could not show: the session goes on, but a live session's first-frame
  wait, bounded by the timeout, lasts until the handler shows a frame.
- `RDPInputSession.supportsUnicodeInput` tells whether the server takes
  Unicode keyboard events; `send` drops `.unicode` events when it does not.

### Compatibility and fixes

- Cancelling stops graphics decoding mid-message, so `run` and `connect`
  return promptly instead of after a long decode.
- A live session's wait for its first frame is bounded by the timeout,
  whatever the server sends meanwhile; 0.4.0 bounded it only in capture
  runs.
- `RDPCredentials` splits a `DOMAIN\user` user name when no domain is given,
  as mstsc and FreeRDP do, and `hasSameConnectionIdentity(as:)` matches it
  to `user` in domain DOMAIN.
- A `storedClientLicense` too large to send no longer fails every connect:
  RDPKit asks for a new license and warns `stored-license-too-large`.
- A Demand Active may set a desktop of up to 32,766 pixels each way, not
  only 8192.
- Clipboard:
  - Local files reach Windows under paths it accepts: `\` and `/` separate
    folders, and invalid characters, device names, trailing dots and
    spaces, overlong names and names differing only in case are fixed.
  - Publishing drops the remote copy being fetched, so a late answer is no
    longer delivered.
  - Remote file names keep Unicode format characters such as ZWNJ, so
    "گزارش‌ها.pdf" no longer becomes "گزارش_ها.pdf".

### Examples

- RDPClient:
  - Says in plain words why a session ended or failed, and offers the
    credentials again after a refused sign-in or an overlong field. A
    session none of whose frames decode fails at the timeout instead of
    staying on Connecting.
  - Retries once with RSA key exchange when the server's certificate
    refuses ECDHE, and says such a connection has no forward secrecy. Only
    a refused certificate offers trust, and "Hide certificate warnings" is
    now "Accept untrusted certificates".
  - Servers list it under the Mac's name. A server without Display Control
    no longer shows a half-size desktop on a Retina Mac, the desktop is
    drawn on whole pixels, and resizing quickly no longer leaves the remote
    at an in-between size.
  - Keyboard: types the characters a Mac layout puts on right Option, such
    as € and "@", while left Option stays Alt for shortcuts; announces
    Windows' Japanese layout for a Japanese input source, with Eisu and
    Kana switching its IME; and sends scancodes to a server that takes no
    Unicode. It also fixes dead keys, Command-scroll opening Start, and keys
    held before a session attached.
  - Clipboard: sharing can be turned on mid-session, so RDPClient always
    joins the clipboard channel, which empties a Windows server's clipboard
    at connect. A server emptying its clipboard clears the copy it gave the
    Mac, and a late server copy no longer replaces a newer Mac copy. Remote
    file downloads no longer time out on slow links, are quarantined, and
    stay on disk while the pasteboard lists them.
  - Stats for Nerds shows the report while the session runs, and its rates
    and the fps overlay fall to 0 once the screen goes still. The footer
    shows the graphics path.
  - Saved passwords: Keychain is read off the main thread and once per
    connect, and a late lookup no longer overrides a typed password. Delete
    Profile keeps a password another saved connection shares, and one
    unreadable saved connection no longer empties the list.
- RDPPreflight prints the redirection depth and the frame acknowledgement
  count.
- The command-line tools check credential lengths before connecting.

## 0.4.0

### Breaking changes

- Renamed: `RDPPreflightClient` is now `RDPSessionClient`,
  `RDPPreflightReport` is `RDPConnectionReport`, `RDPPreflightError` is
  `RDPConnectionError`, `RDPProbeWarning` is `RDPConnectionWarning` and
  `RDPLatestFrameDecodeQueue` is `RDPFrameDecodeQueue`.
- `RDPVideoToolboxFrameDecoder` and `RDPVideoDecodeError` replace the H.264
  and HEVC frame decoders and their errors. `RDPH264NALUnit`,
  `RDPHEVCNALUnit` and `nalUnits(from:)` are removed.
- `RDPFrameDecodeQueue` decodes every frame in order through `submitAndWait`.
  `submit`, `submitReportingCompletion`, the queue-depth parameters,
  `onSkippedFrames` and the dropped-frame completion and error are removed.
  Composed presentations carry their pixels in `imageBuffer`, not
  `decodedBitmapData`.
- `RDPGraphicsFrameSnapshot`:
  - New content kinds `.surfaceCopy` and `.alpha`, plus `deletedSurfaceIDs`
    and `evictedCacheSlots`. `RDPFrameDecodeQueue` applies them; a client
    that decodes snapshots itself must too, or it shows stale pixels.
  - Bitmap snapshots of a surface mapped to scaled output carry the unscaled
    surface, as video snapshots do; `mappedOutputRect` says where it goes.
  - The `h264*` aliases are removed; use `encodedVideoData`,
    `videoByteCount` and `videoNalUnitTypes`.
- `RDPConnectionReport` drops `tlsCipherSuite`, the message hex lists and the
  clipboard and input probe fields, which moved into the `RDPPreflight` tool.
  `stage` splits `tls-upgrade` into `tls-handshake`, `credssp` and
  `early-user-authorization`. `RDPGFXMessageSummary` drops its per-command
  detail fields.
- `RDPRenderMetrics` drops the crop timings, the skipped-frame count and the
  per-stage maximums except `maxDecodeMilliseconds`.
- `RDPInputStateTracker.keyboard(scancode:isReleased:)` drops `isRepeat` and
  `trackRelease`; use `releasePressedInputs()` to release everything held.
- Clipboard: `requestRemoteFileSize` and `requestRemoteFileRange` drop
  `clipDataID`, and `RDPClipboardFileDescriptorW` drops its creation and
  last-access times.
- A throwing `onGraphicsFrame` ends the session with
  `RDPConnectionError.graphicsFrameHandler`. Error cases that were never
  thrown are removed.
- `RDPConnectionIdentity.credentialAccountName` lowercases the host, so
  passwords saved under the old name need moving; RDPClient does this.
- `RDPFramePacingState`, `RDPFramePresentationBuffer`,
  `cropToDestinationRect` and `decodeReportFirstFrame(_:)` moved into the
  examples.
- The default client, workstation and source names are `RDPKit`/`RDPKIT`.

### Additions

- `RDPGraphicsFrameSnapshot.monitors` and `RDPFrameMetadata.monitors` give the
  server's monitor layout from RDPGFX ResetGraphics as `RDPRemoteMonitor`
  rectangles in the graphics output, so a client can show a single remote
  monitor. KRdp's exclusive monitor bounds are read correctly.
- `RDPConnectionConfiguration.keyboardLayout` sets the Windows keyboard layout
  (`RDPKeyboardLayout`, a KLID such as 0x00000407 for German) the server uses
  to turn scancodes into characters, and `keyboardType` (`RDPKeyboardType`),
  `keyboardSubType` and `keyboardFunctionKeyCount` the keyboard it assumes.
  They go in the Client Core Data and the Input Capability Set, and default
  to what RDPKit sent before: US English, an IBM enhanced keyboard, subtype 0
  and 12 function keys.
- `RDPConnectionConfiguration.legacyRSAKeyExchange` offers only TLS 1.2 RSA
  key exchange, for a server whose RSA certificate allows keyEncipherment but
  not digitalSignature. BoringSSL refuses ECDHE with such a certificate, and
  the report's error now names `KEY_USAGE_BIT_INCORRECT` and this option. RSA
  key exchange has no forward secrecy, so it is off by default.
- Drive redirection: `RDPConnectionConfiguration.sharedDrives` shares local
  folders (`RDPSharedDrive`) that Windows shows as `\\tsclient\<name>`. The
  server can list, read, write, create, rename and delete inside a folder and
  nowhere else: `..`, and links whose target is outside the folder, are
  refused. File access runs off the connection thread. A missing folder or a
  drive the server refuses is reported as a warning. Sharing a drive also
  joins rdpsnd, without audio, since Windows starts rdpdr only then.
- Rich clipboard: `RDPClipboardSession.publishLocalContent` offers text,
  HTML, RTF and a bitmap (`RDPClipboardContent`) in one copy, and
  `onClipboardContent` receives every format a remote copy has. HTML travels
  in the Windows CF_HTML envelope and bitmaps as CF_DIB;
  `RDPClipboardBitmap` converts a DIB to and from `CGImage`. Without
  `onClipboardContent` only the text of a remote copy is requested, as
  before.

### Compatibility and fixes

- Connections: every step before the first frame is bounded by the timeout,
  with TCP keepalive. Sessions survive Deactivate All reactivation and server
  redirection, and end with a proper disconnect, so servers log a logoff
  instead of a network failure.
- Errors: lost connections, DNS failures
  (`RDPConnectionError.addressResolution`), licensing failures and logon
  failures such as `STATUS_LOGON_FAILURE` now report a clear reason.
- Video:
  - Windows text drawn over video is no longer dropped.
  - gnome-remote-desktop's partial video updates and scrolls no longer turn
    black.
  - AVC444 from Windows and FreeRDP 3 decodes correctly, and H.264 colours
    are right on every tested server, including KRdp's.
  - `RDPVideoToolboxFrameDecoder.decode(_:)` returns only the visible frame;
    `RDPDecodedFramePresentation.imageBuffer` can be larger than the frame.
  - After video fails to decode, for example once iOS invalidates the
    decoder in the background, its surface keeps its last picture until a
    keyframe instead of decoding updates without their reference, failing
    them as the new `RDPVideoDecodeError.awaitingKeyframe`. Windows and
    gnome-remote-desktop send a keyframe when the client sends its monitor
    layout again.
- Other graphics: fixes for RemoteFX, RemoteFX Progressive, ClearCodec,
  NSCodec, planar and legacy bitmaps, and pointers. Deleted surfaces free
  their decoders. Every frame is acknowledged, even ones that fail to decode.
- Input and display: `RDPInputSession` and `RDPDisplayControlSession` stop
  sending once the server deactivates or replaces them, and `onInputReady`
  and `onDisplayControlReady` hand out new ones. `onDisplayControlReady` runs
  after the first frame, because KRdp ignores earlier layouts. New
  `RDPScrollWheelAccumulator` turns scroll deltas into wheel events.
- Clipboard: text goes out with CRLF line ends and arrives with LF. Remote
  file names are valid and unique, and malformed requests get an error reply.
- Audio: only PCM rates `AVAudioEngine` can play are negotiated, and
  `RDPAudioPlayer` resumes after an interruption.
- Unsupported dynamic channels are declined instead of accepted, and
  mid-session auto-detect requests are answered.

### Security

- Cancelling from `onCertificate` rejects the server before any credential is
  sent, and `shouldCancel` is honoured throughout connecting. The full
  certificate chain is evaluated, and `RDPServerCertificateInfo.host` names
  the host it was checked against.
- Server-controlled sizes and counts are bounded, so a hostile server can't
  exhaust memory or time, and malformed data throws instead of crashing.
- `RDPWireTranscript` zeroes redirection passwords and auto-reconnect
  cookies, and takes a `maximumPayloadByteCount`.

### Performance

- RemoteFX decodes about 20% faster, and planar, interleaved and ClearCodec
  bitmaps 3 to 30 times faster. Partial 4K video updates take about a quarter
  of the time.
- Clipboard data goes out in chunks of the size the server advertises in its
  Demand Active (up to 16,256 bytes) instead of always 1,600, so large copies
  take about a tenth of the channel PDUs.

### Examples

- RDPClient asks before trusting an unknown server certificate and refuses a
  changed one. It also fixes keyboard modifiers, Windows-key and keypad
  input, clipboard file downloads and display resize after a redirection.
  When video fails to decode, it keeps the session and asks the server for a
  fresh picture.
- RDPClient announces the Mac's keyboard layout, mapped to a Windows layout
  as FreeRDP maps it, instead of US English. It sends a character key as its
  scancode when that layout types the same character, so a remote IME sees
  the key, and Space as its scancode on every layout; other characters, and
  those a dead key composed, still go as Unicode.

## 0.3.1

- Raise the minimum deployment targets from 16.0 to 17.0 for iOS, tvOS, and
  Mac Catalyst. The macOS 13.0 and visionOS 1.0 minimums are unchanged.

## 0.3.0

- Follow server redirections, including routing tokens and connect-time
  bandwidth detection.
- Improve Windows and KRdp compatibility across licensing, activation,
  dynamic channels, remote termination and reconnects.
- Add a persistent RDPGFX compositor: mapped and scaled surfaces, partial and
  multi-surface updates, caches, fills, alpha and graphics resets.
- Add RemoteFX Progressive, classic RemoteFX, ClearCodec, NSCodec, RDP 6.0
  bitmap and Interleaved RLE decoding.
- Add AVC444 and AVC444v2 decoding, with a Metal reconstruction path.
- Improve H.264 presentation with zero-copy CoreVideo frames and
  acknowledgements sent only after a frame is shown.
- Negotiate RDPGFX versions 8.0 through 10.7.
- Add remote pointer shapes and fast-path keyboard, Unicode, pointer and
  wheel input.
- Add client licensing, with Keychain-backed licenses in the macOS example.
- Add `RDPWireTranscript` capture and offline replay.

## 0.2.0

- Add a TLS certificate callback.
- Add Network Level Authentication (CredSSP with NTLM).
- Add a timeout for the first graphics frame.
- Add selectable RDPGFX capability profiles: automatic, AVC thin-client,
  AVC420 and legacy.
- Add Windows graphics support: bitmap codecs, frame acknowledgements,
  ClearCodec, NSCodec, ZGFX compression and RemoteFX.
- Add bitmap frame decoding through CoreVideo and in-order video decoding.
- Improve audio compatibility.
- Move the examples to SwiftPM, and add the `RDPFrameBenchmark` tool.

## 0.1.0

- Initial release.
