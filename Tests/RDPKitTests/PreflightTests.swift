import Foundation
@testable import RDPKit
import Testing

@Test func dryRunReportIncludesTargetCredentialsAndNegotiationBytes() {
    let credentials = RDPCredentials(username: "aneesi", domain: "LAB", password: "secret")
    let configuration = RDPConnectionConfiguration(
        host: "192.168.1.126",
        port: 3390,
        credentials: credentials,
        timeoutSeconds: 5,
        hideCertificateWarnings: true
    )

    let report = RDPPreflightClient().dryRun(configuration: configuration)

    #expect(report.status == "dry-run")
    #expect(report.stage == "x224-rdp-negotiation-request")
    #expect(report.target == "192.168.1.126:3390")
    #expect(report.username == "aneesi")
    #expect(report.domain == "LAB")
    #expect(report.passwordConfigured)
    #expect(report.requestedProtocols == ["tls", "credssp"])
    #expect(report.requestHex == "03 00 00 13 0e e0 00 00 00 00 00 01 00 08 00 03 00 00 00")
    #expect(report.nextStage == "send request to KRdp")
    #expect(report.error == nil)
}

@Test func connectionConfigurationClampsGraphicsFrameCaptureLimit() {
    #expect(RDPConnectionConfiguration(host: "example.test", graphicsFrameCaptureLimit: 0).graphicsFrameCaptureLimit == 1)
    #expect(RDPConnectionConfiguration(host: "example.test", graphicsFrameCaptureLimit: 999).graphicsFrameCaptureLimit == 120)
    #expect(RDPConnectionConfiguration(host: "example.test", graphicsFrameCaptureLimit: nil).graphicsFrameCaptureLimit == nil)
}

@Test func liveGraphicsUpdatesRecordOneRecentFrameForReports() {
    #expect(recordedGraphicsFrameLimit(targetFrameCount: nil) == 1)
    #expect(recordedGraphicsFrameLimit(targetFrameCount: 1) == 1)
    #expect(recordedGraphicsFrameLimit(targetFrameCount: 3) == 3)
}

@Test func liveGraphicsUpdatesBoundDiagnosticsForReports() {
    #expect(recordedGraphicsMessageLimit(targetFrameCount: nil) == 16)
    #expect(recordedGraphicsMessageLimit(targetFrameCount: 1) == 4)
    #expect(recordedGraphicsMessageLimit(targetFrameCount: 3) == 12)

    #expect(recordedGraphicsAcknowledgeLimit(targetFrameCount: nil) == 8)
    #expect(recordedGraphicsAcknowledgeLimit(targetFrameCount: 1) == 1)
    #expect(recordedGraphicsAcknowledgeLimit(targetFrameCount: 3) == 3)
}

@Test func connectionConfigurationClampsRequestedDesktopSize() {
    let small = RDPConnectionConfiguration(host: "example.test", desktopWidth: 1, desktopHeight: 1)
    let large = RDPConnectionConfiguration(host: "example.test", desktopWidth: 10000, desktopHeight: 10000)

    #expect(small.desktopWidth == 640)
    #expect(small.desktopHeight == 480)
    #expect(large.desktopWidth == 8192)
    #expect(large.desktopHeight == 8192)
}

@Test func connectionConfigurationNormalizesHostAndTimeout() {
    let configuration = RDPConnectionConfiguration(host: " example.test ", timeoutSeconds: -1)

    #expect(configuration.host == "example.test")
    #expect(configuration.timeoutSeconds == 1)
}

@Test func connectionConfigurationBuildsFromValidatedTargetAndDesktopSize() throws {
    let target = try RDPConnectionTarget(host: " example.test ", portText: "3390")
    let desktopSize = try RDPDesktopSize(widthText: "1920", heightText: "1080")
    let credentials = RDPCredentials(username: "anees", password: "secret")

    let configuration = RDPConnectionConfiguration(
        target: target,
        credentials: credentials,
        timeoutSeconds: 12,
        hideCertificateWarnings: true,
        graphicsFrameCaptureLimit: nil,
        desktopSize: desktopSize,
        clipboardEnabled: false,
        audioPlaybackEnabled: true
    )

    #expect(configuration.host == "example.test")
    #expect(configuration.port == 3390)
    #expect(configuration.credentials == credentials)
    #expect(configuration.timeoutSeconds == 12)
    #expect(configuration.hideCertificateWarnings)
    #expect(configuration.graphicsFrameCaptureLimit == nil)
    #expect(configuration.desktopWidth == 1920)
    #expect(configuration.desktopHeight == 1080)
    #expect(configuration.clipboardEnabled == false)
    #expect(configuration.audioPlaybackEnabled)
    #expect(configuration.identity == RDPConnectionIdentity(
        host: "example.test",
        port: 3390,
        username: "anees"
    ))
    #expect(configuration.displayName == "anees@example.test:3390")
}

@Test func connectionConfigurationBuildsRequestedStaticVirtualChannels() {
    #expect(
        RDPConnectionConfiguration(
            host: "example.test",
            clipboardEnabled: false,
            audioPlaybackEnabled: false
        ).staticVirtualChannels == [.drdynvc]
    )
    #expect(
        RDPConnectionConfiguration(
            host: "example.test",
            clipboardEnabled: false,
            audioPlaybackEnabled: true
        ).staticVirtualChannels == [.drdynvc, .rdpsnd]
    )
    #expect(
        RDPConnectionConfiguration(
            host: "example.test",
            clipboardEnabled: true,
            audioPlaybackEnabled: true
        ).staticVirtualChannels == [.drdynvc, .cliprdr, .rdpsnd]
    )
}

@Test func wireReceiveSampleConvertsBytesToMegabits() {
    let sample = RDPWireReceiveSample(
        byteCount: 125_000,
        receivedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(sample.megabits == 1)
}

@Test func preflightHonorsPreCancelledConnectionCancellation() {
    let cancellation = RDPConnectionCancellation()
    cancellation.cancel()

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(host: "example.test"),
        cancellation: cancellation
    )

    #expect(report.status == "failure")
    #expect(report.stage == "x224-rdp-negotiation")
    #expect(report.error == "cancelled")
}

@Test func preflightReportDerivesFirstFrameFromFrameList() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 7,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        h264AnnexBData: Data([0x00, 0x00, 0x01, 0x65])
    )

    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "example.test:3389",
        passwordConfigured: false,
        requestedProtocols: ["tls"],
        requestHex: "",
        rdpGraphicsFrames: [frame],
        warnings: []
    )

    #expect(report.rdpGraphicsFrames == [frame])
    #expect(report.rdpGraphicsFirstFrame == frame)
    #expect(frame.videoCodec == .h264)
    #expect(frame.videoByteCount == 4)
    #expect(frame.videoNalUnitTypes == [5])
    #expect(frame.h264ByteCount == 4)
    #expect(frame.h264NalUnitTypes == [5])
}

@Test func graphicsFrameSnapshotReportsHEVCVideoMetadata() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 8,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "hevc-test",
        videoCodec: .hevc,
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        encodedVideoData: Data([
            0x00, 0x00, 0x01, 0x40, 0x01,
            0x00, 0x00, 0x01, 0x42, 0x01,
            0x00, 0x00, 0x01, 0x44, 0x01,
            0x00, 0x00, 0x01, 0x26, 0x01,
        ])
    )

    #expect(frame.videoByteCount == 20)
    #expect(frame.videoNalUnitTypes == [32, 33, 34, 19])
    #expect(frame.h264ByteCount == 0)
    #expect(frame.h264NalUnitTypes == [])
}
