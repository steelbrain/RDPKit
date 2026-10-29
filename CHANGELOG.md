# Changelog

## Unreleased

### Breaking changes

- `RDPConnectionError` is a struct with `failure` (`RDPConnectionFailure`)
  and `description` instead of an enum: match `error.failure` instead of its
  cases. `connect` now throws only `RDPConnectionError`.
- Once the graphics have opened, a session that an administrator, a time
  limit or another connection ends is an ended session (`status` "success",
  no `error`, `remoteTermination` set), not a failure.
- Set Error Info 0xB is named `ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER`.
  `error` names RDP_NEG_FAILURE codes, as in "RDP negotiation failed with
  HYBRID_REQUIRED_BY_SERVER (0x00000005)", and the newly named Set Error Info
  codes.

### Additions

- `RDPConnectionReport.failure` (`RDPConnectionFailure`) says why a run failed
  without matching text: connect errors with their errno and a category
  (`RDPSocketError`), RDP_NEG_FAILURE codes (`RDPNegotiationFailureCode`),
  TLS failures, including `tlsKeyUsageIncorrect` (retry with
  `legacyRSAKeyExchange`), CredSSP NTSTATUS codes (`RDPLogonStatus`), missing
  credentials, Early User Authorization, licensing, server termination, lost
  or closed connections, timeouts, cancellation, protocol violations and a
  throwing `onGraphicsFrame`. `error` keeps the details in words.
- `RDPConnectionStage` is public, and `report.connectionStage` returns it.
  `report.remoteTermination` (`RDPRemoteTermination`) names the Set Error
  Info code ([MS-RDPBCGR] 2.2.5.1.1) and gives its category: user, admin,
  time limit, replaced, access denied, licensing and others.
- `RDPConnectionConfiguration.clientName` sets the name servers show for the
  client in session lists and per-device licensing, instead of `RDPKIT`. It
  goes in the Client Core Data, the licensing request and the rdpdr Client
  Name Request; control characters are dropped and it is cut to 15
  characters.
- `RDPConnectionConfiguration.scaleFactors` (`RDPDisplayScaleFactors`) and
  `physicalSize` (`RDPDisplayPhysicalSize`, in millimetres) go in the Client
  Core Data, so a session starts at the client's scale, also on servers
  without Display Control. The defaults send 100% and no size, as before.
  Values set after the initializer are clamped the same way when the
  connection starts.
- Auto-reconnect: `report.rdpAutoReconnectCookie` (`RDPAutoReconnectCookie`)
  keeps the latest cookie the server sent, and
  `RDPConnectionConfiguration.autoReconnectCookie` sends it back in the Client
  Info PDU to reconnect to the same session. CredSSP still needs the
  credentials. The cookie is a secret: the report's encoding, descriptions
  and mirrors keep only its logon ID, and wire transcripts never record the
  client's PDUs.
- `RDPConnectionIdentity.legacyCredentialAccountNames` gives the name RDPKit
  0.1 to 0.3 used for `credentialAccountName`, which kept the host's case, so
  a client can find a password saved under it with a direct lookup and move
  it. `credentialAccountName` is documented as stable: the host is lowercased,
  and the username and domain keep their case.
- `RDPConnectionError.report` carries the report `run` returns for the same
  failure, so a client that calls `connect` keeps the stage reached and the
  negotiation details. `connect` throws only before the TLS handshake, so
  this report holds no captured frames.
- `RDPConnectionReport.redirectionDepth` counts the Server Redirections that
  led to `target`, and `RDPConnectionError.redirectionDepth` and `target`
  read it from the attached report, so a redirection target that cannot be
  reached no longer looks like a failure of the configured server, which
  already took the sign-in.
- `RDPClipboardSession.fetchesRemoteCopies` lets a client join cliprdr
  without fetching the server's copies: their Format Lists are acknowledged
  and nothing is requested. Set it in `onClipboardReady` to cover the
  server's first copy.
- `RDPRemoteDisplayViewport.remotePoint(from:contentRect:)` maps a point with
  the desktop drawn in a given rect, such as `contentRect` aligned to the
  screen's pixels.

### Compatibility and fixes

- Connections: a live session's wait for its first frame is bounded by the
  timeout at every step, however much other traffic or how many empty frames
  the server sends. 0.4.0 bounded it only in capture runs. After its first
  frame a live session still waits indefinitely, with TCP keepalive.
- `RDPCredentials` splits a `DOMAIN\user` user name when no domain is given,
  as mstsc and FreeRDP do, so NTLM and the Client Info PDU carry the domain.
  A UPN stays as it is. `qualifiedUsername`, and so `credentialAccountName`,
  is unchanged; the report's `username` and `domain` show the two parts.
- Clipboard: local files reach the server under paths Windows accepts.
  `publishLocalFiles` treats `\` and `/` as folder separators, so a
  directory `Folder` and a file `Folder\notes.txt` paste as a folder holding
  the file; empty, `.` and `..` components are dropped. In each component it
  replaces `: * ? " < > |` and control characters with `_`, puts `_` before
  device names such as `CON`, `NUL.txt` and `CONIN$`, drops trailing dots and
  spaces, and shortens a component past 255 UTF-16 code units before its
  extension. A path past cFileName's 259 has its last component shortened,
  or goes to the top level when its folders leave no room. Paths that differ
  only in case are numbered in their last component.

### Examples

- RDPClient:
  - Explains why a session ended or failed in plain words, including the
    server's reason after the desktop was shown, and offers the credentials
    again after a refused sign-in. RDPKit's own text stays in Stats for
    Nerds. A session shown through bitmap updates without RDPGFX no longer
    ends as one that never opened RDPGFX.
  - Connects again once with RSA key exchange when the server's certificate
    refuses ECDHE (`KEY_USAGE_BIT_INCORRECT`), keeps it only for reconnects
    to that host and port, and says that such a connection has no forward
    secrecy.
  - When a Server Redirection's target cannot be reached, says so, instead of
    blaming the server typed in, which already took the sign-in.
  - On a Retina Mac, Reconnect and Trust and Connect ask for the view's point
    size at 100% instead of its pixel size, so a server without Display
    Control no longer shows a half-size desktop. Display Control still raises
    a capable server to the pixel size.
  - Servers list RDPClient under the Mac's name, not `RDPKIT`.
  - Types the characters a Mac layout puts on Option, such as "@" (Option-L
    on German), €, [ ] { } | \ and ~. Right Option is held back, and such a
    character goes as Unicode without Alt; other keys still get Alt, and
    right Option released alone still taps Alt. Left Option goes as Alt at
    once, for shortcuts.
  - Scrolling with Command held sends the Windows key with the wheel, so
    releasing Command no longer opens the server's Start menu. Keypad "="
    goes as Unicode where the remote layout has no "=" on the main "=" key,
    as on German.
  - Clipboard sharing can be turned on mid-session; with it off, nothing
    crosses either way.
  - Remote file downloads:
    - A download no longer replaces text or files copied after it began.
      A remote file copy cancels a local file read still in progress, and
      wins over a local copy made in the second before it.
    - Each request has two minutes to be answered and asks for at most
      512 KiB, so slow links and files the server first fetches from the
      cloud no longer time out.
    - Downloaded files are quarantined, so Gatekeeper checks them before
      they open. They stay on disk while the pasteboard lists them, even if
      a newer download fails, and are removed once a newer copy replaces
      them, when the session closes, or at the next launch.
    - Sync Now and another "Share for 30s" send the clipboard only when it
      changed, so they no longer cancel a download in progress.
  - A `\` in a copied file's name is sent as `_`, so Windows does not paste
    the file inside a folder.
  - Only a refused certificate offers trust; other warnings are listed in
    Stats for Nerds. "Hide certificate warnings" is renamed "Accept untrusted
    certificates" and explains its risk.
  - Resizing the window and back within 350 ms no longer leaves the remote at
    the in-between size. The desktop is drawn on whole pixels, so a view of
    odd width no longer blurs it at 1x, and pointer input maps to the same
    rect.
  - The frame clock's display link runs only while a frame waits for the next
    refresh, and the session view no longer re-renders on every frame or
    failed decode. The report's first frame is decoded only when the session
    presented none. Clearing the display removes its last image, a display
    layer that fails between frames shows the last frame again, and Stats for
    Nerds' "Presented Frames" counts presented frames.
  - Saved passwords are looked up off the main thread once typing pauses, and
    ones saved before 0.4.0 are found by their old name instead of by listing
    every Keychain item. RDPClient no longer sets a Keychain accessibility
    that the login keychain ignores. Connecting before a lookup has answered
    reads Keychain then, so the saved password is still filled in, or removed
    with Remember unticked; a password typed or a Remember choice made while
    the lookup was on its way stands. A session window connects by itself
    only with the fields it opened with; editing a field first cancels that.
  - Each saved connection is read on its own. One it cannot read, such as one
    a newer build wrote, no longer empties the list, and saving keeps it and
    any fields a newer build added.

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
