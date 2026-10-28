import Foundation

/// Connects to an RDP server and runs a session.
///
/// `run` and `connect` block the calling thread for the whole session; call
/// them from a dedicated thread, never from an event loop or a Swift
/// concurrency executor. Every handler runs synchronously on that thread,
/// except `onWireReceive`, which runs on the NIO event loop and must not block.
/// A slow handler delays every channel.
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
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        wireTranscript: RDPWireTranscript? = nil,
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
            onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onClipboardFileContents: onClipboardFileContents,
            onAudioSample: onAudioSample,
            onCertificate: onCertificate,
            onWireReceive: onWireReceive,
            wireTranscript: wireTranscript,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
        return session(configuration: configuration, callbacks: callbacks) { connection, error in
            connection.failedReport(error)
        }
    }

    /// Runs a session and returns its report. Throws when no RDP connection
    /// could be set up: the address could not be resolved, the TCP connection
    /// failed, the X.224 exchange could not be completed, or the run was
    /// cancelled before that. A negotiation the server refuses (RDP_NEG_FAILURE)
    /// or settles on a protocol RDPKit does not support returns a failure report.
    public func connect(
        configuration: RDPConnectionConfiguration,
        onGraphicsFrame: RDPGraphicsFrameHandler? = nil,
        onRemotePointer: RDPRemotePointerHandler? = nil,
        onInputReady: RDPInputSessionHandler? = nil,
        onDisplayControlReady: RDPDisplayControlSessionHandler? = nil,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onAudioSample: RDPAudioSampleHandler? = nil,
        onCertificate: RDPServerCertificateHandler? = nil,
        onWireReceive: RDPWireReceiveHandler? = nil,
        wireTranscript: RDPWireTranscript? = nil,
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
            onClipboardFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onClipboardFileContents: onClipboardFileContents,
            onAudioSample: onAudioSample,
            onCertificate: onCertificate,
            onWireReceive: onWireReceive,
            wireTranscript: wireTranscript,
            cancellation: cancellation,
            shouldCancel: shouldCancel
        )
        return try session(configuration: configuration, callbacks: callbacks) { _, error in
            throw error
        }
    }

    /// Connects, following up to two server redirections ([MS-RDPBCGR] 3.1.5.2).
    private func session(
        configuration: RDPConnectionConfiguration,
        callbacks: RDPSessionCallbacks,
        onConnectionError: (RDPClientConnection, Error) throws -> RDPConnectionReport
    ) rethrows -> RDPConnectionReport {
        var configuration = configuration
        while true {
            let connection = RDPClientConnection(configuration: configuration, callbacks: callbacks)
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
            // A run cancelled during the redirect returns the session that ran.
            guard !callbacks.isCancelled,
                  let redirection = connection.redirection,
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
        redirected.redirectionRoutingToken = redirection.routingToken
        redirected.redirectionSessionID = redirection.sessionID
        // The password field is an opaque cookie for the Client Info PDU, not a
        // password for CredSSP ([MS-RDPBCGR] 3.1.5.2.1).
        redirected.redirectionPasswordCookie = redirection.passwordCookie
        if let username = redirection.username, let credentials {
            redirected.credentials = RDPCredentials(
                username: username,
                domain: redirection.domain ?? credentials.domain,
                password: credentials.password
            )
        }
        redirected.redirectionDepth += 1
        return redirected
    }
}
