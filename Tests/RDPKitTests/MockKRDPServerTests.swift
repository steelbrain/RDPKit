import Foundation
@testable import RDPKit
import Testing

// Each test runs the client against a local mock server. The suite stays
// serialized: running these blocking, timeout-bound sessions in parallel broke
// CI (7ff8283).
@Suite(.serialized)
struct MockKRDPServerTests {
    // MARK: Security negotiation

    @Test func clientReportsNegotiationFailureAsFailure() throws {
        let report = try runMock(.init(securityProtocol: .failure(code: 0x0000_0002))).report

        #expect(report.status == "failure")
        #expect(report.stage == "x224-rdp-negotiation")
        #expect(report.failureCode == 0x0000_0002)
        #expect(report.selectedProtocols == nil)
        #expect(report.error == "RDP negotiation failed with SSL_NOT_ALLOWED_BY_SERVER (0x00000002)")
        #expect(report.failure == .negotiation(code: .sslNotAllowedByServer))
        #expect(report.connectionStage == .negotiation)
    }

    @Test func clientReportsStandardSecurityAsUnsupported() throws {
        let report = try runMock(.init(securityProtocol: .standard)).report

        #expect(report.status == "failure")
        #expect(report.stage == "x224-rdp-negotiation")
        #expect(report.selectedProtocols == ["standard-rdp-security"])
        #expect(report.nextStage == nil)
        #expect(report.error == "standard RDP security is not supported")
        #expect(report.failure == .unsupportedSecurityProtocol)
    }

    @Test func clientRejectsUnrequestedSecurityProtocolSelection() throws {
        let report = try runMock(.init(securityProtocol: .rdSTLS)).report

        #expect(report.status == "failure")
        #expect(report.stage == "x224-rdp-negotiation")
        #expect(report.requestedProtocols == ["tls", "credssp"])
        #expect(report.selectedProtocols == ["rdstls"])
        #expect(report.nextStage == nil)
        #expect(report.error == "server selected an unrequested security protocol")
    }

    @Test func clientCallsCertificateHandlerAfterTLSHandshake() throws {
        let certificate = Locked<RDPServerCertificateInfo?>(nil)
        let report = try runMock(.init(), { $0.hideCertificateWarnings = false }, client: {
            RDPSessionClient().run(configuration: $0, onCertificate: { info in
                certificate.withLock { $0 = info }
            })
        }).report

        let info = try #require(certificate.value)
        #expect(report.status == "success")
        #expect(info.trusted == report.certificateTrusted)
        #expect(info.sha256 == report.certificateSHA256)
        #expect(info.warnings == report.warnings)
        #expect(info.trusted == false)
        #expect(info.sha256?.isEmpty == false)
        #expect(info.warnings.first?.code == "unrecognized-certificate")
    }

    /// BoringSSL refuses ECDHE with a certificate that does not allow digitalSignature.
    @Test func clientExplainsKeyUsageHandshakeFailure() throws {
        let report = try runMock(.init(keyEnciphermentOnlyCertificate: true)).report

        #expect(report.status == "failure")
        #expect(report.stage == "tls-handshake")
        #expect(report.error?.contains("KEY_USAGE_BIT_INCORRECT") == true)
        #expect(report.error?.contains("legacyRSAKeyExchange") == true)
        #expect(report.failure == .tlsKeyUsageIncorrect)
    }

    @Test func clientConnectsWithLegacyRSAKeyExchangeToKeyEnciphermentOnlyCertificate() throws {
        let report = try runMock(.init(keyEnciphermentOnlyCertificate: true), { $0.legacyRSAKeyExchange = true }).report

        #expect(report.status == "success")
        #expect(report.tlsProtocol == "tls1.2")
        #expect(report.rdpGraphicsFirstFrame != nil)
    }

    /// Cancelling from onCertificate rejects the server before any credential is
    /// sent (decision: the security gate runs right after the certificate callback).
    @Test func clientCancelledFromCertificateCallbackSendsNoCredentials() throws {
        let cancellation = RDPConnectionCancellation()
        let run = try runMock(.init(securityProtocol: .credSSP(credentials: mockCredentials)), client: {
            RDPSessionClient().run(
                configuration: $0,
                onCertificate: { _ in cancellation.cancel() },
                cancellation: cancellation
            )
        })

        #expect(run.report.status == "failure")
        #expect(run.report.stage == "tls-handshake")
        #expect(run.report.error == "cancelled")
        #expect(run.report.failure == .cancelled)
        #expect(run.report.rdpClientInfoSent != true)
        #expect(run.transcript.credSSPMessages.isEmpty)
        #expect(run.transcript.disconnectUltimatumReasons.isEmpty)
    }

    @Test func clientVerifiesCredSSPAuthenticationWithMockServer() throws {
        let run = try runMock(.init(securityProtocol: .credSSP(credentials: mockCredentials)))

        #expect(run.report.status == "success")
        #expect(run.report.selectedProtocols == ["credssp"])
        #expect(run.transcript.credSSPMessages == ["ntlm-negotiate", "ntlm-authenticate", "credentials"])
        #expect(run.transcript.credSSPGates == [
            "raw-ntlm-negotiate-token",
            "initial-client-nonce",
            "authenticate-client-nonce",
            "raw-ntlm-authenticate-token",
            "ntlm-channel-bindings",
            "nonce-bound-pubkeyauth",
            "credentials-client-nonce",
        ])
        #expect(run.report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(run.report.error == nil)
        #expect(run.report.failure == nil)
    }

    /// A wrong password gets the NTSTATUS the server answers it with, as Windows does.
    @Test func clientReportsTheStatusOfRejectedCredentials() throws {
        let run = try runMock(.init(securityProtocol: .credSSP(credentials: mockCredentials))) {
            $0.credentials = RDPCredentials(username: mockCredentials.username, password: "wrong")
        }

        #expect(run.report.status == "failure")
        #expect(run.report.connectionStage == .credSSP)
        #expect(run.report.failure == .credSSP(status: .logonFailure))
        #expect(run.report.error == "CredSSP server returned STATUS_LOGON_FAILURE (0xc000006d)")
        #expect(run.transcript.credSSPMessages == ["ntlm-negotiate", "ntlm-authenticate"])
    }

    @Test func clientReportsMissingCredentialsForCredSSP() throws {
        let report = try runMock(.init(securityProtocol: .credSSP(credentials: mockCredentials))) {
            $0.credentials = nil
        }.report

        #expect(report.status == "failure")
        #expect(report.connectionStage == .credSSP)
        #expect(report.failure == .credentialsRequired)
    }

    /// A server checks NTLM against the user and domain apart, so "DOMAIN\user" typed as the
    /// user name must reach it split.
    @Test func clientSplitsDomainQualifiedUsernameForCredSSP() throws {
        let serverCredentials = RDPCredentials(username: "rdp-user", domain: "LAB", password: "secret")
        let run = try runMock(.init(securityProtocol: .credSSP(credentials: serverCredentials))) {
            $0.credentials = RDPCredentials(username: "LAB\\rdp-user", password: "secret")
        }

        #expect(run.report.status == "success")
        #expect(run.report.username == "rdp-user")
        #expect(run.report.domain == "LAB")
        #expect(run.transcript.credSSPMessages == ["ntlm-negotiate", "ntlm-authenticate", "credentials"])
    }

    /// The configured client name and scale reach the server where it reads them: Client Core
    /// Data and the licensing request.
    @Test func clientSendsItsNameAndScale() throws {
        let run = try runMock(.init(licensingBehavior: .serverLicenseRequest)) {
            $0.clientName = "Conference-Room-Mac"
            $0.scaleFactors = RDPDisplayScaleFactors(desktopScaleFactor: 200, deviceScaleFactor: 180)
            $0.physicalSize = RDPDisplayPhysicalSize(widthMillimeters: 600, heightMillimeters: 340)
        }
        let connectInitial = try #require(run.report.mcsConnectInitialHex.flatMap { Data(rdpHexString: $0) })
        let coreStart = try #require(connectInitial.range(of: Data([0x01, 0xC0, 0xEA, 0x00]))?.lowerBound)
        let core = Data(connectInitial[coreStart ..< coreStart + 234])

        #expect(run.report.status == "success")
        #expect(core[24 ..< 56] == utf16LENullTerminated("Conference-Room"))
        #expect(core[216...] == hexData("58 02 00 00 54 01 00 00 00 00 c8 00 00 00 b4 00 00 00"))
        #expect(run.transcript.licenseMachineName == "Conference-Room")
    }

    /// A scale and physical size set after the configuration's initializer are checked as it
    /// checks them: a server ignores both fields when either is out of range ([MS-RDPBCGR] 2.2.1.3.2).
    @Test func clientClampsTheScaleAndDropsAnIgnoredPhysicalSizeSetAfterInit() throws {
        let report = try runMock {
            $0.scaleFactors = RDPDisplayScaleFactors(desktopScaleFactor: 900, deviceScaleFactor: 200)
            $0.physicalSize = RDPDisplayPhysicalSize(widthMillimeters: 600, heightMillimeters: 9)
        }.report
        let core = try clientCoreData(fromMCSConnectInitialHex: report.mcsConnectInitialHex)

        #expect(report.status == "success")
        #expect(core[216...] == hexData("00 00 00 00 00 00 00 00 00 00 f4 01 00 00 b4 00 00 00"))
    }

    /// The auto-reconnect cookie ends the Client Info PDU ([MS-RDPBCGR] 2.2.1.11.1.1.1). A wire
    /// transcript records the client's PDUs, and so its cookie, by length only.
    @Test func clientSendsItsAutoReconnectCookie() throws {
        let cookie = try #require(RDPAutoReconnectCookie(
            logonID: 0x1234_5678,
            arcRandomBits: Data((1 ... 16).map { UInt8($0 * 11) })
        ))
        let wireTranscript = RDPWireTranscript()
        let run = try runMock(.init(), { $0.autoReconnectCookie = cookie }, client: {
            RDPSessionClient().run(configuration: $0, wireTranscript: wireTranscript)
        })
        let clientEvents = wireTranscript.events.filter { $0.direction == .clientToServer && $0.layer == .application }

        #expect(run.report.status == "success")
        #expect(run.transcript.clientInfo?.suffix(30) == hexData("1c 00") + cookie.clientPacket)
        #expect(!clientEvents.isEmpty)
        #expect(clientEvents.allSatisfy { $0.hex == nil })
        #expect(!wireTranscript.events.contains { $0.bytes?.range(of: cookie.securityVerifier) != nil })
    }

    @Test func clientConsumesSuccessfulEarlyUserAuthorizationResult() throws {
        let report = try runMock(.init(securityProtocol: .credSSPWithEarlyUserAuth(
            credentials: mockCredentials,
            authorizationResult: .success
        ))) { $0.earlyUserAuthorizationEnabled = true }.report

        #expect(report.status == "success")
        #expect(report.selectedProtocols == ["credssp-early-user-auth"])
        #expect(report.earlyUserAuthorizationResult == 0x0000_0000)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientFailsWhenEarlyUserAuthorizationDeniesAccess() throws {
        let report = try runMock(.init(securityProtocol: .credSSPWithEarlyUserAuth(
            credentials: mockCredentials,
            authorizationResult: .accessDenied
        ))) { $0.earlyUserAuthorizationEnabled = true }.report

        #expect(report.status == "failure")
        #expect(report.stage == "early-user-authorization")
        #expect(report.selectedProtocols == ["credssp-early-user-auth"])
        #expect(report.earlyUserAuthorizationResult == RDPEarlyUserAuthorizationResult.accessDenied.rawValue)
        #expect(report.error == "early user authorization denied access")
        #expect(report.failure == .earlyUserAuthorizationDenied)
    }

    // MARK: Connection sequence

    /// The plain KRdp-style flow, from MCS to the first AVC420 frame. The mock
    /// insists on a bitmap-codecs capability set in the Confirm Active.
    @Test func clientCapturesGraphicsFrameFromMockKRDPServer() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(requireBitmapCodecsCapability: true), client: {
            RDPSessionClient().run(
                configuration: $0,
                onGraphicsFrame: { frame in observed.withLock { $0.frames.append(frame) } },
                onWireReceive: { sample in observed.withLock { $0.wireBytes += sample.byteCount } }
            )
        }).report

        #expect(report.status == "success")
        #expect(report.selectedProtocols == ["tls"])
        #expect(report.mcsIOChannelID == 1003)
        #expect(report.mcsMessageChannelID == 1005)
        #expect(report.mcsStaticChannels == [
            RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        ])
        #expect(report.rdpLicensingResponseType == "license-error-valid-client")
        #expect(report.rdpPostConfirmActiveResponseType == "server-synchronize")
        #expect(report.rdpConfirmActiveRequestHex.flatMap { Data(rdpHexString: $0)?.count } == 580)
        #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("surface-commands") == true)
        #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("bitmap-codecs") == true)
        #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("frame-acknowledge") == true)
        #expect(report.rdpFinalizationResponseTypes == [
            "server-synchronize",
            "control-cooperate",
            "control-granted-control",
            "font-map",
        ])
        #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsCapsAdvertiseHex?.contains(RDPGFXCapsAdvertisePDU().encoded().rdpHexString) == true)
        #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version81)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
        #expect(report.rdpGraphicsFirstFrame?.width == 64)
        #expect(report.rdpGraphicsFirstFrame?.height == 32)
        #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
        #expect(observed.value.frames == report.rdpGraphicsFrames)
        #expect(observed.value.wireBytes > 0)
        #expect(report.error == nil)
    }

    @Test func clientExplicitlyJoinsEveryMCSChannel() throws {
        let report = try runMock().report

        let joinedChannels = try #require(report.mcsJoinedChannels)
        #expect(report.status == "success")
        #expect(joinedChannels.map(\.name) == ["user", "io", "drdynvc", "message"])
        #expect(joinedChannels.allSatisfy { $0.result == "rt-successful" })
        #expect(joinedChannels.allSatisfy { $0.requestHex.isEmpty == false })
        #expect(joinedChannels.allSatisfy { $0.confirmHex.isEmpty == false })
    }

    @Test func clientConnectInitialCarriesKRDPCompatibleClientCoreData() throws {
        let report = try runMock().report

        #expect(report.status == "success")
        let core = try clientCoreData(fromMCSConnectInitialHex: report.mcsConnectInitialHex)
        let earlyCapabilityFlags = core.littleEndianUInt16(at: 144)

        #expect(core.count == 234)
        #expect(core.prefix(4) == Data([0x01, 0xC0, 0xEA, 0x00]))
        #expect(earlyCapabilityFlags == 0x01AF)
        #expect(earlyCapabilityFlags & 0x0040 == 0)
        #expect(earlyCapabilityFlags & 0x0800 == 0)
        #expect(core[210] == 0x07)
        #expect(core.littleEndianUInt32(at: 212) == RDPSecurityProtocols.tls.rawValue)
        #expect(core.littleEndianUInt32(at: 216) == 0)
        #expect(core.littleEndianUInt32(at: 220) == 0)
        #expect(core.littleEndianUInt16(at: 224) == 0)
        #expect(core.littleEndianUInt32(at: 226) == 100)
        #expect(core.littleEndianUInt32(at: 230) == 100)
    }

    /// The configured keyboard reaches the Client Core Data and the Input Capability Set.
    @Test func clientAnnouncesTheConfiguredKeyboard() throws {
        let report = try runMock(.init()) {
            $0.keyboardLayout = RDPKeyboardLayout(rawValue: 0x0000_0411)
            $0.keyboardType = .japanese
            $0.keyboardSubType = 2
            $0.keyboardFunctionKeyCount = 12
        }.report

        #expect(report.status == "success")
        let core = try clientCoreData(fromMCSConnectInitialHex: report.mcsConnectInitialHex)
        #expect(core.littleEndianUInt32(at: 16) == 0x0000_0411)
        #expect(core[56 ..< 68] == hexData("07 00 00 00 02 00 00 00 0c 00 00 00"))
        let confirmActive = try #require(report.rdpConfirmActiveRequestHex.flatMap(Data.init(rdpHexString:)))
        // TS_INPUT_CAPABILITYSET: type 0x000D, length 88.
        #expect(confirmActive.range(of: hexData("0d 00 58 00 35 01 00 00 11 04 00 00 07 00 00 00 02 00 00 00 0c 00 00 00")) != nil)
    }

    /// Recording a wire transcript keeps every server PDU for replay but only
    /// the length of the client's, which carry credentials.
    @Test func wireTranscriptRedactsClientApplicationPayloadsButKeepsByteCounts() throws {
        let transcript = RDPWireTranscript()
        let report = try runMock(client: { RDPSessionClient().run(configuration: $0, wireTranscript: transcript) }).report
        let application = transcript.events.filter { $0.layer == .application }
        let client = application.filter { $0.direction == .clientToServer }
        let server = application.filter { $0.direction == .serverToClient }

        #expect(report.status == "success")
        #expect(!client.isEmpty)
        #expect(client.allSatisfy { $0.hex == nil && $0.byteCount > 0 })
        #expect(!server.isEmpty)
        #expect(server.allSatisfy { $0.bytes?.count == $0.byteCount })
    }

    @Test func clientFollowsServerRedirectionAndReconnects() throws {
        let run = try runMock(.init(redirectionBehavior: .redirectFirstConnection))

        // The first connection is redirected mid graphics handshake; the client must
        // reconnect (carrying the routing token) and complete on the second attempt.
        #expect(run.connectionCount == 2)
        #expect(run.report.status == "success")
        #expect(run.report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(run.report.error == nil)
    }

    /// A run cancelled once a redirect arrives returns the redirected session's report
    /// instead of opening the connection the redirect points to. The redirect answers the
    /// client's caps advertise, so the client is waiting for it and reads it.
    @Test func cancellingDuringARedirectReturnsTheSessionThatRan() throws {
        let transcript = RDPWireTranscript()
        let sawRedirect: @Sendable () -> Bool = {
            transcript.events.contains { event in
                guard event.direction == .serverToClient,
                      let bytes = event.bytes,
                      let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: bytes)
                else {
                    return false
                }
                return (try? RDPServerRedirectionPDU.parseIfPresent(from: indication)) != nil
            }
        }
        let run = try runMock(.init(redirectionBehavior: .redirectFirstConnection), client: {
            RDPSessionClient().run(configuration: $0, wireTranscript: transcript, shouldCancel: sawRedirect)
        })

        #expect(run.report.stage == "rdp-graphics-dynamic-channel")
        #expect(run.report.rdpClientInfoSent == true)
        #expect(run.report.error == "cancelled")
    }

    @Test func clientFollowsRedirectionSentInsteadOfDemandActive() throws {
        let run = try runMock(.init(redirectionBehavior: .redirectInsteadOfDemandActive))

        #expect(run.connectionCount == 2)
        #expect(run.report.status == "success")
        #expect(run.report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(run.report.error == nil)
    }

    /// A connect-time auto-detect run made only of requests without a response
    /// must not fail the connection (C R0).
    @Test func clientContinuesAfterAutoDetectRequestsWithoutResponses() throws {
        let report = try runMock(.init(autoDetectBehavior: .noReplyRequestOnly)).report

        #expect(report.status == "success")
        #expect(report.rdpAutoDetectRequestType == "connect-time-bandwidth-measure-start")
        #expect(report.rdpAutoDetectResponseHex == nil)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    }

    @Test func clientHandlesMultiStepBandwidthAutoDetectBeforeActivation() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(autoDetectBehavior: .bandwidthMeasure), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpAutoDetectRequestType == "connect-time-rtt-measure-request")
        #expect(report.rdpLicensingResponseType == "license-error-valid-client")
        #expect(report.rdpPostLicensingResponseType == "server-demand-active")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(observed.value.frames == report.rdpGraphicsFrames)
        #expect(report.error == nil)
    }

    // MARK: Licensing

    @Test func clientActivatesWhenDemandActiveArrivesWithoutLicensingPDU() throws {
        let report = try runMock(.init(licensingBehavior: .demandActiveOnly)).report

        #expect(report.status == "success")
        #expect(report.rdpLicensingResponseType == nil)
        #expect(report.rdpPostAutoDetectResponseType == "server-demand-active")
        #expect(report.rdpPostLicensingResponseType == nil)
        #expect(report.rdpConfirmActiveRequestHex != nil)
        #expect(report.rdpPostConfirmActiveResponseType == "server-synchronize")
        #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientRespondsToServerLicenseRequest() throws {
        let report = try runMock(.init(licensingBehavior: .serverLicenseRequest)).report

        #expect(report.status == "success")
        #expect(report.rdpLicensingResponseType == "license-request")
        #expect(report.rdpPostLicensingResponseType == "server-demand-active")
        #expect(report.rdpConfirmActiveRequestHex != nil)
        #expect(report.error == nil)
    }

    @Test func clientRespondsToX509ServerLicenseRequest() throws {
        let report = try runMock(.init(licensingBehavior: .serverLicenseRequestX509)).report

        #expect(report.status == "success")
        #expect(report.rdpLicensingResponseType == "license-request")
        #expect(report.rdpPostLicensingResponseType == "server-demand-active")
        #expect(report.rdpConfirmActiveRequestHex != nil)
        #expect(report.error == nil)
    }

    @Test func clientSendsClientLicenseInformationForMatchingStoredLicense() throws {
        let report = try runMock(.init(licensingBehavior: .serverLicenseRequestWithStoredClientLicense)) {
            $0.storedClientLicense = RDPStoredClientLicense(
                version: 0x0006_0001,
                scope: "localhost",
                companyName: "Microsoft Corporation",
                productID: "A02",
                licenseInfo: Data([0x30, 0x82, 0x01, 0x02])
            )
        }.report

        #expect(report.status == "success")
        #expect(report.rdpLicensingResponseType == "license-request")
        #expect(report.rdpPostLicensingResponseType == "server-demand-active")
        #expect(report.rdpConfirmActiveRequestHex != nil)
        #expect(report.error == nil)
    }

    @Test func clientReportsLicensingFailureWithTheServerErrorCode() throws {
        let report = try runMock(.init(licensingBehavior: .noLicenseServerError)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-licensing")
        #expect(report.rdpLicensingResponseType == "license-error-0x00000006")
        #expect(report.rdpLicensingErrorCode == 0x0000_0006)
        #expect(report.error == "server licensing failed: ERR_NO_LICENSE_SERVER (0x00000006), ST_TOTAL_ABORT")
        #expect(report.failure == .licensing(errorCode: 0x0000_0006))
    }

    @Test func clientReportsDisconnectAfterClientInfo() throws {
        let report = try runMock(.init(licensingBehavior: .disconnectInsteadOfLicensing)).report

        #expect(report.status == "failure")
        #expect(report.rdpClientInfoSent == true)
        #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
        #expect(report.error == "server ended the session with rn-user-requested")
        // Before the session runs, even an end with no reason is a failure.
        #expect(report.failure == .serverTermination(termination: RDPRemoteTermination(disconnectReason: 3)))
        #expect(report.remoteTermination?.category == .unspecified)
    }

    // MARK: Connection finalization

    @Test func clientSendsFontListBeforeWaitingForControlGranted() throws {
        let report = try runMock(.init(finalizationBehavior: .waitForFontListBeforeGrant)).report

        #expect(report.status == "success")
        #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientContinuesWhenShareDataArrivesBeforeServerSynchronize() throws {
        let report = try runMock(.init(finalizationBehavior: .saveSessionInfoBeforeSynchronize)).report

        #expect(report.status == "success")
        #expect(report.rdpPostConfirmActiveResponseType == "save-session-info")
        #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientCompletesWhenServerWaitsForClientSynchronizeBeforeServerSynchronize() throws {
        let report = try runMock(.init(finalizationBehavior: .waitForClientSynchronizeBeforeServerSynchronize)).report

        #expect(report.status == "success")
        #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
        #expect(report.rdpFinalizationResponseTypes?.contains("control-cooperate") == true)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientCompletesWhenServerControlCooperateArrivesBeforeSynchronize() throws {
        let report = try runMock(.init(finalizationBehavior: .controlCooperateBeforeSynchronize)).report

        #expect(report.status == "success")
        #expect(report.rdpFinalizationResponseTypes?.prefix(2) == ["control-cooperate", "server-synchronize"])
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientContinuesWhenMonitorLayoutArrivesBeforeServerSynchronize() throws {
        let report = try runMock(.init(licensingBehavior: .validClientThenDemandActiveWithMonitorLayout)).report

        #expect(report.status == "success")
        #expect(report.rdpPostConfirmActiveResponseType == "monitor-layout")
        #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    /// The mock never sends Font Map; the client gives up at its receive timeout.
    @Test func clientRequiresFontMapBeforeGraphicsHandshake() throws {
        let report = try runMock(.init(finalizationBehavior: .grantControlWithoutFontMap)) {
            $0.timeoutSeconds = 1
        }.report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-connection-finalization")
        #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == false)
        #expect(report.rdpGraphicsChannelName == nil)
        #expect(report.error == "server did not send Font Map during connection finalization")
    }

    @Test func clientReactivatesAfterDeactivateAllAndDemandActive() throws {
        let inputSessions = Locked(0)
        let report = try runMock(.init(finalizationBehavior: .deactivateThenReactivateAfterFontMap), client: {
            RDPSessionClient().run(configuration: $0, onInputReady: { _ in inputSessions.withLock { $0 += 1 } })
        }).report

        #expect(report.status == "success")
        #expect(report.rdpFinalizationResponseTypes?.filter { $0 == "font-map" }.count == 2)
        #expect(inputSessions.value == 2)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    /// MS-RDPBCGR 3.2.5.5.1: input sent through a session the server deactivated is dropped.
    @Test func deactivateAllStopsTheEarlierInputSession() throws {
        let sessions = Locked([RDPInputSession]())
        let run = try runMock(.init(finalizationBehavior: .deactivateThenReactivateAfterFontMap), client: {
            RDPSessionClient().run(configuration: $0, onInputReady: { session in
                let earlier = sessions.withLock { $0.last }
                sessions.withLock { $0.append(session) }
                earlier?.send(.pointerMove(x: 1, y: 1))
                session.send(.pointerMove(x: 2, y: 2))
            })
        })

        #expect(run.report.status == "success")
        #expect(sessions.value.count == 2)
        #expect(run.transcript.inputEvents == [.pointerMove(x: 2, y: 2), .pointerMove(x: 2, y: 2)])
    }

    // MARK: Session end before graphics

    /// A Deactivate All that no Demand Active follows; the client gives up at
    /// its receive timeout.
    @Test func clientReportsServerDeactivateBeforeGraphicsAsDisconnect() throws {
        let report = try runMock(.init(finalizationBehavior: .deactivateAfterFontMap)) {
            $0.timeoutSeconds = 1
        }.report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpDynamicChannelRequestTypes == [])
        #expect(report.error == "server deactivated the session before opening RDPGFX dynamic channel")
        #expect(report.failure == .timedOut)
    }

    @Test func clientRejectsSetErrorInfoLogoffBeforeGraphics() throws {
        let report = try runMock(.init(finalizationBehavior: .setErrorInfoLogoffThenDeactivateAfterFontMap)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.nextStage == nil)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpDynamicChannelRequestTypes == [])
        #expect(report.rdpRemoteTerminationErrorInfo == 0x0000_000C)
        #expect(report.rdpRemoteTerminationErrorInfoName == "ERRINFO_LOGOFF_BY_USER")
        #expect(report.rdpRemoteTerminationDisconnectReason == 3)
        #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
        #expect(report.error == "server ended the session with ERRINFO_LOGOFF_BY_USER before opening RDPGFX dynamic channel")
        #expect(report.failure == .serverTermination(termination: RDPRemoteTermination(errorInfo: 0xC, disconnectReason: 3)))
    }

    /// Set Error Info and Deactivate All, then silence: the client waits its
    /// one-second termination grace period for the disconnect.
    @Test func clientRejectsNonCleanSetErrorInfoBeforeGraphics() throws {
        let report = try runMock(.init(finalizationBehavior: .setErrorInfoDeniedThenDeactivateAfterFontMap)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpDynamicChannelRequestTypes == [])
        #expect(report.error
            == "server ended the session with ERRINFO_SERVER_DENIED_CONNECTION before opening RDPGFX dynamic channel")
        #expect(report.failure == .serverTermination(termination: RDPRemoteTermination(errorInfo: 7)))
        #expect(report.remoteTermination?.category == .accessDenied)
    }

    @Test func clientRejectsDeactivateThenUserRequestedDisconnectBeforeGraphics() throws {
        let report = try runMock(.init(finalizationBehavior: .deactivateThenUserRequestedDisconnectAfterFontMap)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.nextStage == nil)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpDynamicChannelRequestTypes == [])
        #expect(report.rdpRemoteTerminationErrorInfo == nil)
        #expect(report.rdpRemoteTerminationErrorInfoName == nil)
        #expect(report.rdpRemoteTerminationDisconnectReason == 3)
        #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
        #expect(report.error == "server ended the session with rn-user-requested before opening RDPGFX dynamic channel")
    }

    @Test func clientRejectsUserRequestedDisconnectBeforeGraphics() throws {
        let report = try runMock(.init(finalizationBehavior: .userRequestedDisconnectAfterFontMap)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.nextStage == nil)
        #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
        #expect(report.rdpDynamicChannelRequestTypes == [])
        #expect(report.rdpRemoteTerminationDisconnectReason == 3)
        #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
        #expect(report.error == "server ended the session with rn-user-requested before opening RDPGFX dynamic channel")
    }

    // MARK: Dynamic channels

    @Test func clientRejectsUnsupportedDynamicChannelsBeforeGraphics() throws {
        let run = try runMock(.init(auxiliaryDynamicChannelBehavior: .unsupportedChannels))

        let dynamicRequestTypes = run.report.rdpDynamicChannelRequestTypes ?? []
        let statuses = run.transcript.dynamicCreateStatuses
        #expect(run.report.status == "success")
        for (channelID, channelName) in MockKRDPAuxiliaryDynamicChannelBehavior.unsupportedChannels.createRequests {
            #expect(dynamicRequestTypes.contains("dynvc-create-request:\(channelName)"))
            #expect((statuses[channelID] ?? 0) < 0)
        }
        #expect(statuses[7] == 0)
        #expect(run.report.rdpGraphicsChannelName == RDPGFXChannel.name)
        #expect(run.report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(run.report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(run.report.error == nil)
    }

    @Test func clientCapsDynamicVirtualChannelResponseAtWindowsVersionThree() throws {
        let report = try runMock(.init(dynamicChannelVersion: 3)).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelCapabilitiesVersion == 3)
        #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 03 00") == true)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientAcceptsFragmentedStaticDynamicChannelCreateRequest() throws {
        let report = try runMock(.init(auxiliaryDynamicChannelBehavior: .fragmentedGraphicsCreate)).report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientDecodesCompressedDynamicVirtualChannelGraphicsData() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendCompressedCAVideoRemoteFXFrame,
            dynamicChannelVersion: 3
        )).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelCapabilitiesVersion == 3)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "surface-bgra")
        #expect(report.rdpGraphicsUpdateMessages?.contains(where: { $0.codecName == "cavideo" }) == true)
        #expect(report.error == nil)
    }

    @Test func clientRejectsUnsupportedCompressedDynamicVirtualChannelData() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendUnsupportedCompressedDynamicData,
            dynamicChannelVersion: 3
        )).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.error == "invalid RDP Dynamic Virtual Channel PDU")
    }

    /// Decompressed DVC data can exceed one 1,600-byte PDU; it once went through
    /// an encoding initializer that trapped. Here it reaches the graphics decoder,
    /// which rejects the 0x41 bytes as RDPGFX data.
    @Test func clientHandlesCompressedDynamicDataLargerThanOnePDU() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendCompressedDataLargerThanOnePDU,
            dynamicChannelVersion: 3
        )).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.error == "invalid RDP Graphics Pipeline PDU")
    }

    @Test func clientIgnoresDynamicVirtualChannelSoftSyncRequest() throws {
        let report = try runMock(.init(graphicsBehavior: .sendSoftSyncBeforeFrame)).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-soft-sync-request") == true)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientIgnoresUnknownDynamicVirtualChannelClose() throws {
        let report = try runMock(.init(graphicsBehavior: .sendUnknownCloseBeforeFrame)).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-close") == true)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    // MARK: RDPGFX capabilities

    @Test func clientAdvertisesGraphicsProfilesToMockServer() throws {
        let cases: [(profile: RDPGraphicsCapabilityProfile, selectedVersion: UInt32, selectedFlags: UInt32)] = [
            (.automatic, RDPGFXCapabilityVersion.version107, RDPGFXCapabilityFlags.defaultVersion107),
            (.avcThinClient, RDPGFXCapabilityVersion.version107, RDPGFXCapabilityFlags.defaultVersion107),
            (.avc420, RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.defaultVersion81),
            (.legacy, RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.defaultVersion8),
        ]

        for testCase in cases {
            let report = try runMock(.init(graphicsCapabilitySelection: .firstAdvertised)) {
                $0.graphicsCapabilityProfile = testCase.profile
            }.report

            let advertisedCaps = RDPGFXCapsAdvertisePDU(
                capabilitySets: testCase.profile.capabilitySets
            ).encoded().rdpHexString

            #expect(report.status == "success")
            #expect(report.rdpGraphicsCapabilityProfile == testCase.profile)
            #expect(report.rdpGraphicsCapsAdvertiseHex?.contains(advertisedCaps) == true)
            #expect(report.rdpGraphicsSelectedCapabilityVersion == testCase.selectedVersion)
            #expect(report.rdpGraphicsSelectedCapabilityFlags == testCase.selectedFlags)
            #expect(report.error == nil)
        }
    }

    @Test func clientAcceptsAdvertisedIntermediateGraphicsCapabilityConfirm() throws {
        let report = try runMock(.init(graphicsCapabilitySelection: .version10)).report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version10)
        #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
        #expect(report.rdpGraphicsFirstFrame != nil)
        #expect(report.error == nil)
    }

    @Test func clientAcceptsGraphicsCapabilityConfirmWithDifferentValidFlags() throws {
        let report = try runMock(.init(graphicsCapabilitySelection: .firstAdvertisedDifferentFlags)).report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version107)
        #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
        #expect(report.rdpGraphicsFirstFrame != nil)
        #expect(report.error == nil)
    }

    @Test func clientRejectsKnownUnadvertisedGraphicsCapabilityConfirm() throws {
        let report = try runMock(.init(graphicsCapabilitySelection: .version10)) {
            $0.graphicsCapabilityProfile = .legacy
        }.report

        #expect(report.status == "failure")
        #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version10)
        #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
        #expect(report.rdpGraphicsFirstFrame == nil)
        #expect(report.error == "server confirmed an RDPGFX capability version that the client did not advertise")
    }

    @Test func clientAcceptsCompressedDataFirstGraphicsCapsConfirm() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendCompressedCapsConfirmFirstFrame,
            dynamicChannelVersion: 3
        )).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 03 00") == true)
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    @Test func clientRejectsCompressedGraphicsCapsConfirmWithoutVersion3() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendCompressedCapsConfirmFirstFrame,
            dynamicChannelVersion: 2
        )).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpDynamicChannelCapabilitiesVersion == 2)
        #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 02 00") == true)
        #expect(report.rdpGraphicsResponseType == nil)
        #expect(report.error == "invalid RDP Dynamic Virtual Channel PDU")
    }

    @Test func clientAcceptsFragmentedMixedCompressedGraphicsCapsConfirm() throws {
        let report = try runMock(.init(
            graphicsBehavior: .sendFragmentedCompressedCapsConfirmFirstFrame,
            dynamicChannelVersion: 3
        )).report

        #expect(report.status == "success")
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data") == true)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    /// The mock sends the first fragment and stops; the client gives up at its
    /// receive timeout.
    @Test func clientReportsIncompleteFragmentedGraphicsCapsConfirm() throws {
        let report = try runMock(.init(
            graphicsBehavior: .stallAfterFragmentedCapsConfirm,
            dynamicChannelVersion: 3
        )) { $0.timeoutSeconds = 1 }.report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
        #expect(report.rdpGraphicsResponseType == nil)
        #expect(report.error == "server did not complete fragmented RDPGFX capabilities data")
    }

    // MARK: Graphics updates

    @Test func clientResolvesPointerCacheUpdatesFromMockKRDPServer() throws {
        let pointerUpdates = Locked<[RDPRemotePointerUpdate]>([])
        let report = try runMock(.init(graphicsBehavior: .sendPointerUpdatesBeforeFirstFrame), client: {
            RDPSessionClient().run(configuration: $0, onRemotePointer: { update in
                pointerUpdates.withLock { $0.append(update) }
            })
        }).report

        let image = RDPRemotePointerImage(
            cacheIndex: 2,
            hotSpot: RDPRemotePoint(x: 0, y: 0),
            width: 1,
            height: 1,
            xorBitsPerPixel: 24,
            xorMaskData: Data([0xaa, 0xbb, 0xcc, 0x00]),
            andMaskData: Data([0xff, 0x00])
        )
        #expect(report.status == "success")
        #expect(pointerUpdates.value == [.image(image), .cachedImage(image)])
        #expect(report.error == nil)
    }

    /// gnome-remote-desktop in extend mode hides the client's pointer before it opens the RDPGFX
    /// channel (PR #5); a pointer the server cached then still resolves afterwards.
    @Test func clientForwardsPointerUpdatesSentBeforeTheGraphicsChannelOpens() throws {
        let pointerUpdates = Locked<[RDPRemotePointerUpdate]>([])
        let report = try runMock(.init(graphicsBehavior: .sendFastPathPointerUpdatesBeforeGraphicsChannel), client: {
            RDPSessionClient().run(configuration: $0, onRemotePointer: { update in
                pointerUpdates.withLock { $0.append(update) }
            })
        }).report

        let image = RDPRemotePointerImage(
            cacheIndex: 2,
            hotSpot: RDPRemotePoint(x: 0, y: 0),
            width: 1,
            height: 1,
            xorBitsPerPixel: 24,
            xorMaskData: Data([0xaa, 0xbb, 0xcc, 0x00]),
            andMaskData: Data([0xff, 0x00])
        )
        #expect(report.status == "success")
        #expect(pointerUpdates.value == [.hidden, .image(image), .cachedImage(image)])
        #expect(report.error == nil)
    }

    @Test func clientReportsFailingGraphicsUpdateFromMockServer() throws {
        let report = try runMock(.init(graphicsBehavior: .sendInvalidGraphicsPDU)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpGraphicsFailureUpdateResponseHex != nil)
        #expect(report.rdpGraphicsFailureUpdatePayloadHex == "12 00 00")
        #expect(report.rdpGraphicsFailureUpdateMessages == [])
        #expect(report.rdpGraphicsFailureUpdateMessageIndex == nil)
        #expect(report.error == "invalid RDP Graphics Pipeline PDU")
    }

    @Test func clientRejectsMalformedAVCFrameFromMockServer() throws {
        let report = try runMock(.init(graphicsBehavior: .sendMalformedAVCFrame)).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpGraphicsFailureUpdateMessages?.map(\.typeName) == [
            "rdpgfx-create-surface",
            "rdpgfx-start-frame",
            "rdpgfx-wire-to-surface-1",
            "rdpgfx-end-frame",
        ])
        #expect(report.rdpGraphicsFailureUpdateMessageIndex == 2)
        #expect(report.error == "truncated input: needed 4 bytes, had 1")
    }

    @Test func clientVerifiesFragmentedBitmapGraphicsWithMockServer() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendFragmentedBitmapCompositionFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        let frame = try #require(report.rdpGraphicsFirstFrame)
        let bitmapData = try #require(frame.decodedBitmapData)
        let messageNames = report.rdpGraphicsUpdateMessages?.map(\.typeName) ?? []

        #expect(report.status == "success")
        #expect(report.rdpGraphicsUpdateResponseCount ?? 0 >= 1)
        #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
        #expect(messageNames.contains("rdpgfx-create-surface"))
        #expect(messageNames.contains("rdpgfx-map-surface-to-output"))
        #expect(messageNames.contains("rdpgfx-solid-fill"))
        #expect(messageNames.contains("rdpgfx-surface-to-cache"))
        #expect(messageNames.contains("rdpgfx-cache-to-surface"))
        #expect(messageNames.contains("rdpgfx-wire-to-surface-1"))
        #expect(messageNames.contains("rdpgfx-end-frame"))
        #expect(frame.frameID == 2)
        #expect(frame.codecName == "surface-bgra")
        #expect(frame.contentKind == .bitmap)
        #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 14, bottom: 24))
        // The second fill, less the cache copy's block; ClearCodec drew inside the fill.
        #expect(frame.regionRects == [
            RDPFrameRect(left: 10, top: 20, right: 14, bottom: 22),
            RDPFrameRect(left: 10, top: 22, right: 12, bottom: 24),
            RDPFrameRect(left: 12, top: 22, right: 14, bottom: 24),
        ])
        #expect(frame.decodedBitmapBytesPerRow == 16)
        #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 16) == [0x09, 0x08, 0x07, 0xFF])
        #expect(pixel(atX: 2, y: 2, data: bitmapData, bytesPerRow: 16) == [0x01, 0x02, 0x03, 0xFF])
        #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 16) == [0x10, 0x20, 0x30, 0xFF])
        #expect(pixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 16) == [0x40, 0x50, 0x60, 0xFF])
        #expect(observed.value.frames == report.rdpGraphicsFrames)
        #expect(report.error == nil)
    }

    @Test func clientDecodesClearCodecBandsFrameFromMockServer() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendClearCodecBandsFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        let frame = try #require(report.rdpGraphicsFirstFrame)
        let bitmapData = try #require(frame.decodedBitmapData)
        let messageNames = report.rdpGraphicsUpdateMessages?.map(\.typeName) ?? []
        let wireMessage = try #require(report.rdpGraphicsUpdateMessages?.first {
            $0.typeName == "rdpgfx-wire-to-surface-1"
        })

        #expect(report.status == "success")
        #expect(messageNames.contains("rdpgfx-wire-to-surface-1"))
        #expect(messageNames.contains("rdpgfx-surface-to-cache"))
        #expect(messageNames.contains("rdpgfx-cache-to-surface"))
        #expect(wireMessage.clearCodecResidualByteCount == 0)
        #expect(wireMessage.clearCodecBandsByteCount == 24)
        #expect(wireMessage.clearCodecSubcodecByteCount == 0)
        #expect(frame.frameID == 3)
        #expect(frame.codecName == "surface-bgra")
        #expect(frame.contentKind == .bitmap)
        #expect(frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 2, bottom: 3))
        #expect(frame.decodedBitmapBytesPerRow == 8)
        #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
        #expect(pixel(atX: 1, y: 0, data: bitmapData, bytesPerRow: 8) == [0x70, 0x80, 0x90, 0xFF])
        #expect(pixel(atX: 0, y: 1, data: bitmapData, bytesPerRow: 8) == [0x10, 0x20, 0x30, 0xFF])
        #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
        #expect(pixel(atX: 0, y: 2, data: bitmapData, bytesPerRow: 8) == [0x40, 0x50, 0x60, 0xFF])
        #expect(pixel(atX: 1, y: 2, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
        #expect(observed.value.frames == report.rdpGraphicsFrames)
        #expect(report.error == nil)
    }

    @Test func clientDecodesCAVideoRemoteFXProfilesFromMockServer() throws {
        let cases: [(profile: RDPGraphicsCapabilityProfile, selectedVersion: UInt32, selectedFlags: UInt32)] = [
            (.avc420, RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.defaultVersion81),
            (.legacy, RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.defaultVersion8),
        ]

        for testCase in cases {
            let observed = Locked(Observed())
            let report = try runMock(
                .init(graphicsBehavior: .sendCAVideoRemoteFXFrame, graphicsCapabilitySelection: .firstAdvertised),
                { $0.graphicsCapabilityProfile = testCase.profile },
                client: {
                    RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                        observed.withLock { $0.frames.append(frame) }
                    })
                }
            ).report

            let frame = try #require(report.rdpGraphicsFirstFrame)
            let bitmapData = try #require(frame.decodedBitmapData)
            let wireMessage = try #require(report.rdpGraphicsUpdateMessages?.first {
                $0.codecName == "cavideo"
            })

            #expect(report.status == "success")
            #expect(report.rdpGraphicsCapabilityProfile == testCase.profile)
            #expect(report.rdpGraphicsSelectedCapabilityVersion == testCase.selectedVersion)
            #expect(report.rdpGraphicsSelectedCapabilityFlags == testCase.selectedFlags)
            #expect(wireMessage.cavideoTileCount == 1)
            #expect(wireMessage.cavideoTileSetEntropyAlgorithms == ["rlgr3"])
            #expect(frame.frameID == 4)
            #expect(frame.codecName == "surface-bgra")
            #expect(frame.contentKind == .bitmap)
            #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84))
            #expect(frame.regionRects == [RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84)])
            #expect(frame.decodedBitmapBytesPerRow == 256)
            #expect(frame.bitmapByteCount == 64 * 64 * 4)
            #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
            #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
            #expect(RDPGraphicsPathDescription.describe(report: report).contains("cavideo remotefx"))
            #expect(observed.value.frames == report.rdpGraphicsFrames)
            #expect(report.error == nil)
        }
    }

    @Test func clientDecodesCAProgressiveFrameFromMockServer() throws {
        let observed = Locked(Observed())
        let report = try runMock(
            .init(graphicsBehavior: .sendCAProgressiveFrame, graphicsCapabilitySelection: .firstAdvertised),
            client: {
                RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                    observed.withLock { $0.frames.append(frame) }
                })
            }
        ).report

        let frame = try #require(report.rdpGraphicsFirstFrame)
        let bitmapData = try #require(frame.decodedBitmapData)
        let wireMessage = try #require(report.rdpGraphicsUpdateMessages?.first {
            $0.codecName == "caprogressive"
        })

        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(report.rdpGraphicsCapabilityProfile == .automatic)
        #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version107)
        #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.defaultVersion107)
        #expect(wireMessage.typeName == "rdpgfx-wire-to-surface-2")
        #expect(wireMessage.progressiveBlockTypeNames == ["sync", "context", "frame-begin", "region", "frame-end"])
        #expect(wireMessage.progressiveContextTileSizes == [64])
        #expect(wireMessage.progressiveContextFlags == [1])
        #expect(wireMessage.progressiveFrameIndexes == [1])
        #expect(wireMessage.progressiveFrameRegionCounts == [1])
        #expect(wireMessage.progressiveRegionRects == [
            RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
        ])
        #expect(wireMessage.progressiveRegionTileCount == 1)
        #expect(wireMessage.progressiveTileSimpleCount == 1)
        #expect(wireMessage.progressiveTileFirstCount == 0)
        #expect(wireMessage.progressiveTileUpgradeCount == 0)
        #expect(frame.frameID == 10)
        #expect(frame.codecName == "surface-bgra")
        #expect(frame.contentKind == .bitmap)
        #expect(frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64))
        #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64)])
        #expect(frame.decodedBitmapBytesPerRow == 256)
        #expect(frame.bitmapByteCount == 64 * 64 * 4)
        #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
        #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
        #expect(RDPGraphicsPathDescription.describe(report: report) == """
        RDPGFX v10.7 AVC thin-client flags=0x00000042 -> rdpgfx-wire-to-surface-2 caprogressive tiles=1 -> surface-bgra
        """.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(observed.value.frames == report.rdpGraphicsFrames)
    }

    /// ClearCodec drawn over AVC on the same surface in one frame (Windows mixed mode) follows
    /// the video as a snapshot whose regions are only what ClearCodec drew.
    @Test func clientDeliversTextDrawnOverVideoAsItsRegionOnly() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendVideoBeforeBitmapCompositionFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(observed.value.frames.map(\.codecName) == ["avc420", "surface-bgra"])
        #expect(observed.value.frames.map(\.contentKind) == [.video, .bitmap])
        #expect(observed.value.frames.last?.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 2)])
        #expect(report.error == nil)
    }

    @Test func clientEmitsEveryVideoUpdateWithinOneRDPGFXFrame() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendMultipleVideoUpdatesInFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsFirstFrame?.surfaceID == 1)
        #expect(report.rdpGraphicsFrames?.map(\.frameID) == [11])
        #expect(report.rdpGraphicsFrames?.map(\.surfaceID) == [2])
        #expect(observed.value.frames.map(\.frameID) == [11, 11])
        #expect(observed.value.frames.map(\.surfaceID) == [1, 2])
    }

    /// Two complete frames in one DVC message are each delivered and acknowledged
    /// ([MS-RDPEGFX] 3.2.5.12).
    @Test func clientDeliversAndAcknowledgesTwoFramesFromOnePayload() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendTwoFramesInOnePayload), { $0.graphicsFrameCaptureLimit = 2 }, client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(observed.value.frames.map(\.frameID) == [1, 2])
        let acknowledgedFrameIDs = try (report.rdpGraphicsFrameAcknowledgeHexes ?? []).map { hex in
            let packet = try #require(Data(rdpHexString: hex))
            // RDPGFX_FRAME_ACKNOWLEDGE_PDU ends with frameId, totalFramesDecoded.
            return packet.littleEndianUInt32(at: packet.count - 8)
        }
        #expect(acknowledgedFrameIDs == [1, 2])
    }

    @Test func clientEmitsEveryDirtyBitmapSurfaceWithinOneRDPGFXFrame() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendMultipleBitmapSurfacesInFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsFirstFrame?.surfaceID == 1)
        #expect(report.rdpGraphicsFrames?.map(\.surfaceID) == [2])
        #expect(observed.value.frames.map(\.frameID) == [12, 12])
        #expect(observed.value.frames.map(\.surfaceID) == [1, 2])
        #expect(observed.value.frames.map(\.contentKind) == [.bitmap, .bitmap])
    }

    /// Regions covering the update five times over reach the decoder as their bounding box.
    @Test func clientCollapsesVideoRegionsCoveringTheSurfaceManyTimesOver() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendVideoRegionsCoveringTheSurfaceFiveTimes), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(observed.value.frames.map(\.regionRects) == [[RDPFrameRect(left: 0, top: 0, right: 64, bottom: 32)]])
    }

    /// gnome-remote-desktop copies each damage rectangle of its staging surface to the mapped
    /// one. The mapped surface's decoder gets each frame's video with those rectangles as its
    /// regions, and nothing paints the copied areas black.
    @Test func clientRetargetsStagedVideoToItsCopiedDamageRectangles() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .copyVideoFromStagingSurfacePerDamageRect), {
            $0.graphicsFrameCaptureLimit = 2
        }, client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.frameID) == [1, 2])
        #expect(frames.map(\.surfaceID) == [1, 1])
        #expect(frames.map(\.contentKind) == [.video, .video])
        #expect(frames.map(\.regionRects) == [
            [RDPFrameRect(left: 0, top: 0, right: 64, bottom: 32)],
            [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 8), RDPFrameRect(left: 32, top: 16, right: 64, bottom: 32)],
        ])
    }

    /// Copies of decoded video, through the cache too, go to the decoder in wire order, ahead
    /// of the bitmap of what the session drew; evictions go with the next snapshot.
    @Test func clientHandsCopiesOfDecodedVideoToTheDecoderInOrder() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .copyDecodedVideoThroughSurfacesAndCache), {
            $0.graphicsFrameCaptureLimit = 3
        }, client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.frameID) == [1, 2, 2, 2, 2, 2, 3])
        #expect(frames.map(\.contentKind) == [.video, .surfaceCopy, .surfaceCopy, .surfaceCopy, .surfaceCopy, .bitmap, .video])
        #expect(frames.compactMap(\.surfaceCopy).map { [$0.source, $0.destination] } == [
            [.surface(1), .surface(1)],
            [.surface(1), .cacheSlot(3)],
            [.cacheSlot(3), .surface(1)],
            [.surface(1), .cacheSlot(4)],
        ])
        #expect(frames.map(\.evictedCacheSlots) == [[], [], [], [], [3], [4], []])
        // The text, and where the decoder's copies of it lack it.
        #expect(frames.first { $0.contentKind == .bitmap }?.regionRects == [
            RDPFrameRect(left: 0, top: 0, right: 8, bottom: 8),
            RDPFrameRect(left: 0, top: 16, right: 8, bottom: 24),
            RDPFrameRect(left: 48, top: 0, right: 56, bottom: 8),
        ])
    }

    /// Once the decoder holds an unmapped surface, because a copy it made wrote there, it
    /// gets the surface's video too, for the copies out of it.
    @Test func clientHandsVideoOfHiddenSurfacesTheDecoderHoldsToIt() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .copyVideoThroughHiddenSurface), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.contentKind) == [.video, .surfaceCopy, .video, .surfaceCopy])
        #expect(frames.map(\.surfaceID) == [1, 2, 2, 1])
        // Not mapped: the decoder keeps it and presents nothing.
        let hiddenVideo = frames.first { $0.contentKind == .video && $0.surfaceID == 2 }
        #expect(hiddenVideo?.graphicsOutputRect != nil)
        #expect(hiddenVideo?.surfaceRect == nil)
    }

    /// Copies out of a surface deleted later in the frame still copy it: the decoder forgets the
    /// surface only after them, from the next snapshot on.
    @Test func clientCopiesOutOfSurfacesBeforeDeletingThem() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .deleteSurfacesAfterCopyingOutOfThem), {
            $0.graphicsFrameCaptureLimit = 3
        }, client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.frameID) == [1, 1, 2, 3])
        #expect(frames.map(\.contentKind) == [.video, .surfaceCopy, .video, .video])
        #expect(frames.map(\.surfaceID) == [2, 1, 1, 1])
        #expect(frames.map(\.deletedSurfaceIDs) == [[], [], [2], [3]])
    }

    /// A deletion maps only the deleted surface's queued updates early; the others are mapped
    /// as the frame ends, after a mapping that came later in it.
    @Test func clientMapsUpdatesOfOtherSurfacesAtTheFrameEndAfterADeletion() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .mapSurfaceAfterDeletingAnotherInTheFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.contentKind) == [.video, .video, .surfaceCopy])
        #expect(frames.map(\.surfaceID) == [3, 2, 1])
        #expect(frames.map { $0.surfaceRect != nil } == [true, true, true])
    }

    /// A hidden surface's video goes to the decoder from a keyframe on: before one it has
    /// nothing to decode against.
    @Test func clientHandsHiddenSurfaceVideoToTheDecoderFromAKeyframeOn() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendHiddenSurfaceVideoBeforeAKeyframe), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.contentKind) == [.video, .surfaceCopy, .video, .video])
        #expect(frames.map(\.surfaceID) == [1, 2, 2, 2])
        #expect(frames.filter { $0.surfaceID == 2 && $0.contentKind == .video }.map(\.videoNalUnitTypes) == [[7, 8, 5], [1]])
    }

    /// Video the decoder drops changes nothing: a fill it covered on a hidden surface is
    /// still the session's, so a copy of it is the session's to paint, not a decoder copy
    /// of pixels the decoder never had.
    @Test func clientCopiesWhatHiddenSurfaceVideoBeforeAKeyframeLeft() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .copyOutOfHiddenSurfaceAfterVideoBeforeAKeyframe), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        let frames = observed.value.frames
        #expect(frames.map(\.contentKind) == [.video, .surfaceCopy, .bitmap])
        #expect(frames.map(\.surfaceID) == [1, 2, 1])
        let bitmap = try #require(frames.last)
        #expect(bitmap.regionRects == [RDPFrameRect(left: 32, top: 16, right: 48, bottom: 24)])
        #expect(pixel(atX: 40, y: 20, data: try #require(bitmap.decodedBitmapData), bytesPerRow: 64 * 4) == [0x01, 0x02, 0x03, 0xFF])
    }

    /// Alpha over video goes to the decoder, which has the video's colour, instead of
    /// painting the session's never decoded pixels.
    @Test func clientHandsAlphaOverVideoToTheDecoder() throws {
        let observed = Locked(Observed())
        let report = try runMock(.init(graphicsBehavior: .sendAlphaOverVideo), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { frame in
                observed.withLock { $0.frames.append(frame) }
            })
        }).report

        #expect(report.status == "success")
        #expect(observed.value.frames.map(\.contentKind) == [.video, .alpha])
        #expect(observed.value.frames.map(\.frameID) == [1, 1])
    }

    // MARK: Live sessions

    /// An empty frame is acknowledged but delivers no image; with no frame to
    /// show, the live session gives up at its receive timeout.
    @Test func liveSessionTimesOutWhenAcknowledgedGraphicsFrameHasNoImageData() throws {
        let report = try runMock(.init(graphicsBehavior: .sendEmptyFrameThenStall)) {
            $0.timeoutSeconds = 1
            $0.graphicsFrameCaptureLimit = nil
        }.report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsUpdateMessages?.map(\.typeName) == [
            "rdpgfx-create-surface",
            "rdpgfx-start-frame",
            "rdpgfx-wire-to-surface-1",
            "rdpgfx-end-frame",
        ])
        #expect(report.rdpGraphicsFrames == [])
        #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
        #expect(report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
    }

    /// A fast-path frame marker End needs its acknowledgement even when the frame changed
    /// no pixels, or the server stalls at its unacknowledged-frame limit ([MS-RDPRFX] 2.2.3.3).
    @Test func clientAcknowledgesFastPathFramesThatChangedNoPixels() throws {
        let run = try runMock(.init(graphicsBehavior: .sendFastPathEmptyFramesBeforeFirstFrame))

        #expect(run.report.status == "success")
        #expect(run.transcript.frameAcknowledgeIDs == [5, 6])
        #expect(run.report.error == nil)
    }

    /// A deleted surface's queued video is dropped, and the next snapshot names the
    /// surface so decoders do not carry its state into the one recreated with its ID.
    @Test func deletedSurfacesAreNamedOnTheNextSnapshot() throws {
        let report = try runMock(.init(graphicsBehavior: .deleteAndRecreateSurfaceInSecondFrame)) {
            $0.graphicsFrameCaptureLimit = 2
        }.report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsFrames?.map(\.deletedSurfaceIDs) == [[], [1]])
        #expect(report.rdpGraphicsFrames?.last?.frameID == 2)
    }

    @Test func clientDoesNotAcknowledgeFrameWhenGraphicsHandlerFails() throws {
        let report = try runMock(.init(graphicsBehavior: .closeAfterFirstFrame), client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { _ in
                throw MockGraphicsFrameHandlerError.failed
            })
        }).report

        #expect(report.status == "failure")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpGraphicsFrames?.isEmpty == false)
        #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
        #expect(report.error?.contains("mock graphics frame handler failed") == true)
        #expect(report.failure == .graphicsFrameHandler)
    }

    @Test func liveSessionTreatsRemoteCloseAfterFrameAsCleanDisconnect() throws {
        let run = try runMock(.init(graphicsBehavior: .closeAfterFirstFrame)) {
            $0.graphicsFrameCaptureLimit = nil
        }
        let report = run.report

        #expect(report.status == "success")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
        #expect(report.error == nil)
        // The server ended the session, so the client sends no ultimatum of its own.
        #expect(run.transcript.disconnectUltimatumReasons.isEmpty)
    }

    /// A session the client ends, at its frame target or by cancelling, says so with
    /// the Disconnect Provider Ultimatum before closing ([MS-RDPBCGR] 1.3.1.4.1).
    @Test func clientEndsItsSessionWithTheDisconnectUltimatum() throws {
        let captured = try runMock()
        #expect(captured.report.status == "success")
        #expect(captured.transcript.disconnectUltimatumReasons == [3])

        let cancellation = RDPConnectionCancellation()
        let cancelled = try runMock(.init(), { $0.graphicsFrameCaptureLimit = nil }, client: {
            RDPSessionClient().run(
                configuration: $0,
                onGraphicsFrame: { _ in cancellation.cancel() },
                cancellation: cancellation
            )
        })
        #expect(cancelled.report.error == "cancelled")
        #expect(cancelled.transcript.disconnectUltimatumReasons == [3])
    }

    /// The server ends the session while the client still handles its frame: the frame
    /// acknowledgement then meets a closed connection, which must not hide the clean end
    /// the server sent before closing.
    @Test func liveSessionEndsCleanlyWhenTheServerEndsItDuringAFrame() throws {
        let report = try runMock(.init(graphicsBehavior: .endSessionLikeGnomeAfterFirstFrame), {
            $0.graphicsFrameCaptureLimit = nil
        }, client: {
            RDPSessionClient().run(configuration: $0, onGraphicsFrame: { _ in Thread.sleep(forTimeInterval: 0.3) })
        }).report

        #expect(report.status == "success")
        #expect(report.error == nil)
        #expect(report.rdpRemoteTerminationErrorInfoName == "ERRINFO_RPC_INITIATED_DISCONNECT")
        #expect(report.rdpRemoteTerminationDisconnectReason == 3)
        #expect(report.remoteTermination?.category == .admin)
    }

    /// A close after a Set Error Info is the server ending the session for that
    /// reason ([MS-RDPBCGR] 2.2.5.1.1); another connection taking the session
    /// over ends a running session normally.
    @Test func liveSessionEndsWhenAnotherConnectionTakesItOver() throws {
        let report = try runMock(.init(graphicsBehavior: .setErrorInfoThenCloseAfterFirstFrame)) {
            $0.graphicsFrameCaptureLimit = nil
        }.report

        #expect(report.status == "success")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.rdpRemoteTerminationErrorInfo == 0x0000_0005)
        #expect(report.rdpRemoteTerminationErrorInfoName == "ERRINFO_DISCONNECTED_BY_OTHERCONNECTION")
        #expect(report.nextStage == "rdp-session-ended")
        #expect(report.error == nil)
        #expect(report.failure == nil)
        #expect(report.remoteTermination?.category == .replaced)
    }

    /// Logoff is a clean end of the session, live or while capturing frames.
    @Test(arguments: [1, nil] as [Int?])
    func clientTreatsSetErrorInfoLogoffBeforeFrameAsCleanDisconnect(captureLimit: Int?) throws {
        let report = try runMock(.init(graphicsBehavior: .setErrorInfoLogoffBeforeFrame)) {
            $0.graphicsFrameCaptureLimit = captureLimit
        }.report

        #expect(report.status == "success")
        #expect(report.stage == "rdp-graphics-dynamic-channel")
        #expect(report.nextStage == "rdp-session-ended")
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFrames == [])
        #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
        #expect(report.error == nil)
        #expect(report.failure == nil)
        #expect(report.remoteTermination?.category == .user)
    }

    // MARK: Clipboard, input, display control, device redirection and audio

    @Test func clientTransfersRemoteClipboardFileFromMockKRDPServer() throws {
        let remoteFile = RDPClipboardLocalFile(
            fileName: "notes.txt",
            contents: Data("hello from remote".utf8)
        )
        let observed = Locked(Observed())
        let report = try runMock(.init(clipboardFiles: [remoteFile]), { $0.clipboardEnabled = true }, client: {
            RDPSessionClient().run(
                configuration: $0,
                onGraphicsFrame: { frame in observed.withLock { $0.frames.append(frame) } },
                onClipboardReady: { session in observed.withLock { $0.clipboardSession = session } },
                onClipboardFileGroupDescriptor: { descriptor in
                    observed.withLock { $0.fileDescriptor = descriptor }
                    observed.recordClipboardErrors { session in
                        try session.requestRemoteFileSize(streamID: 1, fileIndex: 0)
                    }
                },
                onClipboardFileContents: { response in
                    switch response.streamID {
                    case 1:
                        observed.recordClipboardErrors { session in
                            let size = try response.decodedFileSize()
                            observed.withLock { $0.remoteFileSize = size }
                            guard let byteCount = UInt32(exactly: size) else {
                                throw MockClipboardTestError.fileTooLarge
                            }
                            try session.requestRemoteFileRange(
                                streamID: 2,
                                fileIndex: 0,
                                position: 0,
                                requestedByteCount: byteCount
                            )
                        }
                    case 2:
                        observed.withLock { $0.remoteFileData = response.data }
                    default:
                        break
                    }
                }
            )
        }).report

        let sentNames = report.rdpClipboardSentMessages?.map(\.typeName) ?? []
        let receivedNames = report.rdpClipboardMessages?.map(\.typeName) ?? []
        #expect(report.status == "success")
        #expect(report.mcsStaticChannels == [
            RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
            RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1007),
        ])
        #expect(report.rdpClipboardChannelID == 1007)
        for name in ["monitor-ready", "format-list", "format-data-response", "file-contents-response"] {
            #expect(receivedNames.contains("clipboard-\(name)"))
        }
        for name in [
            "capabilities",
            "temporary-directory",
            "format-list-response",
            "format-data-request",
            "file-contents-request",
        ] {
            #expect(sentNames.contains("clipboard-\(name)"))
        }
        #expect(observed.value.clipboardErrors.isEmpty)
        #expect(observed.value.fileDescriptor == RDPClipboardFileGroupDescriptorW(descriptors: [remoteFile.descriptor]))
        #expect(observed.value.remoteFileSize == UInt64(remoteFile.contents.count))
        #expect(observed.value.remoteFileData == remoteFile.contents)
        #expect(observed.value.frames == report.rdpGraphicsFrames)
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.error == nil)
    }

    /// After Monitor Ready the client MUST send a Format List ([MS-RDPECLIP]
    /// 3.2.5.1.2), with or without an onClipboardReady handler.
    @Test func clientAnswersClipboardMonitorReadyWithoutHandlers() throws {
        let run = try runMock(.init(remoteClipboardText: "remote")) { $0.clipboardEnabled = true }

        #expect(run.report.status == "success")
        let sent = run.transcript.clientClipboardMessages.map(\.typeName)
        #expect(Array(sent.prefix(3)) == [
            "clipboard-capabilities",
            "clipboard-temporary-directory",
            "clipboard-format-list",
        ])
        #expect(sent.contains("clipboard-format-list-response"))
    }

    /// With onClipboardContent the client asks for each format of a remote copy in
    /// turn and delivers them together; onClipboardText still gets the text.
    @Test func clientReceivesEveryFormatOfARemoteCopy() throws {
        let observed = Locked(Observed())
        let run = try runMock(
            .init(remoteClipboardText: "remote", remoteClipboardHTML: "<b>remote</b>"),
            { $0.clipboardEnabled = true },
            client: {
                RDPSessionClient().run(
                    configuration: $0,
                    onClipboardText: { text in observed.withLock { $0.clipboardTexts.append(text) } },
                    onClipboardContent: { content in observed.withLock { $0.clipboardContents.append(content) } }
                )
            }
        )

        #expect(run.report.status == "success")
        #expect(observed.value.clipboardTexts == ["remote"])
        #expect(observed.value.clipboardContents == [RDPClipboardContent(
            text: "remote",
            html: "<html><body><!--StartFragment--><b>remote</b><!--EndFragment--></body></html>"
        )])
    }

    /// The traffic a Windows server sees once a session is up: input, clipboard
    /// both ways, display control, device redirection and audio. The mock
    /// sends the first frame only after all of it arrived.
    @Test func clientVerifiesWindowsCompatibilityBehaviorsWithMockServer() throws {
        let localClipboardText = "mock_local_clip"
        // About 4 KB of UTF-16: the Format Data Response arrives as FIRST, middle and LAST chunks.
        let remoteClipboardText = String(repeating: "mock_remote_clip ", count: 120)
        let inputText = "mock_input"
        let observed = Locked(Observed())
        let run = try runMock(
            .init(remoteClipboardText: remoteClipboardText, audioEnabled: true, waitForCompatibilityTraffic: true),
            {
                $0.clipboardEnabled = true
                $0.audioPlaybackEnabled = true
            },
            client: {
                RDPSessionClient().run(
                    configuration: $0,
                    onGraphicsFrame: { frame in observed.withLock { $0.frames.append(frame) } },
                    onInputReady: { session in
                        var events: [RDPSlowPathInputEvent] = [.pointerMove(x: 640, y: 360)]
                        for codeUnit in inputText.utf16 {
                            events.append(.unicode(codeUnit: codeUnit, isReleased: false))
                            events.append(.unicode(codeUnit: codeUnit, isReleased: true))
                        }
                        session.send(events)
                    },
                    onDisplayControlReady: { session in
                        observed.withLock { $0.framesBeforeDisplayControl = $0.frames.count }
                        session.sendSingleMonitorLayout(
                            width: 1440,
                            height: 900,
                            desktopScaleFactor: 150,
                            deviceScaleFactor: 140
                        )
                    },
                    onClipboardReady: { session in session.publishLocalUnicodeText(localClipboardText) },
                    onClipboardText: { text in observed.withLock { $0.clipboardTexts.append(text) } },
                    onAudioSample: { sample in observed.withLock { $0.audioSamples.append(sample) } }
                )
            }
        )

        let report = run.report
        let transcript = run.transcript
        let clipboardSentNames = report.rdpClipboardSentMessages?.map(\.typeName) ?? []
        let clipboardReceivedNames = report.rdpClipboardMessages?.map(\.typeName) ?? []
        let audioReceivedNames = report.rdpAudioMessages?.map(\.typeName) ?? []
        let audioClientNames = transcript.audioClientMessages.map(\.typeName)
        let dynamicRequestTypes = report.rdpDynamicChannelRequestTypes ?? []
        let complete = RDPStaticVirtualChannelFlags.complete

        #expect(report.status == "success")
        #expect(report.selectedProtocols == ["tls"])
        #expect(report.mcsStaticChannels == [
            RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
            RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1007),
            RDPStaticVirtualChannelAssignment(name: "rdpdr", channelID: 1008),
            RDPStaticVirtualChannelAssignment(name: "rdpsnd", channelID: 1009),
        ])
        #expect(report.rdpClipboardChannelID == 1007)
        #expect(report.rdpAudioChannelID == 1009)
        #expect(report.rdpDisplayControlChannelID == 17)
        #expect(report.rdpDisplayControlCaps == RDPDisplayControlCapabilities(
            maxNumMonitors: 16,
            maxMonitorAreaFactorA: 8192,
            maxMonitorAreaFactorB: 8192
        ))
        #expect(dynamicRequestTypes.contains("dynvc-create-request:\(RDPDisplayControlChannel.name)"))
        #expect(dynamicRequestTypes.contains("dynvc-data:display-control"))
        #expect(dynamicRequestTypes.contains("dynvc-create-request:\(RDPAudioDynamicChannel.name)"))
        #expect(dynamicRequestTypes.contains("dynvc-data:audio"))

        // Every client DRDYNVC PDU goes out as one complete SVC chunk.
        #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
        #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
        #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
        #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
        for hex in (report.rdpGraphicsFrameAcknowledgeHexes ?? []) + [
            report.rdpDynamicChannelCapabilitiesResponseHex,
            report.rdpGraphicsChannelCreateResponseHex,
            report.rdpGraphicsCapsAdvertiseHex,
            report.rdpDisplayControlChannelCreateResponseHex,
        ] {
            #expect(try staticChannelFlags(fromTPKTHex: hex) == complete)
        }
        #expect(report.rdpGraphicsCapsAdvertiseHex?.contains(
            RDPGFXCapsAdvertisePDU(
                capabilitySets: RDPGraphicsCapabilityProfile.automatic.capabilitySets
            ).encoded().rdpHexString
        ) == true)
        #expect(transcript.dynamicCreateResponseStaticFlags.count == 2)
        #expect(transcript.dynamicCreateResponseStaticFlags.allSatisfy { $0 == complete })
        #expect(transcript.displayControlStaticFlags.isEmpty == false)
        #expect(transcript.displayControlStaticFlags.allSatisfy { $0 == complete })
        #expect(transcript.audioDynamicStaticFlags.isEmpty == false)
        #expect(transcript.audioDynamicStaticFlags.allSatisfy { $0 == complete })

        for name in ["monitor-ready", "format-list", "format-data-response"] {
            #expect(clipboardReceivedNames.contains("clipboard-\(name)"))
        }
        for name in [
            "capabilities",
            "temporary-directory",
            "format-list",
            "format-list-response",
            "format-data-request",
            "format-data-response",
        ] {
            #expect(clipboardSentNames.contains("clipboard-\(name)"))
        }
        #expect(observed.value.clipboardTexts == [remoteClipboardText])
        #expect(transcript.receivedLocalClipboardText == localClipboardText)
        #expect(transcript.clipboardStaticFlags.allSatisfy {
            $0 == RDPStaticVirtualChannelFlags.first
                | RDPStaticVirtualChannelFlags.last
                | RDPStaticVirtualChannelFlags.showProtocol
        })

        #expect(transcript.inputEvents.contains(.pointerMove(x: 640, y: 360)))
        #expect(transcript.inputEvents.filter {
            if case .unicode = $0 { true } else { false }
        }.count == inputText.utf16.count * 2)

        // KRdp ignores a layout sent before its video stream starts.
        #expect(observed.withLock(\.framesBeforeDisplayControl) == 1)
        #expect(transcript.displayControlLayouts == [
            MockDisplayControlLayoutSummary(
                monitorCount: 1,
                primaryWidth: 1440,
                primaryHeight: 900,
                primaryDesktopScaleFactor: 150,
                primaryDeviceScaleFactor: 140
            ),
        ])
        for name in ["client-id-confirm", "client-name", "client-capability", "device-list-announce"] {
            #expect(transcript.deviceRedirectionClientMessages.contains("rdpdr-\(name)"))
        }

        for name in ["formats", "training", "wave2"] {
            #expect(audioReceivedNames.contains("audio-\(name)"))
        }
        for name in ["formats", "quality-mode", "training", "wave-confirm"] {
            #expect(audioClientNames.contains("audio-\(name)"))
        }
        #expect(observed.value.audioSamples.count == 1)
        #expect(observed.value.audioSamples.first?.format == .pcmStereo48k16Bit)
        #expect(observed.value.audioSamples.first?.data == Data([0x11, 0x22, 0x33, 0x44]))
        #expect(report.error == nil)
    }
}

// MARK: Helpers

private let mockCredentials = RDPCredentials(username: "rdp-user", password: "secret")

private struct MockRun {
    var report: RDPConnectionReport
    var transcript: MockKRDPServerTranscript
    var connectionCount: Int
}

/// Starts a mock server with `options`, runs `client` against it with the
/// usual test configuration (changed by `configure`) and returns the client's
/// report and what the server received.
private func runMock(
    _ options: MockKRDPServer.Options = .init(),
    _ configure: (inout RDPConnectionConfiguration) -> Void = { _ in },
    client: (RDPConnectionConfiguration) -> RDPConnectionReport = { RDPSessionClient().run(configuration: $0) }
) throws -> MockRun {
    let server = try MockKRDPServer(options)
    defer { server.stop() }

    var configuration = RDPConnectionConfiguration(
        host: "127.0.0.1",
        port: server.port,
        credentials: mockCredentials,
        timeoutSeconds: 5,
        hideCertificateWarnings: true,
        clipboardEnabled: false
    )
    configure(&configuration)
    let report = client(configuration)
    server.waitForClientsToClose()
    return MockRun(report: report, transcript: server.transcript.value, connectionCount: server.connectionCount)
}

/// What the client's callbacks delivered.
private struct Observed {
    var frames: [RDPGraphicsFrameSnapshot] = []
    var wireBytes = 0
    var clipboardSession: RDPClipboardSession?
    var fileDescriptor: RDPClipboardFileGroupDescriptorW?
    var remoteFileSize: UInt64?
    var remoteFileData: Data?
    var clipboardTexts: [String] = []
    var clipboardContents: [RDPClipboardContent] = []
    var clipboardErrors: [String] = []
    var framesBeforeDisplayControl: Int?
    var audioSamples: [RDPAudioSample] = []
}

private extension Locked where Value == Observed {
    /// Runs a clipboard request with the session from onClipboardReady and
    /// records any error.
    func recordClipboardErrors(_ request: (RDPClipboardSession) throws -> Void) {
        do {
            guard let session = value.clipboardSession else {
                throw MockClipboardTestError.sessionNotReady
            }
            try request(session)
        } catch {
            withLock { $0.clipboardErrors.append(String(describing: error)) }
        }
    }
}

private enum MockClipboardTestError: Error {
    case sessionNotReady
    case fileTooLarge
}

private enum MockGraphicsFrameHandlerError: Error, CustomStringConvertible {
    case failed

    var description: String {
        "mock graphics frame handler failed"
    }
}

private func clientCoreData(fromMCSConnectInitialHex hex: String?) throws -> Data {
    let data = try #require(hex.flatMap(Data.init(rdpHexString:)))
    let marker = Data([0x01, 0xC0, 0xEA, 0x00])
    let range = try #require(data.range(of: marker))
    let end = try #require(data.index(range.lowerBound, offsetBy: 234, limitedBy: data.endIndex))
    return data.subdata(in: range.lowerBound ..< end)
}

/// The channel flags of a client PDU on the drdynvc channel (1004).
private func staticChannelFlags(fromTPKTHex hex: String?) throws -> UInt32 {
    let request = try mcsSendDataRequest(fromTPKT: #require(hex.flatMap(Data.init(rdpHexString:))))
    #expect(request.channelID == 1004)
    return try RDPStaticVirtualChannelPDU.parse(
        fromUserData: request.userData,
        maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
    ).flags
}
