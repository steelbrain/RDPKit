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
- `RDPGraphicsFrameSnapshot`: a bitmap snapshot of a surface mapped to scaled
  output carries the unscaled surface, as video snapshots do. Its
  `destinationRect` and `regionRects` are in unscaled output coordinates, and
  `mappedOutputRect` says where the surface is scaled to.
- `RDPGraphicsFrameSnapshot`: snapshots of the new content kind `.surfaceCopy`
  carry, in `surfaceCopy`, a copy among the decoder's surfaces, cache and
  ClearCodec glyphs of pixels only the decoder holds, such as decoded video. `evictedCacheSlots`
  names the cache entries such copies stored that the server has since evicted.
  Snapshots of the new content kind `.alpha` set the alpha of such pixels.
  `RDPFrameDecodeQueue` applies all of them; a client that decodes snapshots
  itself must too, or those areas keep stale pixels.
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
- `RDPRenderMetrics`: remove the crop timings, the per-stage
  `max*Milliseconds` timings (`maxDecodeMilliseconds` remains),
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
  version, and fix clipboard chunking and remote file names. Format Lists go
  out in the order the local clipboard changed, so a publish while the
  session answers Monitor Ready no longer leaves the server a stale one.
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
- `RDPGraphicsFrameSnapshot.deletedSurfaceIDs` names the surfaces the server
  deleted since the previous snapshot. `RDPVideoToolboxFrameDecoder` and
  `RDPFrameDecodeQueue` drop their decoders and pixels for them, so a session
  that recreates surfaces no longer keeps a decoder per old surface, and a
  surface recreated with the same ID starts empty. Updates queued for a surface
  deleted later in the frame are dropped, unless a copy out of the surface reads
  them: copies made before a deletion still copy the surface.
- Keep text and other non-video updates that Windows mixed mode draws on a
  video surface. Before, those updates were dropped whenever the same frame also
  carried video. Now the surface snapshot carries only the areas other codecs
  drew last. `RDPFrameDecodeQueue` merges those areas over the decoded video and
  keeps them through later partial video updates, on surfaces mapped to
  scaled output too.
- Copy decoded video instead of painting black. gnome-remote-desktop encodes
  video into an unmapped staging surface and copies each damaged rectangle to
  the mapped one; every partial update after its first frame used to paint
  black, and now goes to the mapped surface's decoder with those rectangles as
  its regions. SurfaceToSurface, SurfaceToCache and CacheToSurface copies of
  video decoded in earlier frames, such as a scroll, are made from the decoded
  pixels. An unmapped surface those copies wrote to gets its own video decoded
  too, from its next keyframe and without showing it, for the copies out of it.
- ClearCodec drawn over video no longer paints black where its layers leave the
  pixels underneath, and a ClearCodec glyph stored over video is drawn with that
  video. Alpha over video, which Windows sends for RemoteApp windows, keeps the
  video's colour.
- Acknowledge every RDPGFX EndFrame and every surface frame marker, including
  after an update that fails to decode, and ignore cosmetic RDPGFX and DVC
  fields instead of ending the session.
- Fix ClearCodec glyphs, NSCodec planes, padded slow-path bitmaps,
  uncompressed bitmaps with `NO_BITMAP_COMPRESSION_HDR`, KRdp 32-bpp pointers
  without an AND mask, and pointer hotspots outside the image.
- Fix NTLM deviations from MS-NLMP, and report a CredSSP error the server sends
  in answer to the credentials instead of timing out or failing the next write,
  naming logon failures such as `STATUS_LOGON_FAILURE` and
  `STATUS_ACCOUNT_LOCKED_OUT`.
- Report a connection lost mid-session as a failure, DNS failures as
  `RDPConnectionError.addressResolution`, and connect and send errors with a
  readable reason.
- Cancelling from `onCertificate` rejects the server before any credential is
  sent. `shouldCancel` is polled while connecting, during the TLS handshake,
  certificate evaluation and sends, and cancelling during a redirection returns
  the report of the session that ran.
- `RDPVideoToolboxFrameDecoder.decode(_:)` returns only the frame, not the
  rows and columns its coded picture rounds up to: gnome-remote-desktop codes
  1280x720 frames as 1280x768 pictures. `RDPDecodedFramePresentation` documents
  that its `imageBuffer` can be larger than the frame, and RDPFirstFrameCapture
  writes only the frame. RDPFrameBenchmark drops its `cgImageCrop` strategy.
- Negotiate only PCM rates `AVAudioEngine` can play.
- An `RDPInputSession` sends nothing once the server sends Deactivate All
  (MS-RDPBCGR 3.2.5.5.1); the reactivation hands out a new one through
  `onInputReady`, on which held keys should be resynchronized.
- `onDisplayControlReady` runs once the first graphics frame has arrived:
  KRdp ignores a monitor layout that arrives before its video stream starts.
- Clipboard text is sent as CF_UNICODETEXT with CRLF line ends and delivered
  with LF line ends. A Format List, Format Data Request or File Contents
  Request the session cannot parse is answered with a failure response
  (MS-RDPECLIP 3.1.5.2.2, 3.1.5.4.3, 3.1.5.4.6) instead of none.
- Stop advertising TSSNDCAPS_VOLUME: the client never applies Volume PDUs.
- Decode AVC444 and AVC444v2 from encoders that crop the coded picture in the
  SPS, such as FreeRDP 3, and place AVC444v2 chroma at the width the encoder
  packed it at.
- Present FreeRDP's x264 video in the specified full-range BT.709. The
  limited-range BT.601 colours apply only to KPipeWire's libx264 encoder
  (KRdp), which `RDPVideoToolboxFrameDecoder.reset()` now also forgets.
- Keep a surface's pixels outside a keyframe's region rectangles instead of
  clearing them to black.
- Video the decoder drops for a hidden surface before its first keyframe no
  longer counts as drawn, so copies out of that area carry what was there.
- Reject a SurfaceToSurface or CacheToSurface whole when any destination is
  outside the surface.

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
- A live session times out when a reactivation's finalization or a reopened
  RDPGFX channel's capability confirm never arrives, instead of waiting
  forever.
- `RDPWireEvent.bytes` returns nil for signed digits such as `+f` instead of
  decoding them.
- A live session the server ends while a frame is still being handled ends
  as the server said, for example gnome-remote-desktop's clean logoff, instead
  of failing on the frame acknowledgement that meets the closed connection.
- A server that closes the connection before TLS starts fails the TLS
  handshake instead of trapping on a leaked promise in debug builds, and one
  that closes it at once fails the connect with "the server closed the
  connection" instead of SwiftNIO's `notFound`.
- `RDPAudioPlayer` drops audio queued while its engine is stopped, so the next
  sample restarts playback instead of audio staying silent after an
  interruption.
- Bound the changed areas held for a primary-surface frame the server never
  ends, and stop walking nested CAVideo tile sets in diagnostic summaries,
  which a server could nest deep enough to overflow the stack.
- `RDPFrameDecodeQueue` drops deleted surfaces and evicted cache entries even
  when the frame that reports them fails to decode.
- Read AVC420/AVC444 region rectangles relative to the update or in surface
  coordinates the same way in every decoder step, so the regions are presented
  and chroma-combined where the video wrote them, and ignore an inverted region
  instead of wrapping it onto another part of the surface.
- A second DisplayControl or audio dynamic channel replaces the first, as a
  second RDPGFX channel already did, so the old channel's data and Close no
  longer reach the new one.
- Cut long clipboard file names between surrogate pairs, not inside one.
- Name each deleted surface and evicted cache slot once in the next graphics
  snapshot, so the lists stop growing for a server that never shows a frame.
- Certificate trust evaluation gets a thread even while busy work holds every
  CPU, instead of stalling for the whole timeout and reporting a trusted server
  as untrusted.
- A video update's region rectangles collapse into their bounding box past
  1,024 of them or when they cover the update more than four times over, so a
  server cannot make applying them take unbounded time.

### Performance and examples

- Mutate RDPGFX surfaces and reassemble channel messages in place, speed up
  ZGFX, NSCodec, CAPROGRESSIVE and hex formatting, and build diagnostic report
  entries only while the report keeps them.
- `RDPFrameDecodeQueue` composes partial video updates without copying whole
  surfaces. It converts only the decoded block the update's regions copy and
  draws presentation buffers from a pool. A partial 4K update now takes about a
  quarter of the time. The frames of composed presentations no longer carry
  `decodedBitmapData`; their pixels are in `imageBuffer`.
- Bitmap snapshots list an area drawn again, or inside or partly over one
  already drawn, once, so its pixels are merged once.
- `RDPScrollWheelAccumulator` turns scroll deltas into wheel events.
- The RDPClient example runs sessions on a dedicated thread, fixes modifier,
  focus-loss, toggle-key, Windows-key and keypad input, keeps a key held as a
  scancode repeating as that scancode once its modifier is released, leaves
  Cmd-. to the server instead of ending the session, and pins a redirected
  server's certificate under its own host. The command-line
  tools share argument parsing through `RDPCommandLineSupport`.
- RDPClient releases modifiers whose release it never saw (one made while a
  menu is open), detaches input, display control and clipboard when a session
  ends, sends the window's size to each new display-control session (also
  after a redirection), keeps the password and Remember choice passed in from
  the Connections window, gives the desktop keyboard focus when it appears,
  reads copied files off the main thread, downloads remote clipboard files in
  ranges of up to 1 MiB, and keeps clipboard sharing on after "Share for 30s".
- RDPClient asks before sending credentials to a server whose certificate
  neither the system nor the user trusts, unless the profile hides certificate
  warnings, and always refuses a certificate that replaced one the user
  trusted. Trust and Connect saves the certificate and connects again;
  trusting a certificate for a host replaces the previous one.
- `RDPConnectionIdentity.credentialAccountName` lowercases the host, as
  `hasSameConnectionIdentity(as:)` matches it; RDPClient moves a password saved
  under the old name the first time it misses.
- RDPFirstFrameCapture captures for the whole settle window and says why none
  decoded. RDPFrameBenchmark validates its sizes, reports why a profile failed
  and exits 1, and reports stages `cgImage` does not time as n/a. Both tools
  and RDPPreflight reject frame counts above 120.

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
