import CoreVideo
import Foundation
@testable import RDPKit
import Testing

// Fixtures captured from a live gnome-remote-desktop (GRD) server during this
// branch's debugging. These are real bytes off the wire, not hand-modelled, so
// they pin the client to GRD's actual behaviour rather than to our own
// assumptions about it — the gap that let the GNOME regressions land green.

@Test func parsesRealGnomeMCSConnectResponseChannelLayout() throws {
    // GRD assigns drdynvc and cliprdr as static channels plus a message channel
    // for connect-time auto-detect.
    let response = try MCSConnectResponse.parse(
        fromTPKT: hexData("""
        03 00 00 72 02 f0 80 7f 66 68 0a 01 00 02 01 00 30 1a 02 01 22 02 01 03 \
        02 01 00 02 01 01 02 01 00 02 01 01 02 03 00 ff f8 02 01 02 04 44 00 05 \
        00 14 7c 00 01 2a 14 76 0a 01 01 00 01 c0 00 4d 63 44 6e 2e 01 0c 10 00 \
        05 00 08 00 03 00 00 00 00 00 00 00 03 0c 0c 00 eb 03 02 00 ec 03 ed 03 \
        02 0c 0c 00 00 00 00 00 00 00 00 00 04 0c 06 00 ee 03
        """),
        requestedChannels: [.drdynvc, .cliprdr],
        expectedMessageChannelAdvertised: true
    )

    #expect(response.result == 0)
    #expect(response.serverUserDataKey == "McDn")
    #expect(response.clientRequestedProtocols == [.tls, .credSSP])
    #expect(response.ioChannelID == 1003)
    #expect(response.messageChannelID == 1006)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1005),
    ])
}

@Test func realGnomeBandwidthMeasureStartParses() throws {
    // The exact auto-detect request GRD sends first, on the message channel
    // (1006), immediately after Client Info. The client must parse it as a
    // bandwidth-measure-start, which has no response (MS-RDPBCGR 2.2.14.1.2).
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(
        fromTPKT: hexData("03 00 00 19 02 f0 80 68 00 06 03 ee 70 80 0a 00 10 00 00 06 00 00 00 14 10")
    ))

    #expect(request.channelID == 1006)
    #expect(request.sequenceNumber == 0)
    #expect(request.requestType == 0x1014)
    #expect(request.requestTypeName == "connect-time-bandwidth-measure-start")
    #expect(request.payloadByteCount == 0)
    #expect(meterResponse(to: request) == nil)
}

/// gnome-remote-desktop 51 at 1000x750 encodes AVC420 into unmapped staging surface 1
/// (1008x768) and copies it to mapped surface 0 with a SurfaceToSurface. Surface 0's
/// decoder gets that video and presents the test pattern gnome showed.
@Test func replaysGnomeStagedVideoOntoTheMappedSurface() throws {
    let observed = Locked([RDPGraphicsFrameSnapshot]())
    let report = try replayTranscriptFixture("gnome-staged-transcript") { frame in
        observed.withLock { $0.append(frame) }
    }.report

    #expect(report.status == "success")
    #expect(report.rdpGraphicsUpdateMessages?.map { [$0.typeName, "\($0.surfaceID ?? 0)"] } == [
        ["rdpgfx-reset-graphics", "0"],
        ["rdpgfx-create-surface", "0"],
        ["rdpgfx-create-surface", "1"],
        ["rdpgfx-map-surface-to-output", "0"],
        ["rdpgfx-start-frame", "0"],
        ["rdpgfx-wire-to-surface-1", "1"],
        ["rdpgfx-surface-to-surface", "0"],
        ["rdpgfx-end-frame", "0"],
    ])
    let surface = RDPFrameRect(left: 0, top: 0, right: 1_000, bottom: 750)
    let frames = observed.value
    #expect(frames.map(\.surfaceID) == [0])
    #expect(frames.map(\.contentKind) == [.video])
    #expect(frames.first?.surfaceRect == surface)
    #expect(frames.first?.regionRects == [surface])

    let presented = Locked([RDPDecodedFramePresentation]())
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { presentation, _, _, _ in presented.withLock { $0.append(presentation) } },
        onDecodeFailed: { _, _ in }
    )
    for frame in frames {
        #expect(queue.submitAndWait(frame, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    }
    let presentation = try #require(presented.value.last)
    #expect(presentation.frame.destinationRect == surface)
    // gnome's first frame shows its 1280x720 test pattern unscaled: bars of red, green,
    // yellow, blue and magenta about 213 columns wide.
    let pixels = try Data(coreImageBGRA(presentation.imageBuffer))
    let bytesPerRow = CVPixelBufferGetWidth(presentation.imageBuffer) * 4
    let bars: [(x: Int, rgb: [Bool])] = [
        (100, [true, false, false]),
        (320, [false, true, false]),
        (530, [true, true, false]),
        (750, [false, false, true]),
        (960, [true, false, true]),
    ]
    for bar in bars {
        let bgra = pixel(atX: bar.x, y: 100, data: pixels, bytesPerRow: bytesPerRow)
        let rgb = [bgra[2], bgra[1], bgra[0]]
        #expect(zip(rgb, bar.rgb).allSatisfy { $1 ? $0 > 180 : $0 < 60 }, "bar at \(bar.x): \(rgb)")
    }
}
