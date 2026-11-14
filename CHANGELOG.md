# Changelog

## Unreleased

### Compatibility and fixes

- A Windows Remote Desktop Session Host that licenses the connection no longer
  fails it as a protocol violation: RDPKit reads the RSA key of the licensing
  certificate itself. Security gives no key for that certificate, whose
  SubjectPublicKeyInfo names a signature algorithm, not rsaEncryption.

## 0.9.1

### Compatibility and fixes

- xrdp no longer rejects the Client Info and closes the connection: it sets
  INFO_MAXIMIZESHELL, which xrdp requires.

## 0.9.0

### Breaking changes

- `RDPPasteboardClipboard.Event` has new cases, `localFilePasteProgress(_:)`
  and `localFilesPasted(count:)`, which an exhaustive `switch` handles.

### Additions

- `RDPPasteboardClipboard.receiveLocalFilePasteProgress(_:)` takes what
  `onClipboardLocalFilePasteProgress` reports, and says when the server starts
  pasting each file the bridge shared, of many files once per tenth, and when
  it has the last one whole. RDPClient shows both.

## 0.8.0

### Breaking changes

- Clipboard files have no size limit by default: a published file is read
  from disk as the server asks for it, and a download writes each range to
  disk. `RDPClipboardDownloadLimits.maximumTotalByteCount` and
  `RDPPasteboardClipboard.maximumLocalFileByteCount` were 32 MiB.
- `downloadRemoteFiles(_:copyNumber:into:progress:finishFile:)` replaces
  `writeFile`: it writes each file itself and hands `finishFile` its URL, the
  place to set a quarantine mark. `RDPPasteboardClipboardSession` requires it
  and `maximumFileByteCount`.
- `RDPClipboardLocalFileReadError` has new cases, `fileTooLarge(_:)` and
  `filesNotSupported`.
- The clipboard advertises CB_HUGE_FILE_SUPPORT_ENABLED to a server that
  does.

### Additions

- `RDPClipboardSession.maximumFileByteCount`: the largest file the server's
  clipboard takes, nil when it takes none, as with KRdp 6.8.
- `RDPClipboardLocalFile(fileURL:maximumByteCount:)` publishes a file on disk.
- Download ranges grow from 512 KiB up to `maximumRangeByteCount`, 8 MiB,
  while the server answers them quickly. GNOME Remote Desktop 51 fails its
  own files past 2 GiB, which stop with `RDPClipboardDownloadError.refused`.
- `onClipboardLocalFilePasteProgress` reports how far the server's paste of
  published files is.
- Shared drives report changes, so the server lists a folder again: FSEvents
  on macOS and Mac Catalyst, a kqueue watch on each watched folder elsewhere.
  Closing a handle completes the notifications waiting on it.
- Shared drives apply FILE_ATTRIBUTE_READONLY, set later or at create, as a
  file's write permissions, and refuse to delete a read-only file until it
  is cleared, as NTFS does.
- `RDPClipboardTestServer.settle(alongside:)` settles the server and a queue
  its handlers hand work to, such as the main one.

## 0.7.0

### Breaking changes

- New `RDPConnectionFailure` cases, which an exhaustive `switch` handles:
  - `legacyCredSSPVersion(version:)`: Network Level Authentication refuses a
    server that answers with CredSSP version 2, 3 or 4, as Windows clients
    do, before sending any credential (CVE-2018-0886).
    `RDPConnectionConfiguration.legacyCredSSP` accepts them for that server
    only, never for a Server Redirection's target.
    `RDPLegacyCredSSPConsent` keeps the rule for an app: connect without it,
    offer it after this failure, and allow it for the next connection to that
    server once the user agrees (`connectionEnded(report:)`, `allow()`,
    `allowedTarget`, `reset()`).
  - `noConnectionConfirm(reason:)`: the server sent no X.224 Connection
    Confirm, in place of `connectionClosed`, `connectionLost`, `timedOut` and
    `protocolViolation` at that stage. `RDPNoConnectionConfirmReason` says what
    came instead: a close, a reset, nothing, or another protocol's first bytes.
  - `credSSPClosedAfterCredentials`: the server dropped the connection after
    NTLM proved the credentials and before answering them, as a CredSSP
    version 2 server does for a wrong password.
  - `noFramePresented(framesReceived:lastNotPresentedReason:)`: a live session
    activated but showed no frame within the timeout, in place of
    `graphicsFrameHandler` and `timedOut`.
- `RDPConnectionConfiguration.legacyRSAKeyExchange` is an
  `RDPLegacyRSAKeyExchange`: `.never` (the default); `.fallback`, which
  connects again within the run offering only RSA key exchange when a
  certificate refuses ECDHE, before any credential is sent; or `.always`,
  which is what `true` was.
- The remote-copy handlers, `onClipboardText`, `onClipboardContent`,
  `onClipboardFileGroupDescriptor` and `onClipboardRemoteCopyUnavailable`, get
  the copy's number as a second argument: write `{ text, _ in }`.
- The session asks the server for a keyframe itself after video fails to
  decode (see below). An app that resends a layout for one turns
  `recoversVideoWithLayoutResend` off or drops its own.
- `onDisplayControlReady` runs before `onGraphicsFrame` gets the first frame,
  still only once it has arrived. Choose the first layout from the session's
  `serverMonitors`.
- `RDPDisplayControlSession.send(_:)` returns a discardable `Bool`, which
  `try?` does not discard: write `_ = try? session.send(layout)`.
- `RDPVideoToolboxFrameDecoder` throws `RDPVideoDecodeError.needsCompositor(_:)`
  for `.surfaceCopy` and `.alpha` snapshots, which it took for empty video.
- While `fetchesRemoteCopies` is off, a server that empties its clipboard is
  reported at once, with `isEmpty` true. A restarted server clipboard sets
  `fetchesRemoteCopies` back to `clipboardFetchesRemoteCopies` before
  `onClipboardReady`, so a client that turned it off does so there again.
- `RDPClipboardRemoteFileTransferPlanningError` has a new case,
  `fileCountLimitExceeded`. File-contents answers to streams from
  `RDPClipboardSession.firstDownloadStreamID` (`0x8000_0000`) up go to the new
  download instead of `onClipboardFileContents`.

### Additions

- Display Control and the server's layout:
  - `RDPDisplayControlSession` has `serverMonitors` and
    `serverMonitorLayoutIssues` as the latest ResetGraphics laid them out,
    `graphicsResetCount`, `isEnded`, `isLastSentLayoutPending`,
    `resendLayout()` and `requestKeyframe()`; `send(_:)` says whether a layout
    went out, and `RDPDisplayRequest.monitorLayout` is public.
  - Keyframe recovery: once the frame handler throws
    `RDPGraphicsFrameNotPresented` for a video frame, as
    `RDPFrameDecodeCompletion.requirePresented()` does for a failed decode, the
    session sends a layout that keeps the desktop as it is, at most one every
    3 seconds and 3 until video decodes again; `rdpKeyframeRequestCount`
    counts them. Windows 11 and gnome-remote-desktop answer with a keyframe,
    which they send no other way.
  - `RDPRemoteMonitor.index`, `RDPMonitorLayout(remoteMonitors:scaleFactors:)`,
    a public `formsOneGroup`, `monitorLayoutIssues` on frames and the report,
    `graphicsResetCount` on frames and `RDPFrameMetadata`, and
    `RDPConnectionConfiguration.receivesServerMonitorLayout`.
- Clipboard files both ways:
  `RDPClipboardFileGroupDescriptorW.downloadPlan(limits:)` plans a remote copy
  within `RDPClipboardDownloadLimits` (32 MiB, 1,000 files, 512 KiB ranges,
  two minutes a request), and
  `RDPClipboardSession.downloadRemoteFiles(_:copyNumber:into:progress:writeFile:)`
  fetches it until a newer copy replaces it, the connection closes or the
  server refuses, stalls or cuts it short.
  `RDPClipboardLocalFile.read(contentsOf:maximumTotalByteCount:)` reads files
  to publish, and `beginLocalCopy()` with `publishLocalFiles(_:forCopy:)`
  offers them unless a newer copy came first.
- Clipboard sharing that follows the user: `clipboardFetchesRemoteCopies`,
  `startFetchingRemoteCopies()`, `serverHoldsLocalCopy` and
  `withdrawLocalCopy()` turn sharing on and off without losing or replacing a
  copy the user made.
- `connectAttempts` and `connectRetryDelay` try a TCP connect again when it
  fails before the server answers, as the first connection into the local
  network does while Apple platforms ask for access. The report's
  `connectAttempt` and `nextConnectAttemptDate` follow it, live too.
- `storedClientLicenseProvider` and `onClientLicenseIssued` read and save the
  client license only once a server licenses. A stored license the server
  rejects gets one more connection without it
  (`rdpStoredClientLicenseRejected`).
- The report adds `credentialsVerifiedBeforeActivation`, also on the input,
  display and clipboard sessions' `RDPConnectionContext` with
  `redirectionDepth`; `usedLegacyRSAKeyExchange`; `presentedFrameCount` and
  `runPresentedFrameCount`; `targetHost`, `targetPort` and
  `redirectionNamedHost`; `rdpLogonNotification` and `rdpLogonErrorInfo`;
  `rdpKeyboardIndicators`, also `RDPInputSession.serverToggleKeys`; and
  `rdpGraphicsFailureUpdateFirstMessageIndex` and
  `rdpGraphicsFailureUpdateMessageCount`.
- `RDPLiveSession` runs a connection for an app whose interface lives on the
  main thread: it decodes off it and delivers frames, failures, wire samples
  and the server's layout (`onServerLayout`, `RDPServerLayout`) on the main
  queue, with `deliver(_:)` and `recipient(_:)` for the app's own work,
  `cancel()`, and `waitUntilEnded(timeout:)` for quitting. The main queue has
  to run on the main thread, as an app's run loop runs it: under
  `dispatchMain()` it and `RDPAudioPlayer` stop with a message saying so.
- `RDPTrustedServerCertificates` trusts a server's certificate on first use,
  per host and port. `RDPConnectionIdentity.legacyCredentialMoves(keptBy:)`
  plans moving saved passwords to an account's current name.
- `RDPKeyboard`, the layout, type and subtype a client announces, also as
  `RDPConnectionConfiguration.keyboard`, and `character(for:shift:capsLock:)`,
  what Windows types for a scancode, from tables Windows 11 reported for every
  layout a Mac announces, Japanese included.
- `RDPScrollWheelAccumulator.events(deltaX:deltaY:isPrecise:at:)` takes an
  AppKit scroll, and `RDPDesktopSize(_:)` an `RDPDisplayRequest`.
- `RDPRemoteDisplayViewport` shows part of the desktop (`sourceRect`,
  `init(frame:monitor:bounds:coordinateOrigin:)`), draws on whole screen
  pixels (`backingScaleFactor`) and maps points past the desktop
  (`nearestRemotePoint(from:)`); `RDPFrameSampleBufferFactory.sourceRect` crops
  to it.
- `RDPDiagnosticText` formats what a diagnostics view shows: units, pixel
  formats, hex codes, and summaries of a report's channels, capabilities,
  messages, graphics failure, redirection and termination.
- The new `RDPKitAppKit` library, for macOS, holds what RDPClient and RDPeek
  each had:
  - `RDPRemoteInputView` sends keyboard, mouse and scroll input to an
    `RDPInputSession`; the keyboard handling behind it is public as
    `RDPMacKeyboardLayout`, `RDPMacKeyboardMapping`, `RDPMacModifierKey`,
    `RDPMacDeferredModifierKeys` and `RDPMacDeadKeys`.
  - `RDPRemoteDesktopVideoView` and `RDPRemoteDesktopVideoLayout` show decoded
    frames through an `AVSampleBufferDisplayLayer`, and `RDPFramePresenter`,
    over `RDPFramePresentationClock` and `RDPFramePresentationBuffer`, paces
    them to the display.
  - `RDPPasteboardClipboard` bridges the pasteboard and a session's clipboard:
    text and files both ways, temporary sharing, quarantined downloads, and
    `onEvent` for the app to word, with `downloadLimits`,
    `maximumLocalFileByteCount` and `temporarySharingDuration` to name.
- The new `RDPKitTesting` library holds in-memory servers for an app's tests:
  `RDPClipboardTestServer`, the server end of a clipboard channel, and
  `RDPDisplayControlTestServer`, which hands out a real
  `RDPDisplayControlSession` and lays out monitors with
  `resetGraphics(monitors:issues:outputRect:)`.
- RDPClient is built on all of the above.

### Security

- Data sent along with the X.224 Connection Confirm ends the connection
  before TLS. It was read later as if TLS had protected it, so it could
  inject PDUs such as a Server Redirection.
- Wire transcripts and report hex zero a Server Redirection's cleartext
  password also where another field overlaps it.
- One RemoteFX or RemoteFX Progressive message can no longer make gigabytes of
  tiles or keep the session drawing for seconds; a graphics frame's copies
  count toward its 1 GiB bound; a Monitor Layout PDU of more than 16 monitors
  is refused.
- A server that stops reading, or floods shared-drive requests and listings,
  can no longer make the client hold data without bound.
- Remote file names are numbered in linear time.
- RDPClient deletes the saved password of an account no profile uses.

### Compatibility and fixes

- NTLM upper-cases the user name with Windows' own table, so user names with
  µ, ı, ſ, ς, Georgian letters or characters outside the BMP sign in.
- xrdp's RDPGFX messages longer than 1,500 bytes no longer end the session.
- Video waits for a keyframe after VideoToolbox invalidates its session, as
  iOS does in the background; an HEVC stream also restarts at a BLA picture.
- RDPGFX: video is no longer painted over when a frame changes more than
  1,024 areas around it, NSCodec surface bits are the right way up, a second
  channel starts ClearCodec afresh, and RemoteFX tiles that are replaced or
  not drawn are not decoded.
- A Set Error Info of ERRINFO_NONE clears an earlier error, so the session
  reactivates after a Deactivate All.
- After a Server Redirection with no credentials configured, the reconnect
  sends the redirection's user name and domain.
- Input and layouts sent as the session deactivates or Display Control ends
  are dropped; `shouldCancel` is polled while a reply waits for room; a
  stalled network volume no longer holds up announcing shared drives.
- Clipboard: a server copy announced while the client's copy is unanswered no
  longer replaces what the user just copied; a malformed Format Data Response
  still answers its request; a file copy's other formats are fetched when the
  app takes no file lists.
- `RDPAudioPlayer` keeps playing after the output device changes, and
  `RDPRemoteDisplayViewport` maps an AppKit view's top pixel row.
- RDPClient: Control shortcuts reach the letters shown on more Mac layouts,
  Caps Lock stays in step, keys held when a menu opens are released, Port takes
  every TCP port, profiles keep the right saved passwords, a password is saved
  only when the server checked it, and a Keychain prompt no longer freezes
  the windows.
- RDPFirstFrameCapture goes on after a frame fails to decode;
  RDPFrameBenchmark's `--frames` takes 1 to 60.

## 0.6.0

### Breaking changes

- `RDPConnectionFailure` has a new case, `rdSTLS(resultCode:)`, and
  `RDPConnectionStage` a new stage, `rdSTLS`.
- The handlers of `RDPFrameDecodeQueue` and `RDPWireReceiveMetricsCoalescer`
  are `@Sendable`; they run on threads of their own.

### Additions

- `run` and `connect` take `audioPlaybackDelay`, so each Wave Confirm says
  when its sample is heard and the server can keep video in step with the
  sound. `RDPAudioPlayer.playbackDelay` supplies it.

### Security

- A server can no longer reach outside a shared drive's folder by renaming
  directories and links under open handles, or exhaust the app's file
  descriptors: all drives hold at most 64, and FIFOs, sockets and devices
  are neither opened nor listed.
- Once the server announces a copy, the clipboard stops offering the app's
  earlier one, which the server could otherwise read for the whole session.
- Remote files are never saved under a hidden name: a leading "." becomes
  "_".
- Wire transcripts and report hex redact a redirection password even in a
  Server Redirection or Save Session Info PDU that RDPKit cannot fully read.
- A graphics frame is bounded in the memory its updates hold and the pixels
  each one writes.
- Drive and clipboard replies wait while 32 MiB is unsent, so a server that
  stops reading cannot make the client queue data until memory runs out.

### Compatibility and fixes

- GNOME Remote Login gets past the system sign-in: after its redirection,
  RDPKit authenticates with RDSTLS, as FreeRDP does.
- A Windows 11 graphics confirmation with both AVC_DISABLED and
  AVC_THINCLIENT set no longer ends the session.
- NLA works with a certificate signed with RSASSA-PSS and SHA-384 or
  SHA-512.
- FreeRDP's Bandwidth Measure Stop without payload gets its results.
- Remote copies keep coming after a response that is malformed or over
  64 MiB, or after the server's clipboard restarts.
- Remote file names are made unique as APFS compares them, so none is saved
  over another, and quickly for many files of one name.
- Shared drives are announced again when the server restarts device
  redirection, pending deletes happen when the session ends, and an
  undefined CreateDisposition no longer truncates a file.
- A refused SurfaceToCache empties its cache slot instead of leaving the old
  pixels for CacheToSurface.
- A receive that the event loop reaches after its deadline still times out.
- No callback or transcript entry comes after `run` returns or after
  `cancel()` on the decode queue or metrics coalescer.
- No crash for `RDPAudioPlayer(maximumQueuedSeconds: .infinity)` or for a
  clipboard bitmap of 4 GiB or more.

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
