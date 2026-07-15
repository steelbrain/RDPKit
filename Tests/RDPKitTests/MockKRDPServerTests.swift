import Foundation
@testable import RDPKit
import Testing

@Suite(.serialized)
struct MockKRDPServerTests {
@Test func preflightReportsNegotiationFailureAsFailure() throws {
    let server = try MockKRDPServer.start(securityProtocol: .failure(code: 0x0000_0002))
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "x224-rdp-negotiation")
    #expect(report.failureCode == 0x0000_0002)
    #expect(report.selectedProtocols == nil)
    #expect(report.error == "RDP negotiation failed with code 0x00000002")
}

@Test func preflightReportsStandardSecurityAsUnsupported() throws {
    let server = try MockKRDPServer.start(securityProtocol: .standard)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "x224-rdp-negotiation")
    #expect(report.selectedProtocols == ["standard-rdp-security"])
    #expect(report.nextStage == nil)
    #expect(report.error == "standard RDP security is not supported")
}

@Test func preflightRejectsUnrequestedSecurityProtocolSelection() throws {
    let server = try MockKRDPServer.start(securityProtocol: .rdSTLS)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "x224-rdp-negotiation")
    #expect(report.requestedProtocols == ["tls", "credssp"])
    #expect(report.selectedProtocols == ["rdstls"])
    #expect(report.nextStage == nil)
    #expect(report.error == "server selected an unrequested security protocol")
}

@Test func preflightCapturesGraphicsFrameFromMockKRDPServer() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        },
        onWireReceive: { sample in
            observed.record(sample)
        }
    )

    #expect(report.status == "success")
    #expect(report.selectedProtocols == ["tls"])
    #expect(report.mcsIOChannelID == 1003)
    #expect(report.mcsMessageChannelID == 1005)
    #expect(report.mcsStaticChannels == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
    #expect(report.rdpLicensingResponseType == "license-error-valid-client")
    #expect(report.rdpPostConfirmActiveResponseType == "server-synchronize")
    #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("surface-commands") == true)
    #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("bitmap-codecs") == true)
    #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("frame-acknowledge") == true)
    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsCapsAdvertiseHex?.contains(RDPGFXCapsAdvertisePDU().encoded().rdpHexString) == true)
    #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version81)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.width == 64)
    #expect(report.rdpGraphicsFirstFrame?.height == 32)
    #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
    #expect(report.rdpGraphicsFirstFrame?.h264NalUnitTypes == [7, 8, 5])
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(observed.wireBytes > 0)
    #expect(report.error == nil)
}

@Test func preflightResolvesPointerCacheUpdatesFromMockKRDPServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendPointerUpdatesBeforeFirstFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            clipboardEnabled: false
        ),
        onRemotePointer: { update in
            observed.record(update)
        }
    )

    let image = RDPRemotePointerImage(
        cacheIndex: 2,
        hotSpot: RDPRemotePoint(x: 1, y: 3),
        width: 1,
        height: 1,
        xorBitsPerPixel: 24,
        xorMaskData: Data([0xaa, 0xbb, 0xcc, 0x00]),
        andMaskData: Data([0xff, 0x00])
    )
    #expect(report.status == "success")
    #expect(observed.pointerUpdates == [.image(image), .cachedImage(image)])
    #expect(report.error == nil)
}

@Test func preflightPassesKRDPServerThatRequiresBitmapCodecsCapability() throws {
    let server = try MockKRDPServer.start(requireBitmapCodecsCapability: true)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpConfirmActiveCapabilitySets?.map(\.name).contains("bitmap-codecs") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightSkipsMCSChannelJoinWhenServerAdvertisesSupport() throws {
    let server = try MockKRDPServer.start(skipChannelJoinSupported: true)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            clipboardEnabled: false
        )
    )

    let joinedChannels = try #require(report.mcsJoinedChannels)
    #expect(report.status == "success")
    #expect(joinedChannels.map(\.name) == ["user", "io", "drdynvc", "message"])
    #expect(joinedChannels.allSatisfy { $0.result == "rt-successful" })
    #expect(joinedChannels.allSatisfy { $0.requestHex.isEmpty })
    #expect(joinedChannels.allSatisfy { $0.confirmHex.isEmpty })
}

@Test func preflightExplicitlyJoinsMCSChannelsWhenServerDoesNotAdvertiseSkip() throws {
    let server = try MockKRDPServer.start(skipChannelJoinSupported: false)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            clipboardEnabled: false
        )
    )

    let joinedChannels = try #require(report.mcsJoinedChannels)
    #expect(report.status == "success")
    #expect(joinedChannels.map(\.name) == ["user", "io", "drdynvc", "message"])
    #expect(joinedChannels.allSatisfy { $0.result == "rt-successful" })
    #expect(joinedChannels.allSatisfy { $0.requestHex.isEmpty == false })
    #expect(joinedChannels.allSatisfy { $0.confirmHex.isEmpty == false })
}

@Test func preflightConnectInitialCarriesKRDPCompatibleClientCoreData() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    let core = try clientCoreData(fromMCSConnectInitialHex: report.mcsConnectInitialHex)
    let earlyCapabilityFlags = littleEndianUInt16(in: core, at: 144)

    #expect(core.count == 234)
    #expect(core.prefix(4) == Data([0x01, 0xC0, 0xEA, 0x00]))
    #expect(earlyCapabilityFlags == 0x01AF)
    #expect(earlyCapabilityFlags & 0x0040 == 0)
    #expect(earlyCapabilityFlags & 0x0800 == 0)
    #expect(core[210] == 0x07)
    #expect(littleEndianUInt32(in: core, at: 212) == RDPSecurityProtocols.tls.rawValue)
    #expect(littleEndianUInt32(in: core, at: 216) == 0)
    #expect(littleEndianUInt32(in: core, at: 220) == 0)
    #expect(littleEndianUInt16(in: core, at: 224) == 0)
    #expect(littleEndianUInt32(in: core, at: 226) == 100)
    #expect(littleEndianUInt32(in: core, at: 230) == 100)
}

@Test func preflightAcceptsWindowsAuxiliaryDynamicChannelsBeforeGraphics() throws {
    let server = try MockKRDPServer.start(
        auxiliaryDynamicChannelBehavior: .windowsInputAndCursor
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    let dynamicRequestTypes = report.rdpDynamicChannelRequestTypes ?? []
    let audioInputClientNames = server.transcript.snapshot.audioInputClientMessages
    #expect(report.status == "success")
    #expect(dynamicRequestTypes.contains(
        "dynvc-create-request:\(RDPWindowsAuxiliaryDynamicChannel.inputName)"
    ))
    #expect(dynamicRequestTypes.contains(
        "dynvc-create-request:\(RDPWindowsAuxiliaryDynamicChannel.coreInputName)"
    ))
    #expect(dynamicRequestTypes.contains(
        "dynvc-create-request:\(RDPWindowsAuxiliaryDynamicChannel.audioInputName)"
    ))
    #expect(dynamicRequestTypes.contains(
        "dynvc-create-request:\(RDPWindowsAuxiliaryDynamicChannel.mouseCursorName)"
    ))
    #expect(dynamicRequestTypes.contains("dynvc-data:rdpei-sc-ready"))
    #expect(dynamicRequestTypes.contains("dynvc-data:rdpei-suspend-input"))
    #expect(dynamicRequestTypes.contains("dynvc-data:rdpei-resume-input"))
    #expect(dynamicRequestTypes.contains("dynvc-data:audio-input-version"))
    #expect(dynamicRequestTypes.contains("dynvc-data:audio-input-formats"))
    #expect(dynamicRequestTypes.contains("dynvc-data:audio-input-open"))
    #expect(audioInputClientNames == [
        "audio-input-version",
        "audio-input-data-incoming",
        "audio-input-formats",
        "audio-input-format-change",
        "audio-input-open-reply",
    ])
    #expect(dynamicRequestTypes.contains("dynvc-close"))
    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightCapsDynamicVirtualChannelResponseAtWindowsVersionThree() throws {
    let server = try MockKRDPServer.start(dynamicChannelVersion: 3)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelCapabilitiesVersion == 3)
    #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 03 00") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightAcceptsFragmentedStaticDynamicChannelCreateRequest() throws {
    let server = try MockKRDPServer.start(
        auxiliaryDynamicChannelBehavior: .fragmentedGraphicsCreate
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightFollowsServerRedirectionAndReconnects() throws {
    let server = try MockKRDPServer.start(redirectionBehavior: .redirectFirstConnection)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

    // The first connection is redirected mid graphics handshake; the client must
    // reconnect (carrying the routing token) and complete on the second attempt.
    #expect(server.connectionCount == 2)
    #expect(report.status == "success")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightHandlesMultiStepBandwidthAutoDetectBeforeActivation() throws {
    let server = try MockKRDPServer.start(autoDetectBehavior: .bandwidthMeasure)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

    #expect(report.status == "success")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpAutoDetectRequestType == "connect-time-rtt-measure-request")
    #expect(report.rdpLicensingResponseType == "license-error-valid-client")
    #expect(report.rdpPostLicensingResponseType == "server-demand-active")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(report.error == nil)
}

@Test func preflightActivatesWhenDemandActiveArrivesWithoutLicensingPDU() throws {
    let server = try MockKRDPServer.start(licensingBehavior: .demandActiveOnly)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

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

@Test func preflightRespondsToServerLicenseRequest() throws {
    let server = try MockKRDPServer.start(licensingBehavior: .serverLicenseRequest)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpLicensingResponseType == "license-request")
    #expect(report.rdpPostLicensingResponseType == "server-demand-active")
    #expect(report.rdpConfirmActiveRequestHex != nil)
    #expect(report.error == nil)
}

@Test func preflightSendsClientLicenseInformationForMatchingStoredLicense() throws {
    let server = try MockKRDPServer.start(licensingBehavior: .serverLicenseRequestWithStoredClientLicense)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            storedClientLicense: RDPStoredClientLicense(
                version: 0x0006_0001,
                scope: "localhost",
                companyName: "Microsoft Corporation",
                productID: "A02",
                licenseInfo: Data([0x30, 0x82, 0x01, 0x02])
            )
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpLicensingResponseType == "license-request")
    #expect(report.rdpPostLicensingResponseType == "server-demand-active")
    #expect(report.rdpConfirmActiveRequestHex != nil)
    #expect(report.error == nil)
}

@Test func preflightRespondsToX509ServerLicenseRequest() throws {
    let server = try MockKRDPServer.start(licensingBehavior: .serverLicenseRequestX509)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpLicensingResponseType == "license-request")
    #expect(report.rdpPostLicensingResponseType == "server-demand-active")
    #expect(report.rdpConfirmActiveRequestHex != nil)
    #expect(report.error == nil)
}

@Test func preflightSendsFontListBeforeWaitingForControlGranted() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .waitForFontListBeforeGrant)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightContinuesWhenShareDataArrivesBeforeServerSynchronize() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .saveSessionInfoBeforeSynchronize)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpPostConfirmActiveResponseType == "save-session-info")
    #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightCompletesFinalizationWhenServerSynchronizeArrivesAfterConfirmActive() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }
    let transcript = RDPWireTranscript()

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        wireTranscript: transcript
    )

    #expect(report.status == "success")
    // [MS-RDPBCGR] 1.3.1.1: client finalization PDUs have no dependency on server PDUs,
    // so the client may send its batch immediately. Server Synchronize/Cooperate are
    // still collected (buffered) and reported.
    #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("control-cooperate") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)

    let events = transcript.events
    let confirmActiveByteCount = try #require(report.rdpConfirmActiveRequestHex.flatMap { Data(rdpHexString: $0)?.count })
    let confirmActiveIndex = try #require(events.firstIndex {
        $0.direction == .clientToServer
            && $0.layer == .application
            && $0.byteCount == confirmActiveByteCount
    })
    let serverSynchronizeIndex = try #require(events[(confirmActiveIndex + 1)...].firstIndex {
        guard $0.direction == .serverToClient,
              $0.layer == .application,
              let bytes = $0.bytes,
              let shareData = try? RDPShareDataPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return shareData.typeName == "server-synchronize"
    })
    let serverControlCooperateIndex = try #require(events[(confirmActiveIndex + 1)...].firstIndex {
        guard $0.direction == .serverToClient,
              $0.layer == .application,
              let bytes = $0.bytes,
              let shareData = try? RDPShareDataPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return shareData.typeName == "control-cooperate"
    })
    let fontMapIndex = try #require(events[(confirmActiveIndex + 1)...].firstIndex {
        guard $0.direction == .serverToClient,
              $0.layer == .application,
              let bytes = $0.bytes,
              let shareData = try? RDPShareDataPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return shareData.typeName == "font-map"
    })
    #expect(serverSynchronizeIndex < fontMapIndex)
    #expect(serverControlCooperateIndex < fontMapIndex)
}

@Test func preflightCompletesWhenServerWaitsForClientSynchronizeBeforeServerSynchronize() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .waitForClientSynchronizeBeforeServerSynchronize)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("control-cooperate") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightCompletesWhenServerControlCooperateArrivesBeforeSynchronize() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .controlCooperateBeforeSynchronize)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.prefix(2) == ["control-cooperate", "server-synchronize"])
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightContinuesWhenMonitorLayoutArrivesBeforeServerSynchronize() throws {
    let server = try MockKRDPServer.start(licensingBehavior: .validClientThenDemandActiveWithMonitorLayout)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpPostConfirmActiveResponseType == "monitor-layout")
    #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightRequiresFontMapBeforeGraphicsHandshake() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .grantControlWithoutFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-connection-finalization")
    #expect(report.rdpFinalizationResponseTypes?.contains("control-granted-control") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == false)
    #expect(report.rdpGraphicsChannelName == nil)
    #expect(report.error == "server did not send Font Map during connection finalization")
}

@Test func preflightReportsServerDeactivateBeforeGraphicsAsDisconnect() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .deactivateAfterFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpDynamicChannelRequestTypes == [])
    #expect(report.error == "server deactivated the session before opening RDPGFX dynamic channel")
}

@Test func preflightRejectsSetErrorInfoLogoffBeforeGraphics() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .setErrorInfoLogoffThenDeactivateAfterFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

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

@Test func preflightRejectsNonCleanSetErrorInfoBeforeGraphics() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .setErrorInfoDeniedThenDeactivateAfterFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpDynamicChannelRequestTypes == [])
    #expect(report.error == "server ended the session with ERRINFO_0x00000007 before opening RDPGFX dynamic channel")
}

@Test func preflightRejectsDeactivateThenUserRequestedDisconnectBeforeGraphics() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .deactivateThenUserRequestedDisconnectAfterFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

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

@Test func preflightRejectsUserRequestedDisconnectBeforeGraphics() throws {
    let server = try MockKRDPServer.start(finalizationBehavior: .userRequestedDisconnectAfterFontMap)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.nextStage == nil)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpDynamicChannelRequestTypes == [])
    #expect(report.rdpRemoteTerminationDisconnectReason == 3)
    #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
    #expect(report.error == "server ended the session with rn-user-requested before opening RDPGFX dynamic channel")
}

@Test func preflightAdvertisesGraphicsProfilesToMockServer() throws {
    let cases: [(profile: RDPGraphicsCapabilityProfile, selectedVersion: UInt32, selectedFlags: UInt32)] = [
        (.automatic, RDPGFXCapabilityVersion.version107, RDPGFXCapabilityFlags.defaultVersion107),
        (.avcThinClient, RDPGFXCapabilityVersion.version107, RDPGFXCapabilityFlags.defaultVersion107),
        (.avc420, RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.defaultVersion81),
        (.legacy, RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.defaultVersion8),
    ]

    for testCase in cases {
        let server = try MockKRDPServer.start(graphicsCapabilitySelection: .firstAdvertised)
        defer { server.stop() }

        let report = RDPPreflightClient().run(
            configuration: RDPConnectionConfiguration(
                host: "127.0.0.1",
                port: server.port,
                credentials: RDPCredentials(username: "rdp-user", password: "secret"),
                timeoutSeconds: 5,
                hideCertificateWarnings: true,
                graphicsFrameCaptureLimit: 1,
                desktopWidth: 1280,
                desktopHeight: 720,
                clipboardEnabled: false,
                graphicsCapabilityProfile: testCase.profile
            )
        )

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

@Test func preflightAcceptsAdvertisedIntermediateGraphicsCapabilityConfirm() throws {
    let server = try MockKRDPServer.start(graphicsCapabilitySelection: .version10)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version10)
    #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
    #expect(report.rdpGraphicsFirstFrame != nil)
    #expect(report.error == nil)
}

@Test func preflightAcceptsGraphicsCapabilityConfirmWithDifferentValidFlags() throws {
    let server = try MockKRDPServer.start(graphicsCapabilitySelection: .firstAdvertisedDifferentFlags)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version107)
    #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
    #expect(report.rdpGraphicsFirstFrame != nil)
    #expect(report.error == nil)
}

@Test func preflightRejectsKnownUnadvertisedGraphicsCapabilityConfirm() throws {
    let server = try MockKRDPServer.start(graphicsCapabilitySelection: .version10)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            graphicsCapabilityProfile: .legacy
        )
    )

    #expect(report.status == "failure")
    #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version10)
    #expect(report.rdpGraphicsSelectedCapabilityFlags == RDPGFXCapabilityFlags.smallCache)
    #expect(report.rdpGraphicsFirstFrame == nil)
    #expect(report.error == "server confirmed an RDPGFX capability version that the client did not advertise")
}

@Test func preflightAcceptsCompressedDataFirstGraphicsCapsConfirm() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendCompressedCapsConfirmFirstFrame,
        dynamicChannelVersion: 3
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 03 00") == true)
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightRejectsCompressedGraphicsCapsConfirmWithoutVersion3() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendCompressedCapsConfirmFirstFrame,
        dynamicChannelVersion: 2
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpDynamicChannelCapabilitiesVersion == 2)
    #expect(report.rdpDynamicChannelCapabilitiesResponseHex?.contains("50 00 02 00") == true)
    #expect(report.rdpGraphicsResponseType == nil)
    #expect(report.error == "invalid RDP Dynamic Virtual Channel PDU")
}

@Test func preflightAcceptsFragmentedMixedCompressedGraphicsCapsConfirm() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendFragmentedCompressedCapsConfirmFirstFrame,
        dynamicChannelVersion: 3
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightReportsIncompleteFragmentedGraphicsCapsConfirm() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .stallAfterFragmentedCapsConfirm,
        dynamicChannelVersion: 3
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-data-first-compressed") == true)
    #expect(report.rdpGraphicsResponseType == nil)
    #expect(report.error == "server did not complete fragmented RDPGFX capabilities data")
}

@Test func preflightReportsFailingGraphicsUpdateFromMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendInvalidGraphicsPDU)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsFailureUpdateResponseHex != nil)
    #expect(report.rdpGraphicsFailureUpdatePayloadHex == "12 00 00")
    #expect(report.rdpGraphicsFailureUpdateMessages == [])
    #expect(report.rdpGraphicsFailureUpdateMessageIndex == nil)
    #expect(report.error == "invalid RDP Graphics Pipeline PDU")
}

@Test func preflightRejectsMalformedAVCFrameFromMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendMalformedAVCFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

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

@Test func preflightDecodesCompressedDynamicVirtualChannelGraphicsData() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendCompressedCAVideoRemoteFXFrame,
        dynamicChannelVersion: 3
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelCapabilitiesVersion == 3)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "surface-bgra")
    #expect(report.rdpGraphicsUpdateMessages?.contains(where: { $0.codecName == "cavideo" }) == true)
    #expect(report.error == nil)
}

@Test func preflightRejectsUnsupportedCompressedDynamicVirtualChannelData() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendUnsupportedCompressedDynamicData,
        dynamicChannelVersion: 3
    )
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.error == "invalid RDP Dynamic Virtual Channel PDU")
}

@Test func preflightIgnoresDynamicVirtualChannelSoftSyncRequest() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendSoftSyncBeforeFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-soft-sync-request") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightIgnoresUnknownDynamicVirtualChannelClose() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendUnknownCloseBeforeFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.rdpDynamicChannelRequestTypes?.contains("dynvc-close") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightVerifiesFragmentedBitmapGraphicsWithMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendFragmentedBitmapCompositionFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 1,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 3,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

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
    #expect(frame.regionRects.contains(RDPFrameRect(left: 12, top: 22, right: 14, bottom: 24)))
    #expect(frame.regionRects.contains(RDPFrameRect(left: 11, top: 21, right: 13, bottom: 22)))
    #expect(frame.decodedBitmapBytesPerRow == 16)
    #expect(mockPixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 16) == [0x09, 0x08, 0x07, 0xFF])
    #expect(mockPixel(atX: 2, y: 2, data: bitmapData, bytesPerRow: 16) == [0x01, 0x02, 0x03, 0xFF])
    #expect(mockPixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 16) == [0x10, 0x20, 0x30, 0xFF])
    #expect(mockPixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 16) == [0x40, 0x50, 0x60, 0xFF])
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(report.error == nil)
}

@Test func preflightDecodesClearCodecBandsFrameFromMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendClearCodecBandsFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

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
    #expect(mockPixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
    #expect(mockPixel(atX: 1, y: 0, data: bitmapData, bytesPerRow: 8) == [0x70, 0x80, 0x90, 0xFF])
    #expect(mockPixel(atX: 0, y: 1, data: bitmapData, bytesPerRow: 8) == [0x10, 0x20, 0x30, 0xFF])
    #expect(mockPixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
    #expect(mockPixel(atX: 0, y: 2, data: bitmapData, bytesPerRow: 8) == [0x40, 0x50, 0x60, 0xFF])
    #expect(mockPixel(atX: 1, y: 2, data: bitmapData, bytesPerRow: 8) == [0x00, 0x00, 0x00, 0xFF])
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(report.error == nil)
}

@Test func preflightDecodesCAVideoRemoteFXProfilesFromMockServer() throws {
    let cases: [(profile: RDPGraphicsCapabilityProfile, selectedVersion: UInt32, selectedFlags: UInt32)] = [
        (.avc420, RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.defaultVersion81),
        (.legacy, RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.defaultVersion8),
    ]

    for testCase in cases {
        let server = try MockKRDPServer.start(
            graphicsBehavior: .sendCAVideoRemoteFXFrame,
            graphicsCapabilitySelection: .firstAdvertised
        )
        defer { server.stop() }

        let observed = MockKRDPObservedEvents()
        let report = RDPPreflightClient().run(
            configuration: RDPConnectionConfiguration(
                host: "127.0.0.1",
                port: server.port,
                credentials: RDPCredentials(username: "rdp-user", password: "secret"),
                timeoutSeconds: 5,
                hideCertificateWarnings: true,
                graphicsFrameCaptureLimit: 1,
                desktopWidth: 1280,
                desktopHeight: 720,
                clipboardEnabled: false,
                graphicsCapabilityProfile: testCase.profile
            ),
            onGraphicsFrame: { frame in
                observed.record(frame)
            }
        )

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
        #expect(mockPixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
        #expect(mockPixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
        #expect(RDPGraphicsPathDescription.describe(report: report).contains("cavideo remotefx"))
        #expect(observed.frames == report.rdpGraphicsFrames)
        #expect(report.error == nil)
    }
}

@Test func preflightDecodesGnomeRemoteDesktopCAPROGRESSIVEFrameFromMockServer() throws {
    let server = try MockKRDPServer.start(
        graphicsBehavior: .sendGnomeRemoteDesktopCAPROGRESSIVEFrame,
        graphicsCapabilitySelection: .firstAdvertised
    )
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            graphicsCapabilityProfile: .automatic
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

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
    #expect(mockPixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(mockPixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(RDPGraphicsPathDescription.describe(report: report) == """
    RDPGFX v10.7 AVC thin-client flags=0x00000042 -> rdpgfx-wire-to-surface-2 caprogressive tiles=1 -> surface-bgra
    """.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(observed.frames == report.rdpGraphicsFrames)
}

@Test func preflightDoesNotReplaceAVCFrameWithIncompleteSurfaceFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendVideoBeforeBitmapCompositionFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsFrames?.map(\.codecName) == ["avc420"])
    #expect(report.rdpGraphicsFrames?.map(\.contentKind) == [.video])
    #expect(observed.frames.map(\.codecName) == ["avc420"])
    #expect(observed.frames.map(\.contentKind) == [.video])
    #expect(report.error == nil)
}

@Test func preflightEmitsEveryVideoUpdateWithinOneRDPGFXFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendMultipleVideoUpdatesInFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsFirstFrame?.surfaceID == 1)
    #expect(report.rdpGraphicsFrames?.map(\.frameID) == [11])
    #expect(report.rdpGraphicsFrames?.map(\.surfaceID) == [2])
    #expect(observed.frames.map(\.frameID) == [11, 11])
    #expect(observed.frames.map(\.surfaceID) == [1, 2])
}

@Test func preflightEmitsEveryDirtyBitmapSurfaceWithinOneRDPGFXFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendMultipleBitmapSurfacesInFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        }
    )

    #expect(report.status == "success")
    #expect(report.rdpGraphicsFirstFrame?.surfaceID == 1)
    #expect(report.rdpGraphicsFrames?.map(\.surfaceID) == [2])
    #expect(observed.frames.map(\.frameID) == [12, 12])
    #expect(observed.frames.map(\.surfaceID) == [1, 2])
    #expect(observed.frames.map(\.contentKind) == [.bitmap, .bitmap])
}

@Test func preflightCallsCertificateHandlerAfterTLSHandshake() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let capture = RDPTestCertificateCapture()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: false,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onCertificate: { certificate in
            capture.record(certificate)
        }
    )

    let certificate = try #require(capture.certificate)
    #expect(report.status == "success")
    #expect(certificate.trusted == report.certificateTrusted)
    #expect(certificate.sha256 == report.certificateSHA256)
    #expect(certificate.warnings == report.warnings)
    #expect(certificate.trusted == false)
    #expect(certificate.sha256?.isEmpty == false)
    #expect(certificate.warnings.first?.code == "unrecognized-certificate")
}

@Test func preflightVerifiesCredSSPAuthenticationWithMockServer() throws {
    let credentials = RDPCredentials(username: "rdp-user", password: "secret")
    let server = try MockKRDPServer.start(securityProtocol: .credSSP(credentials: credentials))
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: credentials,
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    let transcript = server.transcript.snapshot
    #expect(report.status == "success")
    #expect(report.selectedProtocols == ["credssp"])
    #expect(transcript.credSSPMessages == ["ntlm-negotiate", "ntlm-authenticate", "credentials"])
    #expect(transcript.credSSPGates == [
        "raw-ntlm-negotiate-token",
        "initial-client-nonce",
        "authenticate-client-nonce",
        "raw-ntlm-authenticate-token",
        "ntlm-channel-bindings",
        "nonce-bound-pubkeyauth",
        "credentials-client-nonce",
    ])
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightConsumesSuccessfulEarlyUserAuthorizationResult() throws {
    let credentials = RDPCredentials(username: "rdp-user", password: "secret")
    let server = try MockKRDPServer.start(securityProtocol: .credSSPWithEarlyUserAuth(
        credentials: credentials,
        authorizationResult: .success
    ))
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: credentials,
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            earlyUserAuthorizationEnabled: true
        )
    )

    #expect(report.status == "success")
    #expect(report.selectedProtocols == ["credssp-early-user-auth"])
    #expect(report.earlyUserAuthorizationResult == 0x0000_0000)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightFailsWhenEarlyUserAuthorizationDeniesAccess() throws {
    let credentials = RDPCredentials(username: "rdp-user", password: "secret")
    let server = try MockKRDPServer.start(securityProtocol: .credSSPWithEarlyUserAuth(
        credentials: credentials,
        authorizationResult: .accessDenied
    ))
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: credentials,
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            earlyUserAuthorizationEnabled: true
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "tls-upgrade")
    #expect(report.selectedProtocols == ["credssp-early-user-auth"])
    #expect(report.earlyUserAuthorizationResult == nil)
    #expect(report.error == "early user authorization denied access")
}

@Test func livePreflightTimesOutWhenGraphicsPipelineStallsBeforeFirstFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .stallAfterCapsConfirm)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 1,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFrames == [])
    #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
    #expect(report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
}

@Test func livePreflightTimesOutWhenAcknowledgedGraphicsFrameHasNoImageData() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendEmptyFrameThenStall)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 1,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

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

@Test func preflightDoesNotAcknowledgeFrameWhenGraphicsHandlerFails() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .closeAfterFirstFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { _ in
            throw MockGraphicsFrameHandlerError.failed
        }
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsFrames?.isEmpty == false)
    #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
    #expect(report.error?.contains("mock graphics frame handler failed") == true)
}

@Test func livePreflightTreatsRemoteCloseAfterFrameAsCleanDisconnect() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .closeAfterFirstFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
    #expect(report.error == nil)
}

private enum MockGraphicsFrameHandlerError: Error, CustomStringConvertible {
    case failed

    var description: String {
        "mock graphics frame handler failed"
    }
}

@Test func livePreflightTreatsSetErrorInfoLogoffBeforeFrameAsCleanDisconnect() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .setErrorInfoLogoffBeforeFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.nextStage == "rdp-session-ended")
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFrames == [])
    #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
    #expect(report.error == nil)
}

@Test func preflightTransfersRemoteClipboardFileFromMockKRDPServer() throws {
    let remoteFile = RDPClipboardLocalFile(
        fileName: "notes.txt",
        contents: Data("hello from remote".utf8)
    )
    let server = try MockKRDPServer.start(clipboardFiles: [remoteFile])
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: true
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        },
        onClipboardReady: { session in
            observed.record(session)
        },
        onClipboardFileGroupDescriptor: { descriptor in
            observed.record(descriptor)
            guard let session = observed.clipboardSession else {
                observed.recordClipboardError("clipboard session was not ready")
                return
            }
            do {
                try session.requestRemoteFileSize(streamID: 1, fileIndex: 0)
            } catch {
                observed.recordClipboardError(String(describing: error))
            }
        },
        onClipboardFileContents: { response in
            if response.streamID == 1 {
                do {
                    let size = try response.decodedFileSize()
                    observed.recordRemoteFileSize(size)
                    guard let byteCount = UInt32(exactly: size) else {
                        observed.recordClipboardError("remote file size exceeded UInt32")
                        return
                    }
                    guard let session = observed.clipboardSession else {
                        observed.recordClipboardError("clipboard session was not ready")
                        return
                    }
                    try session.requestRemoteFileRange(
                        streamID: 2,
                        fileIndex: 0,
                        position: 0,
                        requestedByteCount: byteCount
                    )
                } catch {
                    observed.recordClipboardError(String(describing: error))
                }
            } else if response.streamID == 2 {
                observed.recordRemoteFileData(response.data)
            }
        },
        onWireReceive: { sample in
            observed.record(sample)
        }
    )

    #expect(report.status == "success")
    #expect(report.mcsStaticChannels == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1007),
    ])
    #expect(report.rdpClipboardChannelID == 1007)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-monitor-ready") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-format-list") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-format-data-response") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-file-contents-response") == true)
    #expect(report.rdpClipboardSentMessages?.map(\.typeName).contains("clipboard-capabilities") == true)
    #expect(report.rdpClipboardSentMessages?.map(\.typeName).contains("clipboard-temporary-directory") == true)
    #expect(report.rdpClipboardSentMessages?.map(\.typeName).contains("clipboard-format-list-response") == true)
    #expect(report.rdpClipboardSentMessages?.map(\.typeName).contains("clipboard-format-data-request") == true)
    #expect(report.rdpClipboardSentMessages?.map(\.typeName).contains("clipboard-file-contents-request") == true)
    #expect(observed.clipboardErrors.isEmpty)
    #expect(observed.fileDescriptor == RDPClipboardFileGroupDescriptorW(descriptors: [remoteFile.descriptor]))
    #expect(observed.remoteFileSize == UInt64(remoteFile.contents.count))
    #expect(observed.remoteFileData == remoteFile.contents)
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func preflightVerifiesWindowsCompatibilityBehaviorsWithMockServer() throws {
    let localClipboardText = "mock_local_clip"
    let remoteClipboardText = "mock_remote_clip"
    let inputText = "mock_input"
    let server = try MockKRDPServer.start(
        remoteClipboardText: remoteClipboardText,
        audioEnabled: true,
        waitForCompatibilityTraffic: true
    )
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "rdp-user", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: true,
            audioPlaybackEnabled: true
        ),
        onInputReady: { session in
            var events: [RDPSlowPathInputEvent] = [
                .pointerMove(x: 640, y: 360),
            ]
            for codeUnit in inputText.utf16 {
                events.append(.unicode(codeUnit: codeUnit, isReleased: false))
                events.append(.unicode(codeUnit: codeUnit, isReleased: true))
            }
            session.send(events)
        },
        onDisplayControlReady: { session in
            session.sendSingleMonitorLayout(
                width: 1440,
                height: 900,
                desktopScaleFactor: 150,
                deviceScaleFactor: 140
            )
        },
        onClipboardReady: { session in
            session.publishLocalUnicodeText(localClipboardText)
        },
        onClipboardText: { text in
            observed.recordClipboardText(text)
        },
        onAudioSample: { sample in
            observed.record(sample)
        }
    )

    let transcript = server.transcript.snapshot
    let clipboardSentNames = report.rdpClipboardSentMessages?.map(\.typeName) ?? []
    let clipboardReceivedNames = report.rdpClipboardMessages?.map(\.typeName) ?? []
    let audioReceivedNames = report.rdpAudioMessages?.map(\.typeName) ?? []
    let audioClientNames = transcript.audioClientMessages.map(\.typeName)
    let dynamicRequestTypes = report.rdpDynamicChannelRequestTypes ?? []

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

    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
    for acknowledgeHex in report.rdpGraphicsFrameAcknowledgeHexes ?? [] {
        #expect(try staticChannelFlags(fromTPKTHex: acknowledgeHex) == (
            RDPStaticVirtualChannelFlags.complete
        ))
    }
    #expect(try staticChannelFlags(fromTPKTHex: report.rdpDynamicChannelCapabilitiesResponseHex) == (
        RDPStaticVirtualChannelFlags.complete
    ))
    #expect(try staticChannelFlags(fromTPKTHex: report.rdpGraphicsChannelCreateResponseHex) == (
        RDPStaticVirtualChannelFlags.complete
    ))
    #expect(try staticChannelFlags(fromTPKTHex: report.rdpGraphicsCapsAdvertiseHex) == (
        RDPStaticVirtualChannelFlags.complete
    ))
    #expect(try staticChannelFlags(fromTPKTHex: report.rdpDisplayControlChannelCreateResponseHex) == (
        RDPStaticVirtualChannelFlags.complete
    ))
    #expect(report.rdpGraphicsCapsAdvertiseHex?.contains(
        RDPGFXCapsAdvertisePDU(
            capabilitySets: RDPGraphicsCapabilityProfile.automatic.capabilitySets
        ).encoded().rdpHexString
    ) == true)
    #expect(transcript.dynamicCreateResponseStaticFlags.count == 2)
    #expect(transcript.dynamicCreateResponseStaticFlags.allSatisfy {
        $0 == RDPStaticVirtualChannelFlags.complete
    })
    #expect(transcript.displayControlStaticFlags.isEmpty == false)
    #expect(transcript.displayControlStaticFlags.allSatisfy {
        $0 == RDPStaticVirtualChannelFlags.complete
    })
    #expect(transcript.audioDynamicStaticFlags.isEmpty == false)
    #expect(transcript.audioDynamicStaticFlags.allSatisfy {
        $0 == RDPStaticVirtualChannelFlags.complete
    })

    #expect(clipboardReceivedNames.contains("clipboard-monitor-ready"))
    #expect(clipboardReceivedNames.contains("clipboard-format-list"))
    #expect(clipboardReceivedNames.contains("clipboard-format-data-response"))
    #expect(clipboardSentNames.contains("clipboard-capabilities"))
    #expect(clipboardSentNames.contains("clipboard-temporary-directory"))
    #expect(clipboardSentNames.contains("clipboard-format-list"))
    #expect(clipboardSentNames.contains("clipboard-format-list-response"))
    #expect(clipboardSentNames.contains("clipboard-format-data-request"))
    #expect(clipboardSentNames.contains("clipboard-format-data-response"))
    #expect(observed.clipboardTexts == [remoteClipboardText])
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

    #expect(transcript.displayControlLayouts == [
        MockDisplayControlLayoutSummary(
            monitorCount: 1,
            primaryWidth: 1440,
            primaryHeight: 900,
            primaryDesktopScaleFactor: 150,
            primaryDeviceScaleFactor: 140
        ),
    ])
    #expect(transcript.deviceRedirectionClientMessages.contains("rdpdr-client-id-confirm"))
    #expect(transcript.deviceRedirectionClientMessages.contains("rdpdr-client-name"))
    #expect(transcript.deviceRedirectionClientMessages.contains("rdpdr-client-capability"))
    #expect(transcript.deviceRedirectionClientMessages.contains("rdpdr-device-list-announce"))

    #expect(audioReceivedNames.contains("audio-formats"))
    #expect(audioReceivedNames.contains("audio-training"))
    #expect(audioReceivedNames.contains("audio-wave2"))
    #expect(audioClientNames.contains("audio-formats"))
    #expect(audioClientNames.contains("audio-quality-mode"))
    #expect(audioClientNames.contains("audio-training"))
    #expect(audioClientNames.contains("audio-wave-confirm"))
    #expect(observed.audioSamples.count == 1)
    #expect(observed.audioSamples.first?.format == .pcmStereo48k16Bit)
    #expect(observed.audioSamples.first?.data == Data([0x11, 0x22, 0x33, 0x44]))
    #expect(report.error == nil)
}
}

private final class RDPTestCertificateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCertificate: RDPServerCertificateInfo?

    var certificate: RDPServerCertificateInfo? {
        lock.lock()
        defer { lock.unlock() }
        return storedCertificate
    }

    func record(_ certificate: RDPServerCertificateInfo) {
        lock.lock()
        storedCertificate = certificate
        lock.unlock()
    }
}

private final class MockKRDPObservedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFrames: [RDPGraphicsFrameSnapshot] = []
    private var recordedWireBytes = 0
    private var recordedClipboardSession: RDPClipboardSession?
    private var recordedFileDescriptor: RDPClipboardFileGroupDescriptorW?
    private var recordedRemoteFileSize: UInt64?
    private var recordedRemoteFileData: Data?
    private var recordedClipboardTexts: [String] = []
    private var recordedAudioSamples: [RDPAudioSample] = []
    private var recordedClipboardErrors: [String] = []
    private var recordedPointerUpdates: [RDPRemotePointerUpdate] = []

    var frames: [RDPGraphicsFrameSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFrames
    }

    var wireBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWireBytes
    }

    var clipboardSession: RDPClipboardSession? {
        lock.lock()
        defer { lock.unlock() }
        return recordedClipboardSession
    }

    var fileDescriptor: RDPClipboardFileGroupDescriptorW? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFileDescriptor
    }

    var remoteFileSize: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRemoteFileSize
    }

    var remoteFileData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRemoteFileData
    }

    var clipboardTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedClipboardTexts
    }

    var audioSamples: [RDPAudioSample] {
        lock.lock()
        defer { lock.unlock() }
        return recordedAudioSamples
    }

    var clipboardErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedClipboardErrors
    }

    var pointerUpdates: [RDPRemotePointerUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPointerUpdates
    }

    func record(_ frame: RDPGraphicsFrameSnapshot) {
        lock.lock()
        recordedFrames.append(frame)
        lock.unlock()
    }

    func record(_ sample: RDPWireReceiveSample) {
        lock.lock()
        recordedWireBytes += sample.byteCount
        lock.unlock()
    }

    func record(_ session: RDPClipboardSession) {
        lock.lock()
        recordedClipboardSession = session
        lock.unlock()
    }

    func record(_ descriptor: RDPClipboardFileGroupDescriptorW) {
        lock.lock()
        recordedFileDescriptor = descriptor
        lock.unlock()
    }

    func recordRemoteFileSize(_ size: UInt64) {
        lock.lock()
        recordedRemoteFileSize = size
        lock.unlock()
    }

    func recordRemoteFileData(_ data: Data) {
        lock.lock()
        recordedRemoteFileData = data
        lock.unlock()
    }

    func recordClipboardText(_ text: String) {
        lock.lock()
        recordedClipboardTexts.append(text)
        lock.unlock()
    }

    func record(_ sample: RDPAudioSample) {
        lock.lock()
        recordedAudioSamples.append(sample)
        lock.unlock()
    }

    func record(_ update: RDPRemotePointerUpdate) {
        lock.lock()
        recordedPointerUpdates.append(update)
        lock.unlock()
    }

    func recordClipboardError(_ error: String) {
        lock.lock()
        recordedClipboardErrors.append(error)
        lock.unlock()
    }
}

private func mockPixel(atX x: Int, y: Int, data: Data, bytesPerRow: Int) -> [UInt8] {
    let offset = y * bytesPerRow + x * 4
    return Array(data[offset ..< offset + 4])
}

private func clientCoreData(fromMCSConnectInitialHex hex: String?) throws -> Data {
    let data = try #require(hex.flatMap(Data.init(rdpHexString:)))
    let marker = Data([0x01, 0xC0, 0xEA, 0x00])
    let range = try #require(data.range(of: marker))
    let end = try #require(data.index(range.lowerBound, offsetBy: 234, limitedBy: data.endIndex))
    return data.subdata(in: range.lowerBound ..< end)
}

private func staticChannelFlags(fromTPKTHex hex: String?) throws -> UInt32 {
    let data = try #require(hex.flatMap(Data.init(rdpHexString:)))
    let unwrapped = try X224DataTPDU.unwrap(data)
    var cursor = ByteCursor(unwrapped)
    #expect(try cursor.readUInt8() == 0x64)
    _ = try cursor.readBigEndianUInt16()
    #expect(try cursor.readBigEndianUInt16() == 1004)
    _ = try cursor.readUInt8()
    let userDataLength = try cursor.readPERLength()
    let userData = try cursor.readData(count: userDataLength)
    #expect(cursor.remaining == 0)

    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: userData)
    return pdu.flags
}

private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}
