import Foundation

/// Connects to an RDP server and runs a session.
///
/// `run` and `connect` block the calling thread for the whole session; call
/// them from a dedicated thread, never from an event loop or a Swift
/// concurrency executor. Every handler runs synchronously on that thread,
/// except `onWireReceive`, which runs on the NIO event loop and must not block.
/// A slow handler delays every channel. Any thread can read the report so far
/// from `liveReport` while the call runs.
///
/// `onCertificate` runs after the TLS handshake and before any credential is
/// sent: cancelling `cancellation` (or returning true from `shouldCancel`)
/// from it rejects the server.
public struct RDPSessionClient: Sendable {
    public init() {}

    public func dryRun(configuration: RDPConnectionConfiguration) -> RDPConnectionReport {
        let request = configuration.connectionRequest
        return RDPConnectionReport(
            status: "dry-run",
            stage: "x224-rdp-negotiation-request",
            target: configuration.target,
            targetHost: configuration.host,
            targetPort: configuration.port,
            username: configuration.credentials?.username,
            domain: configuration.credentials?.domain,
            passwordConfigured: configuration.credentials != nil,
            requestedProtocols: request.negotiationRequest.requestedProtocols.names,
            requestHex: request.encodedTPKT().rdpHexString,
            rdpGraphicsCapabilityProfile: configuration.graphicsCapabilityProfile,
            warnings: [],
            nextStage: "send negotiation request to server"
        )
    }

    /// Like `connect`, but reports a failure to connect in the returned report.
    public func run(
        configuration: RDPConnectionConfiguration,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onRemotePointer: RDPRemotePointerHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardContent: RDPClipboardContentHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onClipboardRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler? = nil,
        onClipboardLocalFilePasteProgress: RDPClipboardLocalFilePasteProgressHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        audioPlaybackDelay: RDPAudioPlaybackDelayHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        storedClientLicenseProvider: RDPStoredClientLicenseProvider? = nil,
        onClientLicenseIssued: RDPClientLicenseIssuedHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        wireTranscript: RDPWireTranscript? = nil,
        liveReport: RDPLiveConnectionReport? = nil,
        cancellation: RDPConnectionCancellation? = nil,
        shouldCancel: RDPCancellationHandler? = nil
    ) -> RDPConnectionReport {
        let callbacks = RDPSessionCallbacks(
            onGraphicsFrame: onGraphicsFrame,
            onRemotePointer: onRemotePointer,
            onInputReady: onInputReady,
            onDisplayControlReady: onDisplayControlReady,
            onClipboardReady: onClipboardReady,
            onClipboardText: onClipboardText,
            onClipboardContent: onClipboardContent,
            onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onClipboardFileContents: onClipboardFileContents,
            onClipboardRemoteCopyUnavailable: onClipboardRemoteCopyUnavailable,
            onClipboardLocalFilePasteProgress: onClipboardLocalFilePasteProgress,
            onAudioSample: onAudioSample,
            audioPlaybackDelay: audioPlaybackDelay,
            onCertificate: onCertificate,
            storedClientLicenseProvider: storedClientLicenseProvider,
            onClientLicenseIssued: onClientLicenseIssued,
            onWireReceive: onWireReceive,
            wireTranscript: wireTranscript,
            liveReport: liveReport,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
        return session(configuration: configuration, callbacks: callbacks) { connection, error in
            connection.failedReport(error)
        }
    }

    /// Runs a session and returns its report. Throws `RDPConnectionError` when
    /// no RDP connection could be set up: the address could not be resolved,
    /// the TCP connection failed, the X.224 exchange could not be completed, or
    /// the run was cancelled before that. A negotiation the server refuses
    /// (RDP_NEG_FAILURE) or settles on a protocol RDPKit does not support
    /// returns a failure report. The error carries the report `run` returns
    /// in its place; its `redirectionDepth` is above 0 when the connection
    /// that failed was to a Server Redirection's target.
    public func connect(
        configuration: RDPConnectionConfiguration,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onRemotePointer: RDPRemotePointerHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardContent: RDPClipboardContentHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onClipboardRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler? = nil,
        onClipboardLocalFilePasteProgress: RDPClipboardLocalFilePasteProgressHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        audioPlaybackDelay: RDPAudioPlaybackDelayHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        storedClientLicenseProvider: RDPStoredClientLicenseProvider? = nil,
        onClientLicenseIssued: RDPClientLicenseIssuedHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        wireTranscript: RDPWireTranscript? = nil,
        liveReport: RDPLiveConnectionReport? = nil,
        cancellation: RDPConnectionCancellation? = nil,
        shouldCancel: RDPCancellationHandler? = nil
    ) throws -> RDPConnectionReport {
        let callbacks = RDPSessionCallbacks(
            onGraphicsFrame: onGraphicsFrame,
            onRemotePointer: onRemotePointer,
            onInputReady: onInputReady,
            onDisplayControlReady: onDisplayControlReady,
            onClipboardReady: onClipboardReady,
            onClipboardText: onClipboardText,
            onClipboardContent: onClipboardContent,
            onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onClipboardFileContents: onClipboardFileContents,
            onClipboardRemoteCopyUnavailable: onClipboardRemoteCopyUnavailable,
            onClipboardLocalFilePasteProgress: onClipboardLocalFilePasteProgress,
            onAudioSample: onAudioSample,
            audioPlaybackDelay: audioPlaybackDelay,
            onCertificate: onCertificate,
            storedClientLicenseProvider: storedClientLicenseProvider,
            onClientLicenseIssued: onClientLicenseIssued,
            onWireReceive: onWireReceive,
            wireTranscript: wireTranscript,
            liveReport: liveReport,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
        return try session(configuration: configuration, callbacks: callbacks) { connection, error in
            throw connection.thrownError(error)
        }
    }

    /// Connects, following up to two server redirections ([MS-RDPBCGR] 3.1.5.2), and connects
    /// again once without the stored client license when the server's licensing fails with it,
    /// and once with RSA key exchange when its certificate refuses ECDHE, if allowed.
    private func session(
        configuration initialConfiguration: RDPConnectionConfiguration,
        callbacks: RDPSessionCallbacks,
        onConnectionError: (RDPClientConnection, Error) throws -> RDPConnectionReport
    ) rethrows -> RDPConnectionReport {
        // What the run starts over with: as the application connected, but for a fallback to RSA
        // key exchange.
        var startConfiguration = initialConfiguration
        var configuration = startConfiguration
        var presentedFrames: Int?
        while true {
            let connection = RDPClientConnection(
                configuration: configuration,
                callbacks: callbacks,
                presentedFramesBefore: presentedFrames
            )
            let negotiated: Bool
            do {
                negotiated = try connection.negotiate()
            } catch {
                return try onConnectionError(connection, error)
            }
            guard negotiated else {
                return connection.finishReport()
            }
            let report = connection.runSession()
            presentedFrames = report.runPresentedFrameCount
            // A run cancelled during the redirect or the license retry returns the session that ran.
            guard !callbacks.isCancelled else {
                return report
            }
            // A stored license the server no longer takes would fail every connection until the
            // application dropped it. The run starts over as the application connected, so a
            // redirection's one-time credentials are not used again; the omission carries through
            // a redirection, and nothing is presented to fail a second time.
            if connection.storedClientLicenseWasRejected {
                configuration = startConfiguration
                configuration.omitsStoredClientLicense = true
                continue
            }
            // A certificate that allows keyEncipherment but not the digitalSignature ECDHE needs;
            // the handshake failed before any credential was sent. Offering only RSA key exchange,
            // the client reports no such failure, so this happens once.
            if report.failure == .tlsKeyUsageIncorrect,
               configuration.legacyRSAKeyExchange == .fallback,
               configuration.redirectionDepth == 0
            {
                configuration.fellBackToRSAKeyExchange = true
                startConfiguration.fellBackToRSAKeyExchange = true
                continue
            }
            guard let redirection = connection.redirection,
                  configuration.redirectionDepth < 2,
                  let redirected = configuration.redirected(by: redirection)
            else {
                return report
            }
            configuration = redirected
        }
    }
}

extension RDPConnectionConfiguration {
    /// The configuration for reconnecting where a Server Redirection PDU
    /// points, or nil when it names no target ([MS-RDPBCGR] 2.2.13.1).
    func redirected(by redirection: RDPServerRedirectionPDU) -> RDPConnectionConfiguration? {
        guard !redirection.flags.contains(.noRedirect),
              redirection.routingToken != nil || redirection.targetHost != nil
        else {
            return nil
        }
        var redirected = self
        redirected.host = redirection.targetHost ?? host
        redirected.redirectionNamedHost = redirectionNamedHost || redirection.targetHost != nil
        redirected.redirectionRoutingToken = redirection.routingToken
        redirected.redirectionSessionID = redirection.sessionID
        // The password field is an opaque cookie for the Client Info PDU, not a
        // password for CredSSP ([MS-RDPBCGR] 3.1.5.2.1).
        redirected.redirectionPasswordCookie = redirection.passwordCookie
        redirected.redirectionRDSTLSCredentials = redirection.rdSTLSCredentials(fallback: credentials)
        if let username = redirection.username, let credentials {
            redirected.credentials = RDPCredentials(
                username: username,
                domain: redirection.domain ?? credentials.domain,
                password: credentials.password
            )
        } else if redirection.username != nil || redirection.domain != nil {
            // With no credentials the target still needs the user its cookie signs in.
            redirected.redirectionUser = RDPCredentials(
                username: redirection.username ?? "",
                domain: redirection.domain,
                password: ""
            )
        }
        redirected.redirectionDepth += 1
        // The user agreed to CredSSP below version 5 for the server they connected to, not for
        // one it passes them on to, which never answered the client before.
        redirected.legacyCredSSP = false
        return redirected
    }
}

extension RDPServerRedirectionPDU {
    /// The RDSTLS credentials for a PK-encrypted password, which only the target can
    /// read, so the client hands it on as sent. FreeRDP 3.32 authenticates the
    /// reconnect by RDSTLS when the flag is set (rdp_client_redirect), with the
    /// redirection's user name and domain, or the ones it had. gnome-remote-desktop 50
    /// sets the flag for every client that does not announce iOS or Android, though
    /// it sends the one-time password unencrypted (grd_session_rdp_send_server_redirection;
    /// Fixtures/gnome-remote-login-redirection.json), and its handover daemon takes those
    /// credentials by RDSTLS or CredSSP; Remote Login on Ubuntu 26.04.1 signs in this way.
    func rdSTLSCredentials(fallback credentials: RDPCredentials?) -> RDPRDSTLSPasswordCredentials? {
        guard flags.contains(.passwordIsPKEncrypted), let passwordCookie, !passwordCookie.isEmpty else {
            return nil
        }
        return RDPRDSTLSPasswordCredentials(
            redirectionGuid: redirectionGuid ?? Data(),
            username: username ?? credentials?.username ?? "",
            domain: domain ?? credentials?.domain ?? "",
            password: passwordCookie
        )
    }
}
