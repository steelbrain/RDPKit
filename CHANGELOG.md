# Changelog

## Unreleased

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
