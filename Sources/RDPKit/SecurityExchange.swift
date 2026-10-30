import Foundation
@preconcurrency import NIOSSL

extension RDPClientConnection {
    /// TLS, the certificate check, then CredSSP and the Early User
    /// Authorization Result, or RDSTLS, when the server selected them ([MS-RDPBCGR] 5.4.5).
    func establishSecurity() throws {
        guard let transport else {
            throw RDPConnectionError.tls("not connected")
        }
        stage = .tlsHandshake
        try transport.setRecordedLayer(nil)
        if selectedProtocols.contains(.rdSTLS) {
            // The server sends its Capabilities PDU as soon as the handshake completes.
            try transport.setFraming(.rdSTLS)
        }
        let tls = try transport.startTLS(
            serverHostname: sniHostname(for: configuration.host),
            legacyRSAKeyExchange: configuration.legacyRSAKeyExchange
        )
        report.tlsProtocol = tlsVersionName(tls.version)
        let certificate = try inspectPeerCertificates(
            tls.certificates,
            host: configuration.host,
            hideCertificateWarnings: configuration.hideCertificateWarnings,
            timeoutSeconds: configuration.timeoutSeconds,
            callbacks: callbacks
        )
        report.certificateTrusted = certificate.trusted
        report.certificateSHA256 = certificate.sha256
        report.warnings += certificate.warnings
        callbacks.onCertificate?(certificate)
        // Cancelling from onCertificate rejects the server before any credential is sent.
        try callbacks.throwIfCancelled()

        let usesEarlyUserAuthorization = selectedProtocols.contains(.credSSPWithEarlyUserAuth)
        if selectedProtocols.usesCredSSP {
            stage = .credSSP
            guard let credentials = configuration.credentials else {
                throw RDPCredSSPError.missingCredentials
            }
            // inspectPeerCertificates rejects an empty chain.
            try authenticate(
                credentials,
                certificateDER: Data(tls.certificates[0].toDERBytes()),
                then: usesEarlyUserAuthorization ? .earlyUserAuthorizationResult : .rdp
            )
            callbacks.wireTranscript?.recordMarker(direction: .clientToServer, layer: .security)
        }
        if selectedProtocols.contains(.rdSTLS) {
            stage = .rdSTLS
            try authenticateRDSTLS()
            callbacks.wireTranscript?.recordMarker(direction: .clientToServer, layer: .security)
        }
        if usesEarlyUserAuthorization {
            stage = .earlyUserAuthorization
            let result = try RDPEarlyUserAuthorizationResultPDU.parse(receive("Early User Authorization Result PDU"))
            report.earlyUserAuthorizationResult = result.rawValue
            try transport.setFraming(.rdp)
            if result.result == .accessDenied {
                throw RDPConnectionError(.earlyUserAuthorizationDenied, description: "early user authorization denied access")
            }
        }
        try transport.setRecordedLayer(.application)
    }

    /// CredSSP with NTLM ([MS-CSSP] 3.1.5): SPNEGO tokens, the public key
    /// binding, then the password credentials.
    private func authenticate(
        _ credentials: RDPCredentials,
        certificateDER: Data,
        then nextFraming: RDPTransportFraming
    ) throws {
        guard let transport else {
            throw RDPConnectionError.tls("not connected")
        }
        let subjectPublicKey = try RDPCredSSPCertificate.subjectPublicKey(fromCertificateDER: certificateDER)
        let ntlm = try RDPCredSSPNTLMContext(
            credentials: credentials,
            workstationName: clientName,
            channelBindingsHash: RDPCredSSPCertificate.ntlmChannelBindingsHash(fromCertificateDER: certificateDER)
        )
        try transport.setFraming(.credSSP)

        // Windows RDP expects the version 5+ nonce in every TSRequest, the first included.
        let nonce = try RDPCredSSPNTLMContext.secureRandomData(count: 32)
        var version = 6
        var inputToken: Data?
        while true {
            try callbacks.throwIfCancelled()
            let step = try ntlm.initialize(inputToken: inputToken)
            var request = RDPCredSSPTSRequest(
                version: version,
                negoTokens: step.outputToken.map { [$0] } ?? [],
                clientNonce: version >= 5 ? nonce : nil
            )
            if step.isComplete {
                request.pubKeyAuth = try ntlm.wrap(version >= 5
                    ? RDPCredSSPPublicKeyBinding.clientServerHash(subjectPublicKey: subjectPublicKey, nonce: nonce)
                    : subjectPublicKey)
            }
            try transport.send(request.encoded())
            if step.isComplete {
                break
            }
            let response = try receiveTSRequest()
            version = min(response.version, 6)
            guard let serverToken = response.negoTokens.last else {
                throw RDPCredSSPError.missingToken
            }
            inputToken = try RDPSPNEGO.mechanismToken(from: serverToken)
        }

        let binding = try receiveTSRequest()
        version = min(binding.version, 6)
        guard let serverPubKeyAuth = binding.pubKeyAuth else {
            throw RDPCredSSPError.missingPubKeyAuth
        }
        let expectedBinding = version >= 5
            ? RDPCredSSPPublicKeyBinding.serverClientHash(subjectPublicKey: subjectPublicKey, nonce: nonce)
            : try RDPCredSSPPublicKeyBinding.legacyServerResponse(subjectPublicKey: subjectPublicKey)
        guard try ntlm.unwrap(serverPubKeyAuth) == expectedBinding else {
            throw RDPCredSSPError.serverBindingMismatch
        }

        let authInfo = try ntlm.wrap(RDPCredSSPCredentials.passwordCredentials(credentials))
        // The server answers the credentials in the next layer's format, or rejects them.
        try transport.setFraming(.credSSPResult(then: nextFraming))
        try transport.send(RDPCredSSPTSRequest(
            version: version,
            authInfo: authInfo,
            clientNonce: version >= 5 ? nonce : nil
        ).encoded())
    }

    /// RDSTLS with the password credentials a Server Redirection gave: the server's
    /// Capabilities PDU, the client's Authentication Request, the server's Authentication
    /// Response (FreeRDP 3.32, rdstls_client_authenticate).
    private func authenticateRDSTLS() throws {
        guard let transport else {
            throw RDPConnectionError.tls("not connected")
        }
        // The negotiation offers RDSTLS only with these credentials.
        guard let credentials = configuration.redirectionRDSTLSCredentials else {
            throw RDPConnectionError.clientFailure("RDSTLS was selected without redirection credentials")
        }
        try RDPRDSTLS.checkCapabilities(receive("RDSTLS Capabilities PDU"))
        try transport.send(RDPRDSTLS.authenticationRequest(credentials))
        let resultCode = try RDPRDSTLS.authenticationResult(receive("RDSTLS Authentication Response PDU"))
        try transport.setFraming(.rdp)
        guard resultCode == .success else {
            throw RDPConnectionError(
                .rdSTLS(resultCode: resultCode),
                description: "RDSTLS server rejected the redirection's credentials with \(resultCode)"
            )
        }
    }

    private func receiveTSRequest() throws -> RDPCredSSPTSRequest {
        let response = try RDPCredSSPTSRequest.parse(receive("CredSSP response"))
        if let errorCode = response.errorCode {
            throw RDPCredSSPError.serverError(errorCode)
        }
        return response
    }
}
