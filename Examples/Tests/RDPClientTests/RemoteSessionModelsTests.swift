import AppKit
import Foundation
@testable import RDPClient
import RDPKit
import Testing

/// A report of a session that reached graphics, with what the test sets.
private func sessionReport(
    graphicsChannelName: String? = "Microsoft::Windows::RDS::Graphics",
    firstFrame: RDPGraphicsFrameSnapshot? = nil,
    errorInfo: UInt32? = nil,
    disconnectReason: UInt8? = nil,
    nextStage: String? = "rdp-session-ended",
    error: String? = nil,
    failure: RDPConnectionFailure? = nil,
    redirectionDepth: Int = 0
) -> RDPConnectionReport {
    RDPConnectionReport(
        status: error == nil ? "success" : "failure",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        redirectionDepth: redirectionDepth,
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        rdpGraphicsChannelName: graphicsChannelName,
        rdpGraphicsFirstFrame: firstFrame,
        rdpRemoteTerminationErrorInfo: errorInfo,
        rdpRemoteTerminationDisconnectReason: disconnectReason,
        warnings: [],
        nextStage: error == nil ? nextStage : nil,
        error: error,
        failure: failure
    )
}

private let bitmapFrame = RDPGraphicsFrameSnapshot(
    frameID: nil,
    surfaceID: 0,
    codecID: 0,
    codecName: "bitmap",
    pixelFormat: 0,
    destinationRect: RDPFrameRect(left: 0, top: 0, right: 640, bottom: 480),
    regionRects: [],
    encodedVideoData: Data()
)

@Test func aSessionThatShowedFramesSaysWhyItEnded() {
    let logoff = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_000C))
    #expect(logoff.kind == .ended)
    #expect(logoff.statusText == "Disconnected")
    #expect(logoff.message == "The remote session was signed out or disconnected from within.")
    #expect(logoff.diagnosticValue
        == "Disconnected: The remote session was signed out or disconnected from within.\n"
        + "server ended the session with ERRINFO_LOGOFF_BY_USER")

    let idle = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0003))
    #expect(idle.message == "The session reached the server's idle or session time limit.")
    let replaced = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0005))
    #expect(replaced.message == "Another connection took over the session.")
    let admin = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0001))
    #expect(admin.message == "An administrator ended the session, or the server is shutting down or restarting.")

    let closed = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, nextStage: "rdp-graphics-frame-decode"))
    #expect(closed.kind == .ended)
    #expect(closed.message == "The server closed the connection.")
    #expect(closed.diagnosticValue == "Disconnected: The server closed the connection.")
}

/// Legacy bitmap updates show the desktop without RDPGFX: such a session ran.
@Test func aSessionWithoutRDPGFXThatShowedFramesEndsNormally() {
    let reason = RDPSessionEndReason(report: sessionReport(
        graphicsChannelName: nil,
        firstFrame: bitmapFrame,
        errorInfo: 0x0000_000C
    ))

    #expect(reason.kind == .ended)
    #expect(reason.message == "The remote session was signed out or disconnected from within.")
    #expect(reason.detail?.contains("RDPGFX") == false)
}

@Test func aSessionThatEndedBeforeItsDesktopAppearedSaysSo() {
    let beforeChannel = RDPSessionEndReason(report: sessionReport(graphicsChannelName: nil, disconnectReason: 3))
    #expect(beforeChannel.kind == .ended)
    #expect(beforeChannel.message == "The server ended the session. This happened before the desktop appeared.")
    #expect(beforeChannel.detail == "server ended the session with rn-user-requested before opening the RDPGFX dynamic channel")

    let beforeFrame = RDPSessionEndReason(report: sessionReport())
    #expect(beforeFrame.message == "The session ended before the desktop appeared.")
    #expect(beforeFrame.detail == "session ended before producing a graphics frame")
}

@Test func failuresAreExplainedAndKeepTheirDetailForDiagnostics() {
    let error = "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)"
    let wrongPassword = RDPSessionEndReason(report: sessionReport(error: error, failure: .credSSP(status: .logonFailure)))
    #expect(wrongPassword.kind == .failed)
    #expect(wrongPassword.title == "Connection Failed")
    #expect(wrongPassword.message == "The user name or password is incorrect.")
    #expect(wrongPassword.offersCredentials)
    #expect(wrongPassword.diagnosticValue == "Failed: The user name or password is incorrect.\n\(error)")

    func reason(_ failure: RDPConnectionFailure) -> RDPSessionEndReason {
        RDPSessionEndReason(report: sessionReport(error: "raw", failure: failure))
    }
    #expect(reason(.credSSP(status: .accountLockedOut)).offersCredentials == false)
    #expect(reason(.credSSP(status: .passwordMustChange)).message.hasPrefix("The password must be changed"))
    #expect(reason(.credSSP(status: .logonTypeNotGranted)).message.hasPrefix("The account may not sign in remotely."))
    #expect(reason(.credentialsRequired).offersCredentials)
    #expect(reason(.negotiation(code: .hybridRequiredByServer)).offersCredentials)
    #expect(reason(.negotiation(code: .sslWithUserAuthRequiredByServer)).message
        == "The server requires a client certificate, which RDPClient does not support.")
    #expect(reason(.connect(error: RDPSocketError(errno: EHOSTUNREACH))).message.contains("Local Network"))
    #expect(reason(.connect(error: RDPSocketError(errno: ECONNREFUSED))).message.hasPrefix("The server refused the connection."))
    #expect(reason(.addressResolution).message.hasPrefix("The server's name could not be found."))
    let redirectedRefused = RDPSessionEndReason(report: sessionReport(
        error: "raw",
        failure: .connect(error: RDPSocketError(errno: ECONNREFUSED)),
        redirectionDepth: 1
    ))
    #expect(redirectedRefused.message == "The server passed the session on to 127.0.0.1:3389, which this Mac could not reach.")
    #expect(reason(.licensing(errorCode: 0x0000_0007)).message.hasPrefix("The server could not license this connection."))
    let freshCredentials = reason(.serverTermination(termination: RDPRemoteTermination(errorInfo: 0x0000_000A)))
    #expect(freshCredentials.message == "The server requires the credentials to be entered again.")
    #expect(freshCredentials.offersCredentials)
    #expect(reason(.serverTermination(termination: RDPRemoteTermination(errorInfo: 0x0000_0007))).message
        == "The server denied the connection, or the account may not connect.")
    #expect(reason(.cancelled).kind == .cancelled)
    // A failure on this side does not blame the server.
    #expect(reason(.protocolViolation).message == "The server sent something RDPClient cannot handle.")
    let invalidConfiguration = reason(.invalidConfiguration)
    #expect(invalidConfiguration.message.hasPrefix("RDPClient cannot send these settings to the server."))
    #expect(invalidConfiguration.offersCredentials)
    #expect(reason(.clientFailure).message == "RDPClient failed on this Mac; the server was not at fault.")
    #expect(reason(.clientFailure).offersCredentials == false)
}

@Test func legacyConnectionProfileDecodesWithDefaultOptions() throws {
    let json = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","host":"server","port":3389,"username":"user",
    "domain":"","desktopWidth":1920,"desktopHeight":1080,"hideCertificateWarnings":false,
    "timeoutSeconds":10,"rememberPassword":true,"updatedAt":0}
    """
    let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))

    #expect(profile.graphicsCapabilityProfile == .automatic)
    #expect(profile.clipboardSharingEnabled)
    #expect(profile.audioPlaybackEnabled == false)
    #expect(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile)) == profile)
}

@Test func framePacingStateNormalizesDisplayLinkTiming() {
    let state = RDPFramePacingState(
        screenName: "Studio Display",
        backingScaleFactor: 2,
        maximumFramesPerSecond: nil,
        minimumRefreshInterval: 1.0 / 120.0,
        maximumRefreshInterval: 1.0 / 48.0,
        displayUpdateGranularity: 0,
        displayLinkDuration: 0.0167,
        hasDisplayLink: true,
        isDisplayLinkPaused: false
    )

    #expect(state.displayLinkDuration == 1.0 / 60.0)
    #expect(state.displayLinkFramesPerSecond == 60)
    #expect(state.maximumRefreshRate == 120)
    #expect(state.clockState == "window display link")
}

@Test func framePacingStateMarksUpdatedDisplayLinkActive() {
    let state = RDPFramePacingState().updatingDisplayLinkDuration(1.0 / 120.0)

    #expect(state.hasDisplayLink)
    #expect(state.isDisplayLinkPaused == false)
    #expect(state.displayLinkFramesPerSecond == 120)
    #expect(state.clockState == "window display link")
}

/// Until the display link fires on a screen, its duration is 0 or the previous screen's, so the
/// clock shows the screen's maximum refresh rate instead.
@Test func framePacingStateShowsTheScreensMaximumUntilTheDisplayLinkFires() {
    let unfired = RDPFramePacingState(maximumFramesPerSecond: 120, hasDisplayLink: true)
    #expect(unfired.displayLinkFramesPerSecond == 120)
    #expect(RDPFramePacingState(minimumRefreshInterval: 1.0 / 60.0, hasDisplayLink: true).displayLinkFramesPerSecond == 60)
    #expect(RDPFramePacingState(maximumFramesPerSecond: 120).displayLinkFramesPerSecond == nil)

    // A 60 Hz link moved to a 120 Hz screen: its old duration is dropped until it fires there.
    let movedScreen = RDPFramePacingState(maximumFramesPerSecond: 120, displayLinkDuration: 1.0 / 60.0, hasDisplayLink: true)
        .updatingClock(displayLinkDuration: nil, hasDisplayLink: true, isPaused: true)
    #expect(movedScreen.displayLinkDuration == nil)
    #expect(movedScreen.displayLinkFramesPerSecond == 120)
    #expect(movedScreen.updatingDisplayLinkDuration(1.0 / 96.0).displayLinkFramesPerSecond == 96)
}

@Test func keyframeRequestsArePacedAndStopUntilVideoDecodesAgain() {
    var throttle = RDPKeyframeRequestThrottle()
    let start = Date()
    func requests(atIntervals intervals: [Double]) -> [Bool] {
        intervals.map { throttle.shouldRequest(at: start.addingTimeInterval($0 * RDPKeyframeRequestThrottle.minimumInterval)) }
    }

    #expect(requests(atIntervals: [0, 0.5, 1, 2, 3]) == [true, false, true, true, false])

    throttle.recordDecodedVideo()

    #expect(requests(atIntervals: [4]) == [true])
}

@Test func rsaKeyExchangeStaysWithTheTargetWhoseCertificateRefusedECDHE() throws {
    let serverA = try RDPConnectionTarget(host: "a.example", port: 3389)
    let serverB = try RDPConnectionTarget(host: "b.example", port: 3389)
    let serverAOtherPort = try RDPConnectionTarget(host: "a.example", port: 3390)
    var fallback = RDPLegacyKeyExchangeFallback()

    #expect(fallback.connect(to: serverA) == false)
    #expect(fallback.shouldRetry(serverA, after: .tls, redirectionDepth: 0, usedRSAKeyExchange: false) == false)
    #expect(fallback.shouldRetry(serverA, after: nil, redirectionDepth: 0, usedRSAKeyExchange: false) == false)
    #expect(fallback.connect(to: serverA) == false)

    #expect(fallback.shouldRetry(serverA, after: .tlsKeyUsageIncorrect, redirectionDepth: 0, usedRSAKeyExchange: false) == true)
    #expect(fallback.connect(to: serverA) == true)
    // Once only: a connection that already used RSA key exchange is not retried.
    #expect(fallback.shouldRetry(serverA, after: .tlsKeyUsageIncorrect, redirectionDepth: 0, usedRSAKeyExchange: true) == false)
    // Reconnecting to the same target keeps it.
    #expect(fallback.connect(to: serverA) == true)
    #expect(fallback.target == serverA)

    // Another target gets ECDHE, and the fallback is gone for a later connection to the first.
    #expect(fallback.connect(to: serverB) == false)
    #expect(fallback.target == nil)
    #expect(fallback.connect(to: serverA) == false)

    // The port is part of the target.
    #expect(fallback.shouldRetry(serverA, after: .tlsKeyUsageIncorrect, redirectionDepth: 0, usedRSAKeyExchange: false) == true)
    #expect(fallback.connect(to: serverAOtherPort) == false)

    // A redirection target that refuses ECDHE is not the server typed in, which already took the
    // sign-in, so that server is not retried with RSA key exchange.
    #expect(fallback.connect(to: serverB) == false)
    #expect(fallback.shouldRetry(serverB, after: .tlsKeyUsageIncorrect, redirectionDepth: 1, usedRSAKeyExchange: false) == false)
    #expect(fallback.connect(to: serverB) == false)
}

@Test func aViewResizedAndBackBeforeTheDelaySendsNothing() {
    let sizeA = RDPDisplayRequest(pointSize: CGSize(width: 1000, height: 600), backingScaleFactor: 2)
    let sizeB = RDPDisplayRequest(pointSize: CGSize(width: 800, height: 500), backingScaleFactor: 2)
    var debounce = RDPDisplayResizeDebounce()
    debounce.recordSent(sizeA)
    var results: [Bool] = []

    results.append(debounce.viewChanged(to: sizeB))
    results.append(debounce.viewChanged(to: sizeA))
    // B's delay still runs out, but the view has left B.
    results.append(debounce.settle(sizeB))
    #expect(results == [true, false, false])
    #expect(debounce.lastSent == sizeA)

    results = [debounce.viewChanged(to: sizeB), debounce.settle(sizeB)]
    debounce.recordSent(sizeB)
    results.append(debounce.viewChanged(to: sizeB))
    #expect(results == [true, true, false])

    // A size sent from the fields while the view's size waits is not sent again.
    results = [debounce.viewChanged(to: sizeA)]
    debounce.recordSent(sizeA)
    results.append(debounce.settle(sizeA))
    #expect(results == [true, false])

    // A new session, or a redirection's target, has been sent nothing.
    debounce.cancel(forgettingLastSent: true)
    results = [debounce.viewChanged(to: sizeA)]
    #expect(results == [true])
}

@Test func aRetinaViewConnectsAtItsPointSize() throws {
    let pointSize = CGSize(width: 1200, height: 750)
    let pixelSize = RDPViewerPixelSize(pointSize: pointSize, backingScaleFactor: 2)
    let pixelFields = try RDPDesktopSize(widthText: pixelSize.desktopWidthText, heightText: pixelSize.desktopHeightText)

    let following = RDPConnectDesktop(
        fieldSize: pixelFields,
        followsViewSize: true,
        viewerPointSize: pointSize,
        viewerPixelSize: pixelSize
    )
    #expect(following.size == (try RDPDesktopSize(width: 1200, height: 750)))
    #expect(following.label == "1200x750")
    #expect(following.displayRequest == RDPDisplayRequest(
        width: 1200,
        height: 750,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 100, deviceScaleFactor: 100)
    ))

    // A size typed into the fields, or any size while the view is not followed, goes as it is.
    let typed = try RDPDesktopSize(width: 1920, height: 1080)
    for (fields, follows) in [(typed, true), (pixelFields, false)] {
        let desktop = RDPConnectDesktop(
            fieldSize: fields,
            followsViewSize: follows,
            viewerPointSize: pointSize,
            viewerPixelSize: pixelSize
        )
        #expect(desktop.size == fields)
    }
    // Before the view has a size, the fields are all there is.
    let early = RDPConnectDesktop(fieldSize: typed, followsViewSize: true, viewerPointSize: .zero, viewerPixelSize: nil)
    #expect(early.size == typed)
}

/// A Password field in a window, showing the form's password as the session window does.
@MainActor
private func passwordField(showing password: String) -> (window: NSWindow, field: NSSecureTextField, sync: RDPPasswordFieldSync) {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
    window.contentView?.addSubview(field)
    var sync = RDPPasswordFieldSync()
    sync.show(password, in: field)
    return (window, field, sync)
}

/// Keychain's answer fills in the saved password while the user edits the Password field, which
/// AppKit leaves as it is: Connect still gets the saved password, not the field's older text,
/// which a server without NLA would take and Remember would then save over the saved one.
@MainActor
@Test func aPasswordFieldBeingEditedGivesThePasswordFilledInMeanwhile() {
    var (window, field, sync) = passwordField(showing: "other")
    #expect(window.makeFirstResponder(field))
    var password = "secret"
    sync.show(password, in: field)
    #expect(field.stringValue == "other")

    sync.read(field, into: &password)
    #expect(password == "secret")

    // Once editing ends, the field shows it.
    #expect(window.makeFirstResponder(nil))
    sync.show(password, in: field)
    #expect(field.stringValue == "secret")
    sync.read(field, into: &password)
    #expect(password == "secret")
}

/// The user can still change or clear the password in a field that shows older text.
@MainActor
@Test func whatTheUserTypesIntoAPasswordFieldShowingOlderTextIsThePassword() throws {
    var (window, field, sync) = passwordField(showing: "")
    #expect(window.makeFirstResponder(field))
    var password = "secret"
    sync.show(password, in: field)
    let editor = try #require(field.currentEditor() as? NSTextView)

    editor.insertText("newer", replacementRange: editor.selectedRange())
    sync.userEdited()
    sync.read(field, into: &password)
    #expect(password == "newer")

    editor.selectAll(nil)
    editor.deleteBackward(nil)
    sync.userEdited()
    sync.read(field, into: &password)
    #expect(password.isEmpty)
}
