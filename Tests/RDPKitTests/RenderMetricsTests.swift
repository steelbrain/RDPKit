import Foundation
@testable import RDPKit
import Testing

@Test func renderMetricsTracksDecodedFramesAndRollingWireBandwidth() {
    let start = Date(timeIntervalSince1970: 100)
    var metrics = RDPRenderMetrics(connectionStartedAt: start)

    metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 125_000, receivedAt: start))
    metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 125_000, receivedAt: start.addingTimeInterval(1)))

    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 2,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
    metrics.recordDecodedFrame(
        frame,
        receivedAt: start.addingTimeInterval(1),
        decodedAt: start.addingTimeInterval(1.02),
        timing: RDPFrameDecodeTiming(
            samplePreparationMilliseconds: 0.2,
            videoToolboxMilliseconds: 4.0,
            imageConversionMilliseconds: 0,
            cropMilliseconds: 0,
            totalMilliseconds: 4.2,
            decodedPixelFormat: 0x3432_3076,
            usesHardwareAcceleration: true
        )
    )

    #expect(metrics.hasActivity)
    #expect(metrics.decodedFrameCount == 1)
    #expect(metrics.decodedByteCount == 4)
    #expect(metrics.wireByteCount == 250_000)
    #expect(metrics.rollingWireMegabitsPerSecond == 2)
    #expect(metrics.lastDecodeMilliseconds == 4.2)
    #expect(metrics.lastVideoToolboxMilliseconds == 4.0)
    #expect(metrics.decodedPixelFormat == 0x3432_3076)
    #expect(metrics.usesHardwareAcceleration == true)
}

@Test func renderMetricsStoreThrottlesSnapshotsUntilForced() {
    let start = Date(timeIntervalSince1970: 200)
    let store = RDPRenderMetricsStore()

    #expect(store.snapshotIfNeeded(at: start) != nil)
    #expect(store.snapshotIfNeeded(at: start.addingTimeInterval(0.1)) == nil)
    #expect(store.snapshotIfNeeded(at: start.addingTimeInterval(0.6)) != nil)
    #expect(store.snapshotIfNeeded(force: true, at: start.addingTimeInterval(0.7)) != nil)
}

@Test func graphicsFrameCountsBothAVC444Substreams() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 2,
        codecID: RDPGFXCodecID.avc444,
        codecName: "avc444",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65]),
        auxiliaryEncodedVideoData: Data([0x00, 0x00, 0x01, 0x41]),
        avc444SubframeLayout: .yuv420AndChroma420
    )

    #expect(frame.videoByteCount == 8)
    #expect(frame.videoNalUnitTypes == [5, 1])
}
