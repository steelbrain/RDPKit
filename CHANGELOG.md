# Changelog

## Unreleased

### Breaking changes

- `RDPConnectionError` is a struct with `failure` (`RDPConnectionFailure`)
  and `description` instead of an enum: match `error.failure` instead of its
  cases. `connect` now throws only `RDPConnectionError`.
- `RDPCredentialValidationError` has a new case, `fieldTooLong(_:)`: a
  `switch` over it needs that case or a `default`.
- Once the graphics have opened, a session that an administrator, a time
  limit or another connection ends is an ended session (`status` "success",
  no `error`, `remoteTermination` set), not a failure.
- Set Error Info 0xB is named `ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER`.
  `error` names RDP_NEG_FAILURE codes, as in "RDP negotiation failed with
  HYBRID_REQUIRED_BY_SERVER (0x00000005)", and the newly named Set Error Info
  codes. The RDP-specific codes 0x10C9–0x1195 are named as [MS-RDPBCGR]
  2.2.5.1.1 spells them, such as `ERRINFO_CONNECTFAILED` (FreeRDP:
  `ERRINFO_CONNECT_FAILED`) instead of `ERRINFO_0x000010d3`.

### Additions

- `RDPConnectionReport.failure` (`RDPConnectionFailure`) says why a run failed
  without matching text: connect errors with their errno and a category
  (`RDPSocketError`), RDP_NEG_FAILURE codes (`RDPNegotiationFailureCode`),
  TLS failures, including `tlsKeyUsageIncorrect` (retry with
  `legacyRSAKeyExchange`), CredSSP NTSTATUS codes (`RDPLogonStatus`), missing
  credentials, Early User Authorization, licensing, server termination, lost
  or closed connections, timeouts, cancellation, protocol violations and a
  throwing `onGraphicsFrame`. A configuration RDPKit cannot send
  (`invalidConfiguration`: credentials longer than the Client Info PDU or
  NTLM holds) and a failure
  on the client's side (`clientFailure`) are not protocol violations.
  `error` keeps the details in words.
- `RDPConnectionStage` is public, and `report.connectionStage` returns it.
  `report.remoteTermination` (`RDPRemoteTermination`) names the Set Error
  Info code ([MS-RDPBCGR] 2.2.5.1.1) and gives its category: user, admin,
  time limit, replaced, access denied, licensing and others.
- `RDPConnectionConfiguration.clientName` sets the name servers show for the
  client in session lists and per-device licensing, instead of `RDPKIT`. It
  goes in the Client Core Data, the licensing request, NTLM's
  AUTHENTICATE_MESSAGE and the rdpdr Client Name Request; control characters
  are dropped and it is cut to 15 characters.
- `RDPConnectionConfiguration.scaleFactors` (`RDPDisplayScaleFactors`) and
  `physicalSize` (`RDPDisplayPhysicalSize`, in millimetres) go in the Client
  Core Data, so a session starts at the client's scale, also on servers
  without Display Control. The defaults send 100% and no size, as before.
  Values set after the initializer are clamped the same way when the
  connection starts, as are `desktopWidth` and `desktopHeight`.
- Auto-reconnect: `report.rdpAutoReconnectCookie` (`RDPAutoReconnectCookie`)
  keeps the latest cookie the server sent, and
  `RDPConnectionConfiguration.autoReconnectCookie` sends it back in the Client
  Info PDU to reconnect to the same session. CredSSP still needs the
  credentials. The cookie is a secret: the report's encoding, descriptions
  and mirrors keep only its logon ID, and wire transcripts never record the
  client's PDUs.
- `RDPMonitorLayout` describes up to 16 monitors, including ones left of or
  above the primary at negative coordinates. Its initializer checks the
  [MS-RDPEDISP] rules and throws `RDPMonitorLayoutError` naming the rule
  broken. `RDPDisplayControlSession.send(_: RDPMonitorLayout)` sends it, and
  throws when the server's MaxNumMonitors or monitor area refuses it.
  `RDPDisplayControlMonitorLayout.isPrimary` reads and sets the primary flag.
- `RDPConnectionConfiguration.monitorLayout` starts a session with several
  monitors. It goes as Client Monitor Data and Client Monitor Extended Data,
  with the desktop set to their bounding box, up to 32,766 x 32,766 pixels,
  to servers that accept extended client data blocks. A layout whose
  monitors form separate groups is dropped: Windows 11 starts one monitor of
  their bounding box instead. Display Control still sends one. The server's
  Monitor Layout PDU is recorded in `RDPConnectionReport.rdpMonitorLayout`,
  which an `RDPLiveConnectionReport` snapshot shows as soon as it arrives.
  Without a layout, the connection sends exactly what it sent before.
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
  server's first copy. Joining still announces the client's clipboard, empty
  until it publishes, and Windows 11 then empties its own clipboard;
  `clipboardEnabled` off leaves it untouched. Turned back on, it fetches the
  last copy the server announced meanwhile, unless the client has published
  since, so a client that decides later, on the main thread for instance,
  still gets a copy that came in between. `isAwaitingRemoteCopy` tells
  whether a copy is being fetched.
- `RDPClipboardSession.deliveredRemoteCopyNumber`, read in a clipboard
  handler, numbers the remote copy it is called for, and
  `hasPublished(since:)` tells whether the client has published since,
  replacing that copy on the server. A client that hands remote copies to
  another thread can drop one there that a publish made in the meantime
  replaced, including the copy `fetchesRemoteCopies` reports when turned on
  right before publishing.
- `run` and `connect` take `onClipboardRemoteCopyUnavailable`
  (`RDPClipboardRemoteCopyUnavailableHandler`), called when the server
  announces a copy none of which is fetched, so the copy delivered before is
  no longer the server's. `isEmpty` is true for an empty Format List, which
  Windows 11 sends when its clipboard is emptied, and false for a copy of
  only formats the session does not fetch, such as an image without
  `onClipboardContent`. It is not called while `fetchesRemoteCopies` is off;
  such a copy is reported once fetching is turned back on, unless a newer
  copy, local or remote, came first.
  gnome-remote-desktop 51 sends nothing when its clipboard is cleared.
- `RDPRemotePointerBitmap(_:)` turns an `RDPRemotePointerImage` from
  `onRemotePointer` into premultiplied RGBA (`pixels`, `bytesPerRow`) and a
  hot spot clamped into the image, with a `cgImage` for
  `NSCursor(image:hotSpot:)` or a UIKit pointer style. It reads 1, 16
  (RGB565), 24 and 32 bpp masks, 1-bpp masks top-down as rdesktop and
  FreeRDP do. A 32-bpp shape with alpha uses that alpha alone, and its
  colors are taken as premultiplied, as Windows and gnome-remote-desktop
  send them, unless one is above its alpha, as KRdp's are. Its pixels match
  Windows 11's own drawing of its cursors, except that pixels that would
  invert the screen become black with a white outline. It is nil for 4 and
  8 bpp, empty images and masks of the wrong length.
- `RDPRemoteDisplayViewport.remotePoint(from:contentRect:)` maps a point with
  the desktop drawn in a given rect, such as `contentRect` aligned to the
  screen's pixels.
- `RDPLiveConnectionReport` reads a connection's report while `run` or
  `connect` runs. Pass one as `liveReport`, then read `snapshot` from any
  thread: a copy of the report so far, with `status` "running", the stage
  the connection is in, and no `nextStage`. It follows a Server Redirection
  to its target. Once the call returns, it is the report the call returned
  or attached to the error `connect` threw.
- `RDPConnectionReport.rdpGraphicsFrameAcknowledgeCount` counts every frame
  acknowledgement the session sent, RDPGFX and fast-path.
  `rdpGraphicsFrameAcknowledgeHexes` still keeps only the first ones: as many
  as a capture run's frames, 8 in a live session.
- `RDPRenderMetrics.rollingFramesPerSecond(at:)` and
  `rollingWireMegabitsPerSecond(at:)` read the rates of the 5 s up to a given
  time, so they fall once traffic stops, to 0 when that window holds none.
  The `rollingFramesPerSecond` and `rollingWireMegabitsPerSecond` properties
  are deprecated: they keep the rate as of the last frame or sample.
  `averageWireMegabitsPerSecond(at:)` reads the average the same way; the
  `averageWireMegabitsPerSecond` property, deprecated, reads it at the
  current time.
- `RDPCredentials.validated` also throws
  `RDPCredentialValidationError.fieldTooLong(_:)`, naming the
  `RDPCredentialField` (user name, domain or password) longer than
  `RDPCredentials.maximumFieldLength`: 255 UTF-16 code units, the Client
  Info PDU's limit, checked after `DOMAIN\user` is split. Apps can report
  the field before connecting instead of failing with
  `invalidConfiguration`.
- An `onGraphicsFrame` handler can throw `RDPGraphicsFrameNotPresented` for a
  frame it could not show, such as video that failed to decode. The session
  goes on and acknowledges the frame, but a live session keeps waiting for
  its first frame, within the timeout, until the handler shows one. If none
  is shown in time, it ends with `RDPConnectionFailure.graphicsFrameHandler`.
- `RDPInputSession.supportsUnicodeInput` tells whether the server takes
  Unicode keyboard events (INPUT_FLAG_UNICODE). `send` drops `.unicode`
  events when it does not, so an app can send scancodes instead.

### Compatibility and fixes

- A `storedClientLicense` too large for the Client License Information PDU
  no longer fails every connect: RDPKit asks the server for a new license
  instead and adds a `stored-license-too-large` report warning. A license
  the server then issues arrives in `report.rdpIssuedClientLicense`, so the
  app can replace the stored one.
- A Demand Active may set a desktop of up to 32,766 pixels each way, not
  only 8192. A session without RDPGFX that Windows 11 reactivates at
  11520x2160, for a Display Control layout of three 4K monitors, now draws
  at that size instead of failing the updates outside the old one.
- Connections: a live session's wait for its first frame is bounded by the
  timeout at every step, however much other traffic or how many empty frames
  the server sends. 0.4.0 bounded it only in capture runs. After its first
  frame a live session still waits indefinitely, with TCP keepalive.
- `RDPCredentials` splits a `DOMAIN\user` user name when no domain is given,
  as mstsc and FreeRDP do, so NTLM and the Client Info PDU carry the domain.
  A UPN stays as it is. `qualifiedUsername`, and so `credentialAccountName`,
  is unchanged; the report's `username` and `domain` show the two parts.
- NLA sends `clientName` as the NTLM workstation ([MS-NLMP] 2.2.1.3,
  3.1.5.1.2) instead of an empty one, whether or not the server negotiates
  NTLMSSP_NEGOTIATE_VERSION. Windows logs it as the logon's client machine
  instead of "Null".
- `RDPConnectionIdentity.hasSameConnectionIdentity(as:)` compares the user
  name and domain as `qualifiedUsername` joins them, so it is true exactly
  when the `credentialAccountName`s match: `LAB\anees` with no domain, which
  `RDPCredentials` signs in as `anees` in LAB, is the same account as `anees`
  in domain LAB. Without a user name, the domains still compare.
- Clipboard: local files reach the server under paths Windows accepts.
  `publishLocalFiles` treats `\` and `/` as folder separators, so a
  directory `Folder` and a file `Folder\notes.txt` paste as a folder holding
  the file; empty, `.` and `..` components are dropped. In each component it
  replaces `: * ? " < > |` and control characters with `_`, puts `_` before
  device names such as `CON`, `NUL.txt` and `CONIN$`, drops trailing dots and
  spaces, and shortens a component past 255 UTF-16 code units before its
  extension. A path past cFileName's 259 has its last component shortened,
  or goes to the top level when its folders leave no room. Paths that differ
  only in case are numbered in their last component. A folder numbered to
  differ from another folder or a file of its name keeps its number for
  everything inside it.
- Clipboard: publishing drops the remote copy being fetched, since the
  client's Format List replaces it on the server ([MS-RDPECLIP] 1.3.2.2.1),
  so a late answer is no longer delivered as text, content or a file list.
- Clipboard: a remote copy that arrives with nothing goes to
  `onClipboardRemoteCopyUnavailable` with `isEmpty` false, unless a newer
  copy came first: a copy whose only requested format failed (text only, or
  a file list), and a rich copy whose formats all failed or came back empty.
  A rich copy with some formats left still arrives through
  `onClipboardContent` without the rest.
- Clipboard: a local file name that starts with whitespace, such as
  " CON.txt", is no longer taken for a device name and reaches Windows
  unchanged: Windows 11 treats " CON" as an ordinary name, and Windows
  ignores only spaces after a device name. Names such as "CON .txt" and
  "NUL.txt" still get a leading "_", since Windows before 11 reserves them.
- Clipboard: names of local files offered to Windows lose only trailing dots
  and spaces (U+0020), as Windows path normalization does. Leading spaces,
  and other whitespace such as U+00A0, U+3000 and U+200B, stay in the name.
- Clipboard: remote file names saved on the client keep Unicode format
  characters such as ZWNJ, ZWJ, the soft hyphen and bidi marks, so
  "گزارش‌ها.pdf" no longer becomes "گزارش_ها.pdf". Control characters, line
  separators, `:` and the bidi embeddings, overrides and isolates still
  become `_`.

### Examples

- RDPClient:
  - Ends a session none of whose frames decode, for example video in an
    H.264 profile VideoToolbox refuses, at the connection timeout instead of
    staying on Connecting.
  - Explains why a session ended or failed in plain words, including the
    server's reason after the desktop was shown, and offers the credentials
    again after a refused sign-in. RDPKit's own text stays in Stats for
    Nerds. A session shown through bitmap updates without RDPGFX no longer
    ends as one that never opened RDPGFX. Settings that cannot be sent, such
    as an overlong password, offer the credentials again, and a failure on
    the Mac no longer blames the server.
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
  - With a Japanese input source that types with ABC or US, announces
    Windows' Japanese layout (0x00000411), so the server starts its Japanese
    IME: as a 106/109-key keyboard (type 7, subtype 2) on a JIS keyboard,
    where the JIS keys go as their scancodes, and as a 101-key one (type 7,
    subtype 0) on an ANSI or ISO keyboard, which types what US English
    types. Every other input source announces its own layout. With the
    101-key keyboard, left Option and the key left of 1 (Alt-`) turn the
    remote IME on and off, and Control-` reaches Windows as VK_DBE_DBCSCHAR
    rather than `` ` ``. On a JIS keyboard, Eisu and Kana go as LANG2 and
    LANG1 (0x71 and 0x72) with every layout, which Windows' Japanese layout
    turns into IME Off and On with either keyboard type, Shift held or not,
    instead of typing a space.
  - Windows applies the announced layout only to a session it creates:
    reconnecting to an existing session keeps that session's layout, so keys
    sent as scancodes type its characters.
  - Scrolling with Command held sends the Windows key with the wheel, so
    releasing Command no longer opens the server's Start menu. Keypad "="
    goes as Unicode where the remote layout has no "=" on the main "=" key,
    as on German.
  - A dead key's accent typed before Return, Tab, Esc or keypad Enter reaches
    the server, as on the Mac: Option-E then Return types "´" and a new
    line. Tapping Command or right Option while the other is already down on
    the server, for example after a Command-click, no longer sends a lone
    Win or Alt tap. A right Option key that a custom layout gives no output,
    without making it a dead key, goes as Alt and the key instead of sending
    nothing.
  - After left Option-E goes to the server as Alt-E, a shortcut, the next key
    goes as what it types on its own, not the accented character macOS
    composes, so menu accelerators and readline's Option-U then a letter
    work, and Option-E then Return no longer types "´" first. Right Option
    does the same once its Alt is on the server. A letter typed with Caps
    Lock on goes as its scancode, as without it.
  - When the server takes no Unicode input, RDPClient sends the keys pressed
    instead of dropping text: right Option goes as Alt (AltGr) at once, and
    characters, dead keys included, go as their scancodes for the server's
    own layout to type. The Mac's composed characters and accents are not
    sent.
  - RDPClient keeps track of held keys while it has no session, so a
    session attached later is not sent a stale key, such as a Windows key
    release left over from a Command shortcut pressed before it attached.
  - Clipboard sharing can be turned on mid-session; with it off, nothing
    crosses either way. To allow that, RDPClient always joins the clipboard
    channel, which empties a Windows server's clipboard at connect. Turning
    sharing off, or a 30 s share ending, empties the server's clipboard only
    while it holds the Mac's copy, so text the server's user copied during
    the share stays.
  - When the server empties its clipboard, as a password manager does,
    RDPClient clears the pasteboard if it still holds the text or files that
    came from the server; a local copy made since is kept. A server copy
    RDPClient takes nothing of, such as an image, cancels a remote file
    download in progress.
  - A server copy announced before the Mac's clipboard was sent, but
    reaching RDPClient after, no longer replaces the Mac's newer copy on the
    pasteboard, nor stops turning sharing off from taking the Mac's copy
    back. Turning sharing on, or connecting, with files copied on the Mac
    sends them as it sends text: the server's clipboard is emptied while
    they are read, so its copy from while sharing was off is not fetched in
    their place; a copy the server's user makes during the read still wins.
    A server copy that brings nothing, such as an image or one that failed
    to arrive, shows "No text or files arrived from the remote copy." Text
    too large to send (over 16 MiB) empties the server's clipboard, as files
    over 32 MiB do, so turning sharing back on with it no longer brings an
    older server copy onto the Mac.
  - The server's first copy reaches the Mac even when it comes before the
    clipboard bridge is ready, and the Mac's older clipboard no longer
    replaces it on the server; Sync Now sends the Mac's clipboard should
    that copy never arrive.
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
    - Sync Now and another "Share for 30s" send the clipboard when it
      changed, or again when it could not be sent, such as a file iCloud
      had not downloaded yet. They no longer cancel a download in progress.
  - A `\` in a copied file's name is sent as `_`, so Windows does not paste
    the file inside a folder.
  - On macOS 15 and later the display goes through the display layer's
    `sampleBufferRenderer` instead of the layer's calls deprecated there;
    macOS 14 keeps them.
  - Stats for Nerds shows the session's stage, TLS, protocols, channels and
    the rest of its report while it runs, not only once it ends. Frame Acks
    counts every acknowledgement instead of stopping at 8. The viewer's fps
    and rx overlay, and Stats for Nerds' Rolling FPS and Wire RX, fall to 0
    within 5 s of the screen going still instead of keeping the last
    burst's rates. The session window's footer shows the graphics path,
    such as the RDPGFX version and codec, while the session runs. The
    display link rate shows the screen's maximum refresh rate until the
    link first fires on that screen, not nothing or the previous screen's
    rate, and Stats for Nerds reads the average wire rate at the same
    instant as the rolling rates. A frame clock whose window closed no
    longer keeps watching screen changes.
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
    every Keychain item, then renamed in one step, so Delete Profile meanwhile
    no longer brings one back. RDPClient no longer sets a Keychain
    accessibility that the login keychain ignores.
  - Connecting before a lookup has answered waits for that answer instead of
    reading Keychain again, so the saved password is still filled in, or
    removed with Remember unticked; a password typed or a Remember choice
    made while the lookup was on its way stands. The Connections window does
    the same, and choosing Connect on a connection that is not selected
    fills the form from it once and looks its password up once. Saving a
    new connection keeps the form as typed, password included, instead of
    filling it again from the saved connection and reading Keychain. A session
    window opened from it takes the answer that
    window already had, so connecting reads Keychain once. Delete Profile
    learns from the deletion whether a password was saved instead of reading
    it first.
  - A password filled in while the Password field has focus is the one used,
    so the field's older text is no longer sent and then saved over it;
    typing in the field still changes it. A session window connects by
    itself only with the fields it opened with; editing a field cancels
    that, and any connection still waiting for Keychain.
  - Each saved connection is read on its own. One it cannot read, such as one
    a newer build wrote, no longer empties the list, and saving keeps it and
    any fields a newer build added. Saving a connection typed as `LAB\anees`
    updates the saved one for `anees` in domain LAB, which shares its saved
    password, instead of adding a second. Two saved connections for one
    account, saved by an earlier build, share its saved password: Delete
    Profile keeps it while the other remains, says so, and deletes it with
    the last. A password saved before 0.4.0 under the deleted connection's
    name, with the host's case as typed, moves to the account's current
    name, or is deleted if that name has a password already, so the
    remaining connection keeps it and nothing is left behind.
- RDPPreflight:
  - Prints `redirection depth: N` after `target:` when a Server Redirection
    led to the target, as its JSON's `redirectionDepth` already showed.
  - Prints `rdp graphics frame acknowledge count`, the number of frame
    acknowledgements sent, ahead of the first few it lists in full; the JSON
    carries it as `rdpGraphicsFrameAcknowledgeCount`.
- The command-line tools check credentials' length before connecting,
  naming the field that is too long.

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
