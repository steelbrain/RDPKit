# Changelog

## Unreleased

### Breaking changes

- The session asks the server for a keyframe itself after video fails to
  decode: an app that resends a layout for one, as RDPClient did, turns
  `RDPConnectionConfiguration.recoversVideoWithLayoutResend` off or drops its
  own, so the server is not asked twice.
- `RDPDisplayControlSession.send(_:)` for an `RDPMonitorLayout` returns a
  discardable `Bool`. `@discardableResult` does not cover `try?`, so
  `try? session.send(layout)` now warns that its result is unused, an error
  under warnings-as-errors: write `_ = try? session.send(layout)`.
- `onDisplayControlReady` runs before `onGraphicsFrame` gets the first frame,
  still only once that frame has arrived, so a handler whose first frame fails
  to decode can ask for a keyframe. A client that chose its first layout from
  the monitors of frames it saw before `onDisplayControlReady` reads the
  session's `serverMonitors` instead.
- Network Level Authentication refuses a server that answers with CredSSP
  version 2, 3 or 4, as Windows clients do by default, with the new
  `RDPConnectionFailure.legacyCredSSPVersion` and before sending any
  credential. Those versions prove the TLS key by sealing the certificate's
  raw public key, the encryption oracle of CVE-2018-0886.
  `RDPConnectionConfiguration.legacyCredSSP` accepts them for a server without
  the 2018 CredSSP update: connect with it off, and on that failure ask the
  user before connecting again with it on. It covers only that server: a
  Server Redirection's target answering below version 5 is refused the same
  way. `RDPLegacyCredSSPConsent` keeps that rule for an app: it offers the
  old version only after the server connected to answered with it, and
  allows it only for the next connection to that server once the user
  agrees. RDPClient offers Connect Anyway with it.
- `RDPVideoToolboxFrameDecoder` throws the new
  `RDPVideoDecodeError.needsCompositor(_:)` for `.surfaceCopy` and `.alpha`
  snapshots, which it took for empty video samples that stalled the surface's
  video until a keyframe. `RDPFrameDecodeQueue` already applied them.
- While `fetchesRemoteCopies` is off, `onClipboardRemoteCopyUnavailable` is
  called at once, with `isEmpty` true, when the server empties its
  clipboard; other copies still wait until fetching is back on.
- When the server's clipboard restarts, its Monitor Ready sets
  `RDPClipboardSession.fetchesRemoteCopies` back to
  `clipboardFetchesRemoteCopies` before `onClipboardReady` gets the session
  again, so a client that decides on another thread fetches nothing the
  restarted server announces before it has decided again. A client that turned
  fetching off sets it again in `onClipboardReady`, as on the first start.
- `RDPConnectionConfiguration.legacyRSAKeyExchange` is an
  `RDPLegacyRSAKeyExchange`: `.never` (the default), `.fallback` or
  `.always`, which is what `true` was. With `.fallback` a certificate that
  refuses ECDHE gets a second connection within the run, offering only RSA key
  exchange, before any credential is sent; a Server Redirection's target that
  refuses it still ends the run with `tlsKeyUsageIncorrect`. RDPClient falls
  back this way in place of its own retry.
- Two new `RDPConnectionFailure` cases, which an exhaustive `switch` handles,
  replace guesses from the stage:
  - `noConnectionConfirm(reason:)`: the server answered the connection request
    with no X.224 Connection Confirm. In place of `connectionClosed`,
    `connectionLost`, `timedOut` and `protocolViolation` at the negotiation
    stage. `RDPNoConnectionConfirmReason` says what came instead: a close, a
    reset, nothing, or `unexpectedReply(firstBytes:)`, the first 16 bytes of
    another protocol's reply, such as an SSH banner. Only that last one means
    another service for sure; a close or silence can also be a host at its
    connection limit or a firewall.
  - `credSSPClosedAfterCredentials`: the server closed or reset the
    connection during Network Level Authentication after the client's NTLM
    AUTHENTICATE proved its credentials, before answering them, with no
    NTSTATUS, as a CredSSP version 2 server rejects a sign-in. The credentials
    may be wrong. A close before the AUTHENTICATE is still `connectionClosed`
    or `connectionLost`, and one after the server answered them a plain close.
- A live session that activates but shows no frame within the timeout ends
  with the new `RDPConnectionFailure.noFramePresented(framesReceived:lastNotPresentedReason:)`,
  which an exhaustive `switch` handles: in place of `graphicsFrameHandler`
  when frames came that the handler could not show, and of `timedOut` when
  none came or the server did not set up its graphics. A capture run still
  times out with `timedOut`, and `graphicsFrameHandler` is now only a handler
  that threw another error. A client can retry such a session, as one with no
  desktop, without reading the stage and the first frame.
- The remote-copy handlers, `onClipboardText`, `onClipboardContent`,
  `onClipboardFileGroupDescriptor` and `onClipboardRemoteCopyUnavailable`, get
  the copy's number as a second argument, so a client no longer keeps the
  clipboard session to read `deliveredRemoteCopyNumber` in them: write
  `{ text, copyNumber in }`, or `{ text, _ in }`.
- `RDPClipboardRemoteFileTransferPlanningError` has a new case,
  `fileCountLimitExceeded`, which an exhaustive `switch` handles.
- File-contents answers to streams from
  `RDPClipboardSession.firstDownloadStreamID` (`0x8000_0000`) up no longer
  reach `onClipboardFileContents`: those streams are the new download's.

### Additions

- `RDPDisplayControlSession.serverMonitors` and `serverMonitorLayoutIssues`
  hold the server's monitors as its latest ResetGraphics laid them out: the
  first frame's when `onDisplayControlReady` hands out the session, so a client
  can keep the server's several monitors rather than send one.
- `RDPDisplayControlSession.send(_:)` says whether the layout went out, and
  `isEnded` whether the session sends anything more: once the server replaces
  its channel or the connection closes, a layout is for the next session.
  `send(_:)` for an `RDPDisplayRequest` returns a discardable `Bool` too,
  false also when the server's capabilities refuse the request.
  `RDPDisplayRequest.monitorLayout` is public, so a request goes through it.
- `RDPRemoteMonitor.index` is the monitor's place in the server's list, which
  stays put when RDPKit leaves out a monitor with nothing in the graphics
  output, so a client numbers displays as the server does.
- `RDPMonitorLayout(remoteMonitors:scaleFactors:)` makes a layout of the
  server's monitors, from a frame or the report, to keep or change them through
  Display Control, and `formsOneGroup` is public.
- Frames' `monitorLayoutIssues` and the report's `rdpMonitorLayoutIssues` say
  what is off about the server's monitor layout: a monitor RDPKit cut to the
  graphics output, monitors that overlap, no or several primary monitors, or
  part of the output on no monitor. KRdp's exclusive right and bottom edges
  count as exact: KRdp 6.8 always sends one monitor.
- `RDPConnectionConfiguration.receivesServerMonitorLayout` asks for the
  server's Monitor Layout PDU without sending a layout. Windows 11 and
  gnome-remote-desktop send their desktop; KRdp sends the size the client asked
  for, not the one it streams.
- Keyframe recovery: once the frame handler throws
  `RDPGraphicsFrameNotPresented` for a video frame, as the new
  `RDPFrameDecodeCompletion.requirePresented()` does for a failed decode, the
  session sends `RDPDisplayControlSession.requestKeyframe()`'s layout, which
  keeps the server's desktop as it is: the layout last sent while it is
  unanswered, otherwise that layout again when the server shows the monitors
  it asked for, or the server's one monitor at the scale last sent; a server
  that lists no monitors, as MS-RDPEGFX allows, has one of its graphics
  output's size. Several monitors laid out otherwise get no request: the
  server never says their scales, and asking for any could change them. It
  sends at most one every 3 seconds and 3 until video decodes again, holds one
  until Display Control is handed out, and `rdpKeyframeRequestCount` counts
  them.
  Windows 11 answered with a ResetGraphics and an IDR 0.23 s later, the
  desktop unchanged (observed live).
- `RDPDisplayControlSession.isLastSentLayoutPending` says whether the layout
  last sent is still unanswered: until a ResetGraphics lays out its monitors,
  or, from a server that changes what it is asked for, until one has come
  for it and each layout before it. A ResetGraphics for an earlier layout
  leaves it pending, so the keyframe request asks for it rather than the
  size the window left. Frames'
  `graphicsResetCount`, also on `RDPFrameMetadata` and the session, counts
  the connection's ResetGraphics PDUs, so a client sees the server lay out its
  graphics again even to the same size and monitors.
- `RDPDisplayControlSession.resendLayout()` sends `lastSentLayout` again, or
  `connectLayout`, the layout the connection started with. Windows 11 and
  gnome-remote-desktop answer it with a keyframe, which they send no other way
  after video fails to decode.

- `RDPRemoteDisplayViewport.sourceRect` and
  `RDPFrameSampleBufferFactory.sourceRect` show part of the remote desktop,
  such as one of its monitors: `init(frame:monitor:bounds:coordinateOrigin:)`
  maps input within an `RDPRemoteMonitor`, and the factory crops the picture to
  it.
- `RDPRemoteDisplayViewport.backingScaleFactor` puts `contentRect` on a whole
  screen pixel, keeping its size, so a desktop shown one to one in a view of
  odd width is not drawn half a pixel off and blurred; `remotePoint(from:)`
  maps where it is drawn. `nearestRemotePoint(from:)` maps a point past the
  desktop, such as a drag's, to its nearest pixel by the viewport's own edge
  convention, so a drag below a `.bottomLeft` view reaches the bottom row.
- The report's `rdpLogonNotification` says the server notified that a user
  logged on, and `rdpLogonErrorInfo` holds its latest logon error
  notification, as sent. Without Network Level Authentication a server
  activates the session whatever the password, so activation does not say
  the sign-in worked; a user who logs on at the server's own logon screen is
  notified too.
- The report's `rdpKeyboardIndicators` holds the toggle keys the server last
  said are on, so a client can set Caps Lock again when it drifts.
  `RDPToggleKeyFlags` is `Encodable` and `Hashable`. `RDPInputSession` has them
  too, as `serverToggleKeys`, readable from any thread, and
  `RDPRemoteInputView` synchronizes the toggle keys before the next key once
  the server says its Caps Lock changed away from the Mac's, as another client
  of the session can make it.
- The report's `rdpGraphicsFailureUpdateFirstMessageIndex` and
  `rdpGraphicsFailureUpdateMessageCount` say where a failing graphics update's
  summaries start and how many PDUs it held, which RDPPreflight and
  RDPClient's diagnostics show, and `RDPGFXMessageSummary.omittedListEntryCount`
  how many entries its codec lists left out.
- `RDPClipboardFileGroupDescriptorW.downloadPlan(limits:)` plans the download
  of a remote copy's files within `RDPClipboardDownloadLimits` (32 MiB, 1000
  files, 512 KiB ranges, two minutes per request): the files under the names
  they get, whether folders are left out, entries or names that carry them,
  and the declared total, so an app can refuse a copy or name its first file
  before it makes a folder. `RDPClipboardSession.downloadRemoteFiles(_:copyNumber:into:progress:writeFile:)`
  follows the plan: a size request per file, then ranges, asking again for the
  rest of a range the server answers short. It ends with an
  `RDPClipboardDownloadError` once a newer copy replaces the one downloading,
  the connection closes, or the server refuses, stalls or sends short, and
  with `CancellationError` when its task is cancelled, writing nothing more.
  It awaits `progress`, so reports arrive in order and none after it returns,
  also through a hop to the main actor. `writeFile` lets an app set a
  quarantine mark. RDPClient downloads through it.
- `RDPClipboardFileGroupDescriptorW.remoteFileTransferFiles` takes a
  `maximumFileCount`.
- `RDPConnectionReport.credentialsVerifiedBeforeActivation` says whether the
  server checked the credentials before the session started: it selected
  CredSSP, with or without Early User Authorization, or RDSTLS. A client saves
  a password only then, without matching `selectedProtocols` names.
- `RDPInputSession`, `RDPDisplayControlSession` and `RDPClipboardSession` carry
  an `RDPConnectionContext`, the `redirectionDepth` and
  `credentialsVerifiedBeforeActivation` of the connection they belong to, for
  their ready handlers to read rather than the live report, which a Server
  Redirection moves on. RDPClient decides whether to save a password from it.
- `RDPConnectionConfiguration.clipboardFetchesRemoteCopies` sets what
  `RDPClipboardSession.fetchesRemoteCopies` starts as, so a client with
  sharing off fetches nothing of the server's clipboard, without turning it off
  in `onClipboardReady`. RDPClient starts with it off until its clipboard
  bridge attaches.
- `RDPClipboardSession.startFetchingRemoteCopies()` turns fetching on and
  says whether a copy the server announced is being fetched then, decided
  under the same lock. Reading `isAwaitingRemoteCopy` after turning fetching
  on said false when the copy came first, and a client that then published
  replaced the server's copy with its own. RDPClient's bridge attaches
  through it.
- `RDPClipboardSession.serverHoldsLocalCopy` says whether the server's
  clipboard holds the client's last publish, which was not empty, and
  `withdrawLocalCopy()` takes it back with an empty publish only then, so a
  client that stops sharing leaves a copy the server's user made since alone:
  Windows empties its clipboard for an empty publish. RDPClient withdraws
  through it.
- `RDPClipboardSession.beginLocalCopy()` publishes an empty copy at once for
  content still to come, such as files being read, so an older server copy is
  neither fetched nor reported in its place, and `publishLocalFiles(_:forCopy:)`
  offers the files unless a newer copy replaced it: a later publish, or a copy
  the server announced since.
- `RDPClipboardLocalFile.read(contentsOf:maximumTotalByteCount:)` reads files
  to publish, at most 32 MiB by default and checked before each file is read,
  a MiB at a time, so a file that grew since is read no more than a byte past
  the limit, stopping between them once its task is cancelled. Each keeps its own name in no folder: a
  `\`, which `publishLocalFiles` takes for a folder separator, becomes `_`.
  It throws an `RDPClipboardLocalFileReadError`. RDPClient reads and publishes
  copied files through these.
- `run` and `connect` take a `storedClientLicenseProvider`, asked for the
  client license to present only once a server starts licensing, at most once
  per connection, in place of `storedClientLicense`, and an
  `onClientLicenseIssued` handler that gets a new or upgraded license as soon
  as it arrives. The deadline for the connection's next step starts once
  either returns, so a Keychain prompt takes none of it. RDPClient reads and
  saves its Keychain license through them.
- A run whose stored client license the server's licensing fails with, by a
  Licensing Error Message or by ending the connection for a licensing reason,
  before the session activates, connects again once from the start without
  it, so a license the server no longer takes does not fail every connection
  until the application drops it. `RDPConnectionReport.rdpStoredClientLicenseRejected`
  says so; a license the server issues then reaches `onClientLicenseIssued`.
- `RDPConnectionReport.usedLegacyRSAKeyExchange` says whether the TLS
  handshake offered only RSA key exchange, which has no forward secrecy.
- The `RDPKitTesting` library holds `RDPClipboardTestServer`, the server's
  end of a clipboard channel in memory. An app's tests drive their clipboard
  code with it against a real `RDPClipboardSession`, and the handlers run as
  `run` calls them. The server can:
  - copy text, files, or other formats (`copyFormats(_:)`), and empty or
    restart its clipboard;
  - fail format data requests;
  - answer each file request (`fileRequestAnswer`) in full, with a failure,
    cut short, or later (`.hold`, then `answerHeldFileRequests(_:)`);
  - record the client's copies in order (`clientCopies`), and paste the
    client's text or files (`pasteFiles()`).

  With `isStepping` on, the server's messages wait until `step()` hands each
  one to the session. `isSettled` is true once nothing the server set off is
  still under way, and `settle()`'s documentation shows how to wait for
  handlers that hand work on to the main queue.
- `RDPKitTesting`'s `RDPDisplayControlTestServer` hands an app's
  `onDisplayControlReady` code a real `RDPDisplayControlSession`.
  `resetGraphics(monitors:issues:outputRect:)` lays out the server's monitors
  as a ResetGraphics does, setting `serverMonitors` and counting
  `graphicsResetCount`, and returns the `RDPServerLayout` the frames after it
  carry, for the app's `onServerLayout` handler. `endSession()` ends the
  session as a server that replaces its channel does, and `sentLayouts`
  records what the session sent.
- `RDPConnectionReport.presentedFrameCount` counts the frames the
  `onGraphicsFrame` handler showed on the connection, where
  `rdpGraphicsFirstFrame` is the first that came, shown or not, and
  `runPresentedFrameCount` those of the whole run, so a run that showed a
  desktop before a Server Redirection's target failed still says so.
- `RDPKitAppKit`'s `RDPPasteboardClipboard` bridges a Mac pasteboard and a
  session's clipboard, as RDPClient and RDPeek each did with a copy of their
  own: `attach(_:)`, the `receive…` calls for the session's handlers, `poll()`
  once a second, `syncNow()`, `setSharingEnabled(_:)` and
  `startTemporarySharing()`. It publishes the user's copies, puts the server's
  text and quarantined downloads on the pasteboard, drops what a newer copy
  replaced, sends nothing while macOS denies reading the pasteboard, and clears
  the copy it sent when the server's clipboard is emptied, also while sharing
  is off. `onEvent` reports what happened for the app to word, and
  `removeStaleDownloadDirectories(in:changedBefore:keeping:)` clears what
  earlier runs left. RDPClient now uses it.
- `RDPConnectionReport.targetHost` and `targetPort` give `target` apart, and
  `redirectionNamedHost` says whether a Server Redirection named that host,
  rather than only a routing token that leads to the configured host again.
- `RDPKeyboard` is a keyboard as a client announces it, layout, type and
  subtype, and `character(for:shift:capsLock:)` says what Windows types for a
  scancode with it, from tables Windows 11 reported for every layout a Mac
  input source announces, Japanese with a 106/109-key or 101-key keyboard
  among them, so a client sends a character as its scancode only where the
  server types the same one. `Scripts/generate-windows-keyboard-layout-tables.py`
  and `Scripts/capture-windows-keyboard-layouts.ps1` capture them again.
- The `RDPKitAppKit` library, for macOS, holds `RDPRemoteInputView`, which
  sends the Mac's keyboard, mouse and scroll input to an `RDPInputSession`:
  RDPClient's input view with RDPeek's refinements. Modifiers found held are
  pressed from their own side bits, a click on a background window presses
  none, a button goes up only if the server saw it go down, and a release off
  the shown desktop goes at its nearest pixel. `pointMapping` takes an
  `RDPRemotePointMapping` for a view that shows part of the desktop, and
  `claimsCommandShortcuts` gives ⌘ and ⌃ chords to the server ahead of the
  menus. The keyboard handling behind the view is public too:
  `RDPMacKeyboardLayout` maps the Mac's input source to the `RDPKeyboard` to
  announce (`current()`), Japanese keyboards included;
  `RDPMacKeyboardMapping` turns key codes into scancodes or Unicode;
  `RDPMacModifierKey` reads each side of a modifier from an event's flags;
  `RDPMacDeferredModifierKeys` holds back the Windows keys and right Alt; and
  `RDPMacDeadKeys` reads dead keys from the Mac's layout.
  `RDPRemoteDisplayViewport(frame:view:)` maps a view's points onto the
  desktop it shows on whole screen pixels.
- `RDPKitAppKit` also holds the video side of a macOS client, from RDPClient
  with RDPeek's container layer:
  - `RDPRemoteDesktopVideoView` shows decoded frames through an
    `AVSampleBufferDisplayLayer` (`displayLayer`). It flushes on a format
    change and shows the last frame again when the layer fails. `videoLayout`
    places and clips the video, for chosen monitors, and `sourceRect` crops
    each frame.
  - `RDPRemoteDesktopVideoLayout(viewport:)` lays the video out where an
    `RDPRemoteDisplayViewport` draws the desktop, on a whole screen pixel. A
    whole desktop gets a layer the size of the view, so a frame of a new size
    letterboxes in it rather than stretching.
  - `RDPFramePresenter` paces frames to the display for a video view. It
    shows the first frame at once, and holds each later one for the next
    refresh. `present(_:)` says whether a frame was shown, waits or replaced
    one that waited, a skipped presentation. Turning `isPacing` off or
    `flush()` shows the frame waiting, and `clear()` drops it.
  - Underneath it, `RDPFramePresentationClock` paces to the window's display
    link, which runs only while a frame waits (`requestFrame()`), and
    publishes the screen's timing as `RDPFramePacingState`.
    `RDPFramePresentationBuffer` holds the one frame waiting for it.
- `RDPTrustedServerCertificates` keeps the certificates a user trusted, one
  per host and port, by the storage identifiers an app stores. It decides
  trust on first use: `refusal(of:port:acceptsUntrusted:)` refuses a
  certificate nobody trusts as `.untrusted`, and one that replaced a trusted
  certificate as `.changed` even when untrusted ones are accepted.
  `RDPServerCertificateTrustKey(storageIdentifier:)` reads a stored key back.
  RDPClient's store keeps only the storage.
- `RDPConnectionConfiguration.connectAttempts` and `connectRetryDelay` try a
  TCP connect again, a delay apart, when it fails before the server answers:
  unreachable, timed out, or without a category. That gets past the first
  connection into the local network failing while Apple platforms ask to
  allow local network access. A refused connection, one the system does not
  permit, or a name that does not resolve fails at once. The report's
  `connectAttempt`, live too, says which try is under way, and
  `nextConnectAttemptDate`, while the client waits, when the next one starts.
- `RDPDiagnosticText` formats what a diagnostics view such as Stats for Nerds
  shows: metric units, Core Video pixel formats, hex codes, a one-line
  performance summary, and summaries of a report's channels, capability sets,
  messages, Client Info, RDPGFX updates, graphics failure, first frame,
  redirection and termination. RDPKitAppKit adds `refreshRange(_:)` for an
  `RDPFramePacingState`. RDPClient's window uses it; the layout stays the
  app's.
- `RDPConnectionIdentity.legacyCredentialMoves(keptBy:)` plans moving the
  passwords saved under an account's earlier names to its current one, as
  `RDPCredentialAccountMove` steps in order: for a lookup that finds nothing
  under the current name, and for a profile deleted while others keep the
  account. Each step renames, and says whether to delete the earlier one when
  the current name has a password already. The app keeps only the store's
  I/O, as RDPClient now does.
- `RDPConnectionConfiguration.keyboard` sets or reads the layout, type and
  subtype together as an `RDPKeyboard`, as `RDPMacKeyboardLayout.current()`
  gives it.
- `RDPDesktopSize(_:)` takes an `RDPDisplayRequest`, its width even as
  Display Control rounds it, so the layout sent once connected resizes
  nothing.
- `RDPScrollWheelAccumulator.events(deltaX:deltaY:isPrecise:at:)` takes a
  scroll as AppKit reports it, a line a notch of 120 rotation units and a
  precise scroll's point 10, with the horizontal axis negated for RDP.
- `RDPLiveSession` runs a connection for an app whose interface lives on the
  main thread, as RDPClient did on its own. `start(events:run:)` calls `run`
  on a named thread with the handlers to pass to `RDPSessionClient.run`:
  - `onGraphicsFrame` decodes each frame on an `RDPFrameDecodeQueue` and
    reports one that failed as not presented;
  - `onWireReceive` coalesces wire samples, the last one sent before the end.
  `events` gets decoded frames, failures and samples on the main queue, and
  with `onServerLayout` the server's layout (`RDPServerLayout`: monitors,
  their issues, the ResetGraphics count and the output) ahead of each
  connection's first frame, a Server Redirection's included, and of each
  frame whose layout changed, also one that fails to decode.
  `deliver(_:)` puts the app's own main-thread work in the same order, and
  `recipient(_:)` hands it to an object held weakly, such as the view
  controller, so the session's thread does not keep a closed one alive.
  `cancel()` drops whatever has not run yet, so a session the app left
  changes nothing. `onEnd` gets the report on the session thread unless the
  session was cancelled. `waitUntilEnded(timeout:)` returns once the session's
  thread is done and the connection is closed, so an app that quits right
  after `cancel()` waits until the server has been told rather than for a
  fixed time. RDPClient does that when it quits, tries a connect three times,
  and shows the server's layout and the connect attempt in Stats for Nerds.

### Security

- Data a server, or anyone on the path, sends with the X.224 Connection
  Confirm ends the connection before the TLS handshake. It was read later as
  if TLS had protected it, so it could inject PDUs such as a Server
  Redirection.
- Wire transcripts and report hex zero a Server Redirection's cleartext
  password also where another field, such as the user name, has its bytes or
  overlaps it.
- A RemoteFX message writes at most sixteen times its surface's pixels, as
  other graphics updates do, gives at most 65,535 region rects, and leaves one
  decoded tile per position; RemoteFX Progressive keeps state for at most
  65,536 tile positions over all surfaces. One message can no longer hold
  gigabytes of tiles or keep the session drawing for seconds.
- A Monitor Layout PDU of more than 16 monitors is refused.
- The copies a graphics frame holds count toward its memory bound, which
  never passes the 1 GiB all RDPGFX surfaces may hold; copies out of a staging
  surface expand in time linear in their points and carry at most 4,096 access
  units a frame; and a failing update's report keeps at most 64 PDU summaries
  of at most 1,024 list entries each.
- At most 32 MiB of the server's shared-drive requests wait for the drive I/O
  queue, and directory listings hold at most 64 MiB of names together, so a
  server can no longer make the client hold its requests or listings until
  memory runs out.
- The connection stops reading from a server that stops reading once 80 MiB
  of the client's bytes wait for its socket, and reads again under 64 MiB, so
  the replies cliprdr, rdpdr and rdpsnd send without waiting, such as Format
  List Responses, failed device requests and Wave Confirms, can no longer
  pile up without bound; TCP holds the server back instead.
- RDPClient deletes the saved password of an account a profile is saved off,
  as Delete Profile does, unless another profile uses that account.
- Remote files are numbered in linear time, so a server's file list of long
  names that differ only near the end can no longer keep the transfer's
  planning busy for minutes.

### Compatibility and fixes

- RDPClient sends a keyframe request it made before Display Control was ready
  once it is.
- RDPClient saves a password only when the server checked it, with Network
  Level Authentication or RDSTLS.
- RDPClient announces a Windows layout that types the Mac layout's letters on
  the same keys, so Control shortcuts reach the letters they show, for Turkish
  F, German DIN 2137, ABC QWERTZ and ABC AZERTY, Latvian, Lithuanian and LST
  1582, Hungarian QWERTY, Romanian, Finnish Extended, Slovenian, Albanian and
  Kabyle AZERTY.
- RDPClient synchronizes Caps Lock again when a key or click shows a toggle it
  missed, releases the keys held when a menu opens, moves the remote pointer to
  a scroll's position before the wheel, sends no Windows or Alt tap while
  another modifier or a button is down, types the JIS keypad comma as a comma,
  and composes the key after a dead key that follows one sent as an Alt chord.
- `RDPAudioPlayer` keeps playing after the output device or its sample rate
  changes. The engine stopped, and starting it again played nothing: the
  queue never drained and later audio was dropped.
- `RDPRemoteDisplayViewport` maps an AppKit view's top pixel row: with
  bottom-left coordinates the top edge is inside and the bottom edge outside,
  as `NSMouseInRect` counts them, so hovering or clicking the remote desktop's
  first row works without a letterbox.
- NTLM upper-cases the user name with Windows' own table, one UTF-16 code
  unit at a time, as read from Windows 11. A user name with µ, ı, ſ, ς,
  Georgian letters, a character outside the BMP, or another of the 252 code
  units where Unicode's case mapping differs, failed to sign in.
- A dynamic virtual channel Data First shorter than a full PDU is accepted:
  xrdp sends RDPGFX messages in 1,500-byte blocks, and its first message
  longer than that ended the session.
- After VideoToolbox invalidates a decompression session, as iOS does in the
  background, a surface's video waits for a keyframe instead of decoding
  P-frames without their references. Servers that cannot be asked for one,
  FreeRDP shadow and KRdp, show the last picture until their next periodic
  keyframe.
- An HEVC stream waiting for a keyframe starts again at a BLA picture too.
- `RDPGraphicsPathDescription` names RDPGFX 10.0 to 10.6 with each version's
  flags.
- RDPGFX video is no longer painted over with black or stale pixels when a
  frame changes more than 1,024 separate areas around it, unless the video
  itself lies in more than 1,024 pieces, or leaving it out would split the
  changed area into more than 512.
- NSCodec Set Surface Bits are drawn the right way up.
- A second RDPGFX channel starts ClearCodec afresh, so its streams are no
  longer refused as out of sequence.
- Classic RemoteFX tiles that a later tile replaces, or that fall outside the
  area drawn, are no longer decoded, so bad data in them no longer fails the
  update.
- A Set Error Info of ERRINFO_NONE clears an earlier error, so a Deactivate
  All after it reactivates the session instead of ending it.
- A `timeoutSeconds` of 0 or less set after the configuration's initializer
  counts as 1 second, as the initializer counts it.
- After a Server Redirection with no credentials configured, the reconnect
  sends the redirection's user name and domain with its password cookie, and
  the report names them.
- Input sent as the server deactivates the session, and a layout sent as a
  display control session ends, are dropped instead of written after the
  reactivation.
- Wire transcripts redact only the I/O channel, so a large clipboard, drive
  or audio message is no longer partly zeroed, and their docs say which client
  PDUs they record.
- `shouldCancel` is polled while a clipboard reply or a shared-drive request
  waits for room, so `run` returns cancelled instead of staying blocked.
- Shared drives are announced from the drive I/O queue, so a folder on a
  network volume that stopped answering no longer holds up the connection.
- A shared-drive file opened with MAXIMUM_ALLOWED falls back to read access
  also when it is locked in the Finder, on a read-only volume or sandbox
  grant, or a running program.
- A server copy announced while a Format List of the client's is unanswered,
  an empty one included, is acknowledged but neither fetched nor reported:
  the server takes the client's copy after it, so an app no longer replaces
  what the user just copied, or files RDPClient is still reading, with the
  older one, also after the server's clipboard restarts. Only the empty list
  sent on joining cliprdr before the app's first copy, or once a server copy
  has replaced it, does not count, so KRdp's copy at connect, sent ahead of
  its answer to that list, is still fetched.
- The server's next copy stops the app's earlier copy being offered also when
  a client Format List was unanswered as the server clipboard restarted.
- A Format Data Response whose chunk the channel layer refuses, or whose
  cliprdr header does not parse, still answers its request, so later remote
  copies are still fetched.
- Without `onClipboardFileGroupDescriptor`, a remote copy of files is fetched
  for the other formats offered with it, or reported unavailable, instead of
  fetching a file list the app would drop.
- RDPClient's Port field takes every TCP port; one above 8192 was dropped.
- RDPClient connects a profile from the list with the Remember choice the
  form shows beside its password, so the password Keychain has for it is no
  longer deleted once signed in. Deleting one of two profiles for an account
  no longer leaves the other signing in with the deleted one's legacy
  password.
- RDPClient reads a stored client license off the main thread, so a Keychain
  prompt no longer freezes every window.
- RDPFirstFrameCapture goes on after a frame fails to decode, until
  `--settle-seconds` ends or, with no frame decoded, `--timeout-seconds`.
- RDPFrameBenchmark's `--frames` takes 1 to 60, which leaves it spare frames.

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
