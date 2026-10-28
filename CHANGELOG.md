# Changelog

## Unreleased

### Breaking changes

- Rename the types named after the old preflight probe: `RDPPreflightClient`
  is now `RDPSessionClient`, `RDPPreflightReport` is `RDPConnectionReport`,
  `RDPPreflightError` is `RDPConnectionError` and `RDPProbeWarning` is
  `RDPConnectionWarning`. `RDPLatestFrameDecodeQueue`, which decodes every
  frame in order, is now `RDPFrameDecodeQueue`.
- `RDPConnectionReport`: remove `tlsCipherSuite`, the always-nil
  `rdpClipboardMessageHexes`, `rdpClipboardSentMessageHexes` and
  `rdpAudioMessageHexes`, and the clipboard and input probe fields, which moved
  into the `RDPPreflight` tool. `stage` uses one stage list: `tls-upgrade` is
  split into `tls-handshake`, `credssp` and `early-user-authorization`.
- `RDPGraphicsFrameSnapshot`: remove the `h264AnnexBData`, `h264ByteCount` and
  `h264NalUnitTypes` aliases; use `encodedVideoData`, `videoByteCount` and
  `videoNalUnitTypes`.
- `RDPGFXMessageSummary`: remove the per-command detail fields nothing read,
  such as the cache, fill, surface-to-surface, monitor and ClearCodec subcodec
  fields.
- Replace `RDPH264FirstFrameDecoder`, `RDPH264FrameSequenceDecoder`,
  `RDPHEVCFrameSequenceDecoder` and their error types with the shared
  `RDPVideoToolboxFrameDecoder` and `RDPVideoDecodeError`. Remove
  `RDPH264NALUnit`, `RDPHEVCNALUnit` and `nalUnits(from:)`;
  `nalUnitTypes(from:)` and `sample(from:)` remain.
- `RDPFrameDecodeQueue` decodes in arrival order through `submitAndWait`:
  remove `submit`, `submitReportingCompletion`, the queue-depth initializer
  parameters, `onSkippedFrames`, `RDPFrameDecodeCompletion.dropped` and
  `RDPFrameDecodeQueueError.frameDropped`.
- `RDPRenderMetrics`: remove the crop timings, the `max*Milliseconds` timings,
  `skippedDecodeFrameCount` and `recordSkippedDecodeFrames`.
  `RDPFrameDecodeTiming.cropMilliseconds` is gone too.
- `RDPInputStateTracker`: `keyboard(scancode:isReleased:)` drops `isRepeat`
  and `trackRelease`. A press of a key already down is sent as a repeat, and
  every press is tracked, so a key whose first press the server saw was an
  auto-repeat is no longer left down there. `releasePressedScancodes()` and
  `releasePressedPointerButtons()` are gone; use `releasePressedInputs()`.
- Clipboard: `requestRemoteFileSize` and `requestRemoteFileRange` drop the
  `clipDataID` parameter, which needs clipboard locking RDPKit does not
  negotiate, and `RDPClipboardFileDescriptorW` drops the creation and
  last-access times, which MS-RDPECLIP reserves.
- `RDPConnectionError.graphicsFrameHandler` is new: a throwing `onGraphicsFrame`
  ends the session with its own error. Remove `RDPDecodeError` and
  `RDPBitmapFrameDecodeError` cases that were never thrown.
- Move `RDPFramePacingState`, `RDPFramePresentationBuffer`,
  `RDPH264DecodedFrameImage.cropToDestinationRect` and
  `decodeReportFirstFrame(_:)`, which only the examples used, into the
  examples.
- Use `RDPKit`/`RDPKIT` as the default client, workstation and source names.

### Protocol and compatibility

- Rebuild the connection engine around one connection object and one receive
  path that routes every server message by MCS channel. The whole connection,
  including X.224, now runs on SwiftNIO with a connect timeout and TCP
  keepalive, and every milestone before the first frame is bounded by the
  configured timeout however much other traffic arrives.
- Answer mid-session auto-detect requests, including continuous bandwidth
  measurement, and stop answering requests that need no response. An unknown
  or malformed request no longer ends the session.
- Reactivate after Deactivate All followed by Demand Active, at the desktop
  size the server's Demand Active sets.
- End a session the client finishes, by cancelling or at its frame target,
  with the MCS Disconnect Provider Ultimatum (rn-user-requested) before
  closing the connection, as MS-RDPBCGR 1.3.1.4.1 describes. Servers log a
  user logoff instead of a transport failure.
- Server redirection: follow redirections that name only a target host, send
  the password cookie opaquely in the Client Info PDU instead of using it for
  NLA, accept the spec's PDU form as well as gnome-remote-desktop's, and treat
  `LB_NOREDIRECT` as informational.
- Reassemble virtual channel chunks sent without `CHANNEL_FLAG_SHOW_PROTOCOL`,
  which the specification allows, and answer newer DVC capability versions.
- Reject dynamic channels the client does not implement with E_NOTIMPL,
  instead of accepting the Windows input, mouse-cursor and microphone channels.
- Follow the cliprdr and rdpdr initialization sequences, accept any rdpdr minor
  version, and fix clipboard chunking and remote file names.
- Send one Confirm Active capability list to every server, including the
  mandatory Sound capability set KRdp checks for.
- Report licensing failures with the server's error code, keep reading
  licensing PDUs only until licensing completes, and send non-ASCII license
  user and machine names as UTF-8.
- Present RDPGFX H.264 as full-range BT.709, as MS-RDPEGFX specifies, except
  KRdp's x264 video, which holds limited-range BT.601 without signalling it.
- Fix AVC444 reverse filtering, subframe scaling, chroma-only updates and
  inverted chroma regions, and recreate VideoToolbox sessions after
  invalidation.
- Acknowledge every RDPGFX EndFrame and every surface frame marker, including
  after an update that fails to decode, and ignore cosmetic RDPGFX and DVC
  fields instead of ending the session.
- Fix ClearCodec glyphs, NSCodec planes, padded slow-path bitmaps,
  uncompressed bitmaps with `NO_BITMAP_COMPRESSION_HDR`, KRdp 32-bpp pointers
  without an AND mask, and pointer hotspots outside the image.
- Fix NTLM deviations from MS-NLMP, and report a CredSSP error the server sends
  in answer to the credentials instead of timing out.
- Report a connection lost mid-session as a failure, DNS failures as
  `RDPConnectionError.addressResolution`, and connect and send errors with a
  readable reason.
- Cancelling from `onCertificate` rejects the server before any credential is
  sent. `shouldCancel` is polled while connecting, during the TLS handshake,
  certificate evaluation and sends, and cancelling during a redirection returns
  the report of the session that ran.
- Negotiate only PCM rates `AVAudioEngine` can play.
- `onDisplayControlReady` runs once the first graphics frame has arrived:
  KRdp ignores a monitor layout that arrives before its video stream starts.

### Security and robustness

- Evaluate the server's full certificate chain, bounded by the timeout.
  `RDPServerCertificateInfo.host` names the host the certificate was checked
  against, the redirection target after a redirection.
- Zero the server redirection password and the auto-reconnect cookie in
  `RDPWireTranscript` events and report hex. `RDPWireTranscript` takes an
  optional `maximumPayloadByteCount`, and credential descriptions redact the
  password.
- Bound what a server can make the client allocate or keep: RDPGFX surfaces,
  progressive tile state, ZGFX output, pending video updates, static channel
  messages, raw RSA work and every report list that grows during a live
  session. Server-sized data now throws where it used to trap.
- Keep sanitized remote clipboard file names valid and unique.

### Performance and examples

- Mutate RDPGFX surfaces and reassemble channel messages in place, speed up
  ZGFX, NSCodec, CAPROGRESSIVE and hex formatting, and build diagnostic report
  entries only while the report keeps them.
- `RDPScrollWheelAccumulator` turns scroll deltas into wheel events.
- The RDPClient example runs sessions on a dedicated thread, fixes modifier,
  focus-loss, toggle-key, Windows-key and keypad input, keeps a key held as a
  scancode repeating as that scancode once its modifier is released, and pins
  a redirected server's certificate under its own host. The command-line
  tools share argument parsing through `RDPCommandLineSupport`.

## 0.3.1

- Raise the minimum deployment targets from 16.0 to 17.0 for iOS, tvOS, and
  Mac Catalyst. The macOS 13.0 and visionOS 1.0 minimums are unchanged.

## 0.3.0

- Add server-redirection compatibility by following redirection PDUs, reconnecting with server-provided routing tokens, handling connect-time bandwidth detection, and using the required `drdynvc` ShowProtocol framing.
- Improve Windows and KDE KRdp activation compatibility across licensing, auto-detect, Confirm Active, finalization, auxiliary dynamic channels, remote termination, and reconnect flows.
- Add a persistent RDPGFX compositor for mapped and scaled surfaces, partial and multi-surface updates, surface caches, solid fills, alpha bitmaps, graphics resets, and output composition.
- Add full RemoteFX Progressive decoding, including Reduce-Extrapolate transforms, refinement and sub-band difference passes, shared tile state, change regions, and compatible region envelopes.
- Add decoded rendering for classic RemoteFX, ClearCodec, NSCodec, RDP 6.0 bitmap compression, and Interleaved RLE surface and bitmap updates.
- Add AVC444 and AVC444v2 chroma reconstruction with persistent luma and chroma state, reverse filtering, per-surface decoder isolation, and a Metal reconstruction path.
- Improve H.264 presentation with zero-copy CoreVideo frames, per-surface resynchronization, dependent-frame preservation, bounded decode backlog handling, and acknowledgements sent only after successful decode and presentation.
- Advertise every supported RDPGFX capability version from 8.0 through 10.7, validate the server-selected version, enforce negotiated cache and fragment limits, and preserve compatibility with server-selected capability flags.
- Add remote pointer shape and cache handling plus fast-path keyboard, Unicode, pointer, extended-button, and wheel input support.
- Add RDP client licensing for new, upgraded, and stored licenses, including platform-challenge handling and Keychain-backed license persistence in the macOS example.
- Expand clipboard, audio input and output, device redirection, display control, CredSSP, NTLM, MCS, fast-path, ZGFX, and graphics PDU validation and interoperability.
- Add `RDPWireTranscript` capture and offline replay, explicit capture geometry, timed Windows-key probes, richer graphics diagnostics, and latest-frame capture after a configurable settle window.
- Add captured negotiation fixtures, transcript replay coverage, and expanded mock-server regression tests for Windows and KRdp connection and graphics paths.

## 0.2.0

- Add a TLS certificate callback so live clients can show certificate trust state before the session ends.
- Add a timeout while live viewer sessions wait for the first graphics frame after RDPGFX setup, preventing stalled sessions from blocking forever.
- Add CredSSP with NTLM authentication for Windows hosts that require Network Level Authentication.
- Add selectable RDPGFX capability profiles for automatic, AVC thin-client, AVC420, and legacy negotiation paths.
- Add Windows graphics compatibility for bitmap codec capability advertisement, frame acknowledgements, thin-client fallbacks, ClearCodec and NSCodec bitmap streams, ZGFX compression, RemoteFX CAVIDEO updates, and uncompressed BGRA surface composition.
- Add parsing and diagnostics for more RDPGFX update paths, including CAPROGRESSIVE summaries, solid fill, surface cache, and cache-to-surface commands.
- Add bitmap frame decoding through CoreVideo and bounded in-order video decode buffering that can drop forward at resync frames instead of falling far behind the live session.
- Add device-redirection protocol handling for server announce, capability, and user-logon PDUs during preflight sessions.
- Add clipboard temporary-directory support plus sent-message and probe diagnostics for CLIPRDR validation.
- Improve RDPSND compatibility with dynamic audio channel handling and compatible PCM format selection.
- Move the example apps from XcodeGen to SwiftPM and add the `RDPFrameBenchmark` tool for measuring live frame capture and decode paths.
- Expand `RDPPreflight` and `RDPFirstFrameCapture` with graphics profile selection, Windows clipboard/input/audio probes, display resize support, richer graphics path reporting, and failure-update diagnostics.
- Improve the macOS example viewer with graphics profile controls, early certificate warning updates, Stats for Nerds graphics path reporting, and more reliable window activation.
- Expand mock-server and unit coverage for Windows CredSSP, graphics, codecs, clipboard diagnostics, device redirection, audio, display resize, and input paths.

## 0.1.0

- Initial release.
