import Foundation
@testable import RDPClient
import RDPKit
import Testing

@Test func viewerMetricsSummaryFallsOnceTrafficStops() {
    let start = Date(timeIntervalSince1970: 1000)
    var metrics = RDPRenderMetrics(connectionStartedAt: start)
    let frame = RDPGraphicsFrameSnapshot(
        frameID: nil,
        surfaceID: 0,
        codecID: 0,
        codecName: "bitmap",
        pixelFormat: 0,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [],
        encodedVideoData: Data()
    )
    let timing = RDPFrameDecodeTiming(
        samplePreparationMilliseconds: 0,
        videoToolboxMilliseconds: 2,
        imageConversionMilliseconds: 0,
        totalMilliseconds: 2,
        decodedPixelFormat: nil,
        usesHardwareAcceleration: true
    )
    // 2 s at 64 fps and 1 Mbps.
    for index in 0 ... 128 {
        let decodedAt = start.addingTimeInterval(Double(index) / 64)
        metrics.recordDecodedFrame(frame, receivedAt: decodedAt, decodedAt: decodedAt, timing: timing)
    }
    for index in 0 ... 8 {
        metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 31250, receivedAt: start.addingTimeInterval(Double(index) / 4)))
    }
    let end = start.addingTimeInterval(2)

    #expect(compactViewerMetricsSummary(metrics: metrics, framePacing: RDPFramePacingState(), at: end)
        == "64.0 fps - decode 2.0 ms - rx 1.1 Mbps")
    #expect(compactViewerMetricsSummary(metrics: metrics, framePacing: RDPFramePacingState(), at: end.addingTimeInterval(10))
        == "0.0 fps - decode 2.0 ms - rx 0.00 Mbps")
}
