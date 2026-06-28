import Foundation
@testable import RDPKit
import Testing

@Suite(.serialized)
struct MockKRDPServerTests {
@Test func preflightCapturesGraphicsFrameFromMockKRDPServer() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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

@Test func preflightFollowsServerRedirectionAndReconnects() throws {
    let server = try MockKRDPServer.start(redirectionBehavior: .redirectFirstConnection)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
                credentials: RDPCredentials(username: "aneesi", password: "secret"),
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

@Test func preflightReportsFailingGraphicsUpdateFromMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendInvalidGraphicsPDU)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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

@Test func preflightVerifiesFragmentedBitmapGraphicsWithMockServer() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendFragmentedBitmapCompositionFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
    #expect(report.rdpGraphicsUpdateResponseCount ?? 0 > 1)
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
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
        (.avc420, RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.defaultVersion8),
        (.legacy, RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.defaultVersion8),
    ]

    for testCase in cases {
        let server = try MockKRDPServer.start(
            graphicsBehavior: .sendCAVideoRemoteFXFrame,
            graphicsCapabilitySelection: .firstAdvertisedThinClientSmallCache
        )
        defer { server.stop() }

        let observed = MockKRDPObservedEvents()
        let report = RDPPreflightClient().run(
            configuration: RDPConnectionConfiguration(
                host: "127.0.0.1",
                port: server.port,
                credentials: RDPCredentials(username: "aneesi", password: "secret"),
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

@Test func preflightDoesNotReplaceAVCFrameWithIncompleteSurfaceFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendVideoBeforeBitmapCompositionFrame)
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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

@Test func preflightCallsCertificateHandlerAfterTLSHandshake() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let capture = RDPTestCertificateCapture()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
    let credentials = RDPCredentials(username: "aneesi", password: "secret")
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
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

@Test func livePreflightTimesOutWhenGraphicsPipelineStallsBeforeFirstFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .stallAfterCapsConfirm)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
        "rdpgfx-end-frame",
    ])
    #expect(report.rdpGraphicsFrames == [])
    #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
    #expect(report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
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
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
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
