# Changelog

## Unreleased

- Add GNOME Remote Desktop compatibility by following server redirection PDUs, reconnecting with the server-provided routing token, and handling GNOME's connect-time bandwidth auto-detect exchange.
- Add parsing for RDP server-redirection fields, including load-balance cookies, target host names, redirected credentials, redirection GUIDs, and target certificates, while avoiding redirects when unknown flags make the field layout ambiguous.
- Improve dynamic virtual channel interoperability by advertising and emitting ShowProtocol framing for `drdynvc` traffic where required by GNOME Remote Desktop.
- Add `RDPWireTranscript` capture support and a `RDPFirstFrameCapture --capture-transcript` option for recording negotiation traffic up to the first graphics frame.
- Add a real GNOME Remote Desktop negotiation fixture plus an offline transcript replay server that regression-tests redirect/reconnect, auto-detect, RDPGFX negotiation, and first-frame detection without requiring a live GNOME host.

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
