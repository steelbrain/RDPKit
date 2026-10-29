import Foundation
@testable import RDPKit
import Testing

@Test func dryRunReportIncludesTargetCredentialsAndNegotiationBytes() {
    let credentials = RDPCredentials(username: "rdp-user", domain: "LAB", password: "secret")
    let configuration = RDPConnectionConfiguration(
        host: "192.0.2.10",
        port: 3390,
        credentials: credentials,
        timeoutSeconds: 5,
        hideCertificateWarnings: true
    )

    let report = RDPSessionClient().dryRun(configuration: configuration)

    #expect(report.status == "dry-run")
    #expect(report.stage == "x224-rdp-negotiation-request")
    #expect(report.target == "192.0.2.10:3390")
    #expect(report.username == "rdp-user")
    #expect(report.domain == "LAB")
    #expect(report.passwordConfigured)
    #expect(report.requestedProtocols == ["tls", "credssp"])
    #expect(report.requestHex == "03 00 00 13 0e e0 00 00 00 00 00 01 00 08 00 03 00 00 00")
    #expect(report.nextStage == "send negotiation request to server")
    #expect(report.error == nil)
}

@Test func dryRunCanRequestEarlyUserAuthorization() {
    let report = RDPSessionClient().dryRun(configuration: RDPConnectionConfiguration(
        host: "192.0.2.10",
        earlyUserAuthorizationEnabled: true
    ))

    #expect(report.requestedProtocols == ["tls", "credssp", "credssp-early-user-auth"])
    #expect(report.requestHex == "03 00 00 13 0e e0 00 00 00 00 00 01 00 08 00 0b 00 00 00")
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
    #expect(recordedGraphicsMessageLimit(targetFrameCount: 1) == 16)
    #expect(recordedGraphicsMessageLimit(targetFrameCount: 3) == 16)

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
        ).staticVirtualChannels == [.drdynvc, .rdpdr, .rdpsnd]
    )
    #expect(
        RDPConnectionConfiguration(
            host: "example.test",
            clipboardEnabled: true,
            audioPlaybackEnabled: true
        ).staticVirtualChannels == [.drdynvc, .cliprdr, .rdpdr, .rdpsnd]
    )
    // Shared drives need rdpsnd as well as rdpdr, even with audio off.
    #expect(
        RDPConnectionConfiguration(
            host: "example.test",
            clipboardEnabled: false,
            audioPlaybackEnabled: false,
            sharedDrives: [RDPSharedDrive(name: "share", url: URL(fileURLWithPath: "/tmp"))]
        ).staticVirtualChannels == [.drdynvc, .rdpdr, .rdpsnd]
    )
}

@Test func connectionConfigurationCarriesGraphicsCapabilityProfile() throws {
    let target = try RDPConnectionTarget(host: "example.test", portText: "3390")
    let desktopSize = try RDPDesktopSize(widthText: "1920", heightText: "1080")

    let configuration = RDPConnectionConfiguration(
        target: target,
        graphicsFrameCaptureLimit: nil,
        desktopSize: desktopSize,
        graphicsCapabilityProfile: .avc420
    )

    #expect(configuration.graphicsCapabilityProfile == .avc420)
}

@Test func wireReceiveSampleConvertsBytesToMegabits() {
    let sample = RDPWireReceiveSample(
        byteCount: 125_000,
        receivedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(sample.megabits == 1)
}

@Test func clientHonorsPreCancelledConnectionCancellation() {
    let cancellation = RDPConnectionCancellation()
    cancellation.cancel()

    let report = RDPSessionClient().run(
        configuration: RDPConnectionConfiguration(host: "example.test"),
        cancellation: cancellation
    )

    #expect(report.status == "failure")
    #expect(report.stage == "x224-rdp-negotiation")
    #expect(report.error == "cancelled")
}

@Test func connectionReportDerivesFirstFrameFromFrameList() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 7,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )

    let report = RDPConnectionReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "example.test:3389",
        passwordConfigured: false,
        requestedProtocols: ["tls"],
        requestHex: "",
        rdpFastPathUpdateMessages: [
            RDPFastPathUpdateSummary(
                typeName: "fastpath-pointer-position",
                fragmentation: "single",
                compressed: false,
                byteCount: 4,
                pointerTypeName: "pointer-position"
            ),
        ],
        rdpGraphicsFrames: [frame],
        warnings: []
    )

    #expect(report.rdpGraphicsFrames == [frame])
    #expect(report.rdpGraphicsFirstFrame == frame)
    #expect(report.rdpFastPathUpdateMessages?.first?.typeName == "fastpath-pointer-position")
    #expect(frame.videoCodec == .h264)
    #expect(frame.videoByteCount == 4)
    #expect(frame.videoNalUnitTypes == [5])
}

@Test func connectionReportCarriesIssuedClientLicenseForPersistence() throws {
    let license = RDPStoredClientLicense(
        version: 0x0006_0001,
        scope: "localhost",
        companyName: "Microsoft Corporation",
        productID: "A02",
        licenseInfo: Data([0x30, 0x82, 0x01, 0x02])
    )
    let report = RDPConnectionReport(
        status: "success",
        stage: "rdp-server-activation",
        target: "example.test:3389",
        passwordConfigured: false,
        requestedProtocols: ["tls"],
        requestHex: "",
        rdpIssuedClientLicense: license,
        warnings: []
    )
    let encoded = try JSONEncoder().encode(report)
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(report.rdpIssuedClientLicense == license)
    #expect(json.contains("\"rdpIssuedClientLicense\""))
    #expect(json.contains("\"licenseInfo\""))
}

@Test func graphicsPathDescriptionNamesAVC444VideoPath() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 2,
        surfaceID: 0,
        codecID: RDPGFXCodecID.avc444v2,
        codecName: RDPGFXCodecID.name(for: RDPGFXCodecID.avc444v2),
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )

    let description = RDPGraphicsPathDescription.describe(
        selectedCapabilityVersion: RDPGFXCapabilityVersion.version107,
        selectedCapabilityFlags: RDPGFXCapabilityFlags.defaultVersion107,
        firstFrame: frame,
        updateMessages: nil
    )

    #expect(description == "RDPGFX v10.7 AVC thin-client flags=0x00000042 -> avc444v2/H.264")
}

@Test func graphicsPathDescriptionNamesCaprogressiveUpdatePath() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.caProgressive)
    payload.appendLittleEndianUInt32(12)
    payload.appendUInt8(32)
    payload.appendLittleEndianUInt32(1)
    payload.appendUInt8(0x00)
    let message = try RDPGFXHeader.parse(
        from: graphicsMessage(commandID: RDPGFXCommandID.wireToSurface2, payload: payload)
    )
    let summary = try RDPGFXMessageSummary.summarize(message)

    let description = RDPGraphicsPathDescription.describe(
        selectedCapabilityVersion: RDPGFXCapabilityVersion.version81,
        selectedCapabilityFlags: RDPGFXCapabilityFlags.defaultVersion81,
        firstFrame: nil,
        updateMessages: [summary]
    )

    #expect(description == "RDPGFX v8.1 AVC420 flags=0x00000012 -> rdpgfx-wire-to-surface-2 caprogressive")
}

@Test func graphicsPathDescriptionNamesCAVideoRemoteFXUpdatePath() {
    var summary = RDPGFXMessageSummary(typeName: "rdpgfx-wire-to-surface-1")
    summary.codecName = "cavideo"
    summary.cavideoTileCount = 2
    summary.cavideoTileSetEntropyAlgorithms = ["rlgr3"]

    let description = RDPGraphicsPathDescription.describe(
        selectedCapabilityVersion: RDPGFXCapabilityVersion.version81,
        selectedCapabilityFlags: RDPGFXCapabilityFlags.thinClient
            | RDPGFXCapabilityFlags.smallCache
            | RDPGFXCapabilityFlags.avc420Enabled,
        firstFrame: nil,
        updateMessages: [summary]
    )

    #expect(
        description == """
        RDPGFX v8.1 thin-client AVC420 flags=0x00000013 -> rdpgfx-wire-to-surface-1 cavideo remotefx tiles=2 entropy=rlgr3
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

@Test func graphicsPathDescriptionPreservesCAVideoPathForDecodedBitmapFrame() {
    var summary = RDPGFXMessageSummary(typeName: "rdpgfx-wire-to-surface-1")
    summary.codecName = "cavideo"
    summary.cavideoTileCount = 1
    summary.cavideoTileSetEntropyAlgorithms = ["rlgr3"]
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 4,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84),
        regionRects: [RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data(repeating: 0x80, count: 64 * 64 * 4),
        decodedBitmapBytesPerRow: 64 * 4
    )
    let cases: [(version: UInt32, flags: UInt32, description: String)] = [
        (
            RDPGFXCapabilityVersion.version8,
            RDPGFXCapabilityFlags.thinClient,
            """
            RDPGFX v8 thin-client flags=0x00000001 -> rdpgfx-wire-to-surface-1 cavideo remotefx tiles=1 entropy=rlgr3 -> surface-bgra
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        (
            RDPGFXCapabilityVersion.version81,
            RDPGFXCapabilityFlags.thinClient,
            """
            RDPGFX v8.1 thin-client flags=0x00000001 -> rdpgfx-wire-to-surface-1 cavideo remotefx tiles=1 entropy=rlgr3 -> surface-bgra
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
    ]

    for testCase in cases {
        let description = RDPGraphicsPathDescription.describe(
            selectedCapabilityVersion: testCase.version,
            selectedCapabilityFlags: testCase.flags,
            firstFrame: frame,
            updateMessages: [summary]
        )

        #expect(description == testCase.description)
    }
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
}

@Test func stagedVideoCopyRejectsDestinationsOutsideCoordinateRange() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 9,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 40_000, bottom: 10),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 40_000, bottom: 10)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
    let sourceRect = RDPGFXRect16(left: 0, top: 0, right: 40_000, bottom: 10)

    for point in [RDPGFXPoint16(x: -1, y: 0), RDPGFXPoint16(x: Int16.max, y: 0)] {
        #expect(stagedVideoCopy(of: frame, sourceRect: sourceRect, to: point, surfaceID: 2) == nil)
    }
}

/// Regions that would take unbounded work to apply collapse into their bounding box; the
/// regions servers send, which cover each pixel about once, stay as they are.
@Test func videoRegionsCollapseWhenTooManyOrCoveringTheUpdateManyTimesOver() {
    let update = RDPFrameRect(left: 100, top: 0, right: 2148, bottom: 64)
    let pixels = (0 ..< rdpMaximumVideoRegionCount).map {
        RDPFrameRect(left: UInt16($0), top: 0, right: UInt16($0 + 1), bottom: 1)
    }
    #expect(pixels.boundedVideoRegions(within: update) == pixels)
    let onePixelMore = pixels + [RDPFrameRect(left: 2000, top: 63, right: 2001, bottom: 64)]
    #expect(onePixelMore.boundedVideoRegions(within: update) == [RDPFrameRect(left: 0, top: 0, right: 2001, bottom: 64)])

    let whole = RDPFrameRect(left: 100, top: 0, right: 2148, bottom: 64)
    let fourTimes = Array(repeating: whole, count: 4)
    #expect(fourTimes.boundedVideoRegions(within: update) == fourTimes)
    #expect((fourTimes + [RDPFrameRect(left: 100, top: 0, right: 101, bottom: 1)]).boundedVideoRegions(within: update) == [whole])
    // Only the area inside the update's right and bottom edges counts.
    let overhanging = Array(repeating: RDPFrameRect(left: 2147, top: 63, right: 65535, bottom: 65535), count: 8)
    #expect(overhanging.boundedVideoRegions(within: update) == overhanging)
}

/// gnome-remote-desktop copies each damage rectangle of its staging surface with a
/// SurfaceToSurface of its own; each copy carries the access unit's part inside it.
@Test func stagedVideoCopyCarriesTheRegionsInsideTheCopiedRectangle() throws {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 9,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(left: 8, top: 4, right: 72, bottom: 36),
        regionRects: [
            RDPFrameRect(left: 0, top: 0, right: 16, bottom: 8),
            RDPFrameRect(left: 32, top: 16, right: 64, bottom: 32),
        ],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )

    let staged = try #require(stagedVideoCopy(
        of: frame,
        sourceRect: RDPGFXRect16(left: 40, top: 20, right: 56, bottom: 36),
        to: RDPGFXPoint16(x: 50, y: 30),
        surfaceID: 0
    ))
    #expect(staged.surfaceID == 0)
    #expect(staged.destinationRect == RDPFrameRect(left: 18, top: 14, right: 82, bottom: 46))
    #expect(staged.regionRects == [RDPFrameRect(left: 32, top: 16, right: 48, bottom: 32)])
    #expect(staged.encodedVideoData == frame.encodedVideoData)
    // A copy outside every region carries none of the access unit.
    #expect(stagedVideoCopy(
        of: frame,
        sourceRect: RDPGFXRect16(left: 8, top: 20, right: 24, bottom: 36),
        to: RDPGFXPoint16(x: 8, y: 20),
        surfaceID: 0
    ) == nil)
}
