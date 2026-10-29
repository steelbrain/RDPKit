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
            totalMilliseconds: 4.2,
            decodedPixelFormat: 0x3432_3076,
            usesHardwareAcceleration: true
        )
    )

    #expect(metrics.hasActivity)
    #expect(metrics.decodedFrameCount == 1)
    #expect(metrics.decodedByteCount == 4)
    #expect(metrics.wireByteCount == 250_000)
    #expect(metrics.rollingWireMegabitsPerSecond(at: start.addingTimeInterval(1)) == 2)
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

@Test func renderMetricsStoreIsSafeForConcurrentRecording() {
    let store = RDPRenderMetricsStore()
    let start = Date(timeIntervalSince1970: 300)

    DispatchQueue.concurrentPerform(iterations: 1000) { index in
        store.recordWireReceive(RDPWireReceiveSample(byteCount: 1, receivedAt: start.addingTimeInterval(Double(index) / 1000)))
        _ = store.snapshotIfNeeded(at: start)
    }

    #expect(store.metrics.wireByteCount == 1000)
}

@Test func renderMetricsRollingFramesPerSecondUsesRecentFrames() throws {
    let start = Date(timeIntervalSince1970: 400)
    var metrics = RDPRenderMetrics(connectionStartedAt: start)
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 2,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
    let timing = RDPFrameDecodeTiming(
        samplePreparationMilliseconds: 0,
        videoToolboxMilliseconds: 0,
        imageConversionMilliseconds: 0,
        totalMilliseconds: 1,
        decodedPixelFormat: nil,
        usesHardwareAcceleration: nil
    )

    // 30 s at 10 fps, then 5 s at 60 fps: only the recent 60 fps frames count.
    for index in 0 ..< 600 {
        let seconds = index < 300 ? Double(index) / 10 : 30 + Double(index - 300) / 60
        let decodedAt = start.addingTimeInterval(seconds)
        metrics.recordDecodedFrame(frame, receivedAt: decodedAt, decodedAt: decodedAt, timing: timing)
    }

    #expect(metrics.decodedFrameCount == 600)
    let lastFrameDecodedAt = try #require(metrics.lastFrameDecodedAt)
    #expect(abs((metrics.rollingFramesPerSecond(at: lastFrameDecodedAt) ?? 0) - 60) < 0.001)
}

@Test func renderMetricsRollingRatesFallOnceTrafficStops() throws {
    let start = Date(timeIntervalSince1970: 500)
    var metrics = RDPRenderMetrics(connectionStartedAt: start)
    #expect(metrics.rollingFramesPerSecond(at: start) == nil)
    #expect(metrics.rollingWireMegabitsPerSecond(at: start) == nil)

    // 240 frames at 64 fps, which keeps the times exact, and 250 KB every
    // 0.5 s on the wire for 4 s; then nothing.
    recordDecodedFrames(&metrics, at: (0 ..< 240).map { start.addingTimeInterval(Double($0) / 64) })
    for index in 0 ... 8 {
        metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 250_000, receivedAt: start.addingTimeInterval(Double(index) / 2)))
    }
    let lastFrame = try #require(metrics.lastFrameDecodedAt)
    let lastSample = start.addingTimeInterval(4)

    #expect(metrics.rollingFramesPerSecond(at: lastFrame) == 64)
    // Frames 47 to 239 are the 5 s up to 2 s after the last frame.
    #expect(metrics.rollingFramesPerSecond(at: lastFrame.addingTimeInterval(2)) == 38.4)
    #expect(metrics.rollingFramesPerSecond(at: lastFrame.addingTimeInterval(5)) == 0)
    #expect(metrics.rollingFramesPerSecond(at: lastFrame.addingTimeInterval(60)) == 0)

    #expect(metrics.rollingWireMegabitsPerSecond(at: lastSample) == 4.5)
    // The samples from 2 s to 4 s, over the whole window.
    #expect(metrics.rollingWireMegabitsPerSecond(at: lastSample.addingTimeInterval(3)) == 2)
    #expect(metrics.rollingWireMegabitsPerSecond(at: lastSample.addingTimeInterval(6)) == 0)
    #expect(metrics.rollingWireMegabitsPerSecond(at: lastSample.addingTimeInterval(60)) == 0)

    // Traffic that resumes counts from its first sample.
    let resumed = lastSample.addingTimeInterval(60)
    metrics.recordWireReceive(RDPWireReceiveSample(byteCount: 125_000, receivedAt: resumed))
    #expect(metrics.rollingWireMegabitsPerSecond(at: resumed) == 4)
}

@Test func renderMetricsRollingFramesPerSecondNeedsTwoFrames() {
    let start = Date(timeIntervalSince1970: 600)
    var metrics = RDPRenderMetrics(connectionStartedAt: start)
    recordDecodedFrames(&metrics, at: [start])

    #expect(metrics.rollingFramesPerSecond(at: start.addingTimeInterval(1)) == nil)

    recordDecodedFrames(&metrics, at: [start.addingTimeInterval(10)])
    #expect(metrics.rollingFramesPerSecond(at: start.addingTimeInterval(10)) == 0)
}

private func recordDecodedFrames(_ metrics: inout RDPRenderMetrics, at dates: [Date]) {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 2,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
    let timing = RDPFrameDecodeTiming(
        samplePreparationMilliseconds: 0,
        videoToolboxMilliseconds: 0,
        imageConversionMilliseconds: 0,
        totalMilliseconds: 1,
        decodedPixelFormat: nil,
        usesHardwareAcceleration: nil
    )
    for date in dates {
        metrics.recordDecodedFrame(frame, receivedAt: date, decodedAt: date, timing: timing)
    }
}
