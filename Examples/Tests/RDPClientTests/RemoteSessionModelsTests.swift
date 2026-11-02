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
    let logoff = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_000C), showedDesktop: true)
    #expect(logoff.kind == .ended)
    #expect(logoff.statusText == "Disconnected")
    #expect(logoff.message == "The remote session was signed out or disconnected from within.")
    #expect(logoff.diagnosticValue
        == "Disconnected: The remote session was signed out or disconnected from within.\n"
        + "server ended the session with ERRINFO_LOGOFF_BY_USER")

    let idle = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0003), showedDesktop: true)
    #expect(idle.message == "The session reached the server's idle or session time limit.")
    let replaced = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0005), showedDesktop: true)
    #expect(replaced.message == "Another connection took over the session.")
    let admin = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0001), showedDesktop: true)
    #expect(admin.message == "An administrator ended the session, or the server is shutting down or restarting.")

    let closed = RDPSessionEndReason(report: sessionReport(firstFrame: bitmapFrame, nextStage: "rdp-graphics-frame-decode"), showedDesktop: true)
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
    ), showedDesktop: true)

    #expect(reason.kind == .ended)
    #expect(reason.message == "The remote session was signed out or disconnected from within.")
    #expect(reason.detail?.contains("RDPGFX") == false)
}

@Test func aSessionThatEndedBeforeItsDesktopAppearedSaysSo() {
    let beforeChannel = RDPSessionEndReason(report: sessionReport(graphicsChannelName: nil, disconnectReason: 3), showedDesktop: false)
    #expect(beforeChannel.kind == .ended)
    #expect(beforeChannel.message == "The server ended the session. This happened before the desktop appeared.")
    #expect(beforeChannel.detail == "server ended the session with rn-user-requested before opening the RDPGFX dynamic channel")

    let beforeFrame = RDPSessionEndReason(report: sessionReport(), showedDesktop: false)
    #expect(beforeFrame.message == "The session ended before the desktop appeared.")
    #expect(beforeFrame.detail == "session ended before producing a graphics frame")

    // Frames arrived, but none decoded, when another connection took over.
    let neverShown = RDPSessionEndReason(
        report: sessionReport(firstFrame: bitmapFrame, errorInfo: 0x0000_0005),
        showedDesktop: false
    )
    #expect(neverShown.kind == .ended)
    #expect(neverShown.message == "Another connection took over the session. This happened before the desktop appeared.")
    #expect(neverShown.detail == "server ended the session with ERRINFO_DISCONNECTED_BY_OTHERCONNECTION before showing a graphics frame")
}

@Test func failuresAreExplainedAndKeepTheirDetailForDiagnostics() {
    let error = "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)"
    let wrongPassword = RDPSessionEndReason(report: sessionReport(error: error, failure: .credSSP(status: .logonFailure)), showedDesktop: false)
    #expect(wrongPassword.kind == .failed)
    #expect(wrongPassword.title == "Connection Failed")
    #expect(wrongPassword.message == "The user name or password is incorrect.")
    #expect(wrongPassword.offersCredentials)
    #expect(wrongPassword.diagnosticValue == "Failed: The user name or password is incorrect.\n\(error)")

    func reason(_ failure: RDPConnectionFailure) -> RDPSessionEndReason {
        RDPSessionEndReason(report: sessionReport(error: "raw", failure: failure), showedDesktop: false)
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
    ), showedDesktop: false)
    #expect(redirectedRefused.message == "The server passed the session on to 127.0.0.1:3389, which this Mac could not reach.")
    #expect(reason(.licensing(errorCode: 0x0000_0007)).message.hasPrefix("The server could not license this connection."))
    // gnome's one-time credentials are its own, so typing others would not help.
    let redirectedSignIn = reason(.rdSTLS(resultCode: .logonFailure))
    #expect(redirectedSignIn.message == "The server refused the sign-in it passed the session on with.")
    #expect(redirectedSignIn.offersCredentials == false)
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

@Test func aSessionThatShowedNoFrameInTimeSaysWhetherAnyCame() {
    let none = RDPSessionEndReason(
        report: sessionReport(error: "timed out", failure: .noFramePresented(framesReceived: 0, lastNotPresentedReason: nil)),
        showedDesktop: false
    )
    #expect(none.message == "The server sent no remote desktop in time.")
    let undecoded = RDPSessionEndReason(
        report: sessionReport(
            error: "no frame shown",
            failure: .noFramePresented(framesReceived: 3, lastNotPresentedReason: "awaiting a keyframe")
        ),
        showedDesktop: false
    )
    #expect(undecoded.message == "RDPClient could not show the remote desktop in time.")
    #expect(undecoded.detail == "no frame shown")
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

/// Without Network Level Authentication or RDSTLS the server did not check the password: it is
/// not saved, while removing a saved one still happens.
@Test func onlyAPasswordTheServerCheckedIsSaved() throws {
    let key = try #require(KeychainCredentialKey(identity: RDPConnectionIdentity(
        host: "a.example",
        port: 3389,
        username: "user",
        domain: ""
    )))
    func persistence(
        _ request: CredentialPersistenceRequest?,
        _ verified: Bool
    ) -> (saves: Bool, deletes: Bool, dropped: Bool) {
        let result = rdpCredentialPersistenceOnceReady(request, credentialsVerified: verified)
        let saves = if case .save = result.request { true } else { false }
        let deletes = if case .delete = result.request { true } else { false }
        return (saves, deletes, result.droppedUncheckedSave)
    }
    let save = CredentialPersistenceRequest.save(key: key, password: "secret")

    #expect(persistence(save, true) == (true, false, false))
    #expect(persistence(save, false) == (false, false, true))
    #expect(persistence(.delete(key: key), false) == (false, true, false))
    #expect(persistence(nil, false) == (false, false, false))
}

/// A port above the desktop size's limit of 8192, such as a forwarded 33890, stays in the
/// session window's Port field once editing ends, rather than leaving it empty.
@MainActor
@Test func thePortFieldTakesEveryTCPPort() throws {
    _ = NSApplication.shared
    let launchStore = RDPConnectionLaunchStore()
    let controller = RDPRemoteSessionViewController(
        sessionID: UUID(),
        draft: RDPConnectionDraft(
            host: "desktop.example",
            port: 3389,
            username: "",
            domain: "",
            password: "",
            desktopWidth: 1920,
            desktopHeight: 1080,
            hideCertificateWarnings: false,
            timeoutSeconds: 10,
            graphicsCapabilityProfile: .automatic,
            clipboardSharingEnabled: false,
            audioPlaybackEnabled: false,
            rememberPassword: false,
            passwordAnswer: nil
        ),
        launchStore: launchStore
    )
    // As the session window does on closing, before the controller goes.
    defer { controller.closeSession() }
    // Only the controls: viewDidLoad would read Keychain and connect.
    controller.loadView()
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    let field = controller.portField
    window.contentView?.addSubview(field)

    for port in ["33890", "65535", "1"] {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(port, replacementRange: editor.selectedRange())
        #expect(window.makeFirstResponder(nil))
        #expect(field.stringValue == port)
    }
    let formatter = try #require(field.formatter as? NumberFormatter)
    #expect(formatter.number(from: "0") == nil)
    #expect(formatter.number(from: "65536") == nil)
}
