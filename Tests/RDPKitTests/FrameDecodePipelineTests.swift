import Foundation
@testable import RDPKit
import Testing

@Test func decodeBacklogKeepsVideoFramesInOrderWithinLimit() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 3))

    #expect(backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [7, 8, 5])).isEmpty)
    #expect(backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1])).isEmpty)
    #expect(backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1])).isEmpty)

    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.frames.contains(where: \.resetDecoderBeforeDecode) == false)
}

@Test func decodeBacklogTrimsVideoOverflowToNewestResyncFrame() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 3))

    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [7, 8, 5]))
    _ = backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1]))
    _ = backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1]))

    let dropped = backlog.append(pendingVideoFrame(id: 4, nalUnitTypes: [7, 8, 5]))

    #expect(dropped.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.frames.map(\.frame.frameID) == [4])
    #expect(backlog.frames.first?.resetDecoderBeforeDecode == true)
    #expect(backlog.waitingForVideoResync == false)
}

@Test func decodeBacklogWaitsForVideoResyncWhenOverflowHasNoKeyframe() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 2))

    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [1]))
    _ = backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1]))
    let droppedOverflow = backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1]))

    #expect(droppedOverflow.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.frames.isEmpty)
    #expect(backlog.waitingForVideoResync)

    let droppedDelta = backlog.append(pendingVideoFrame(id: 4, nalUnitTypes: [1]))
    #expect(droppedDelta.map(\.frame.frameID) == [4])
    #expect(backlog.frames.isEmpty)
    #expect(backlog.waitingForVideoResync)

    #expect(backlog.append(pendingVideoFrame(id: 5, nalUnitTypes: [7, 8, 5])).isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [5])
    #expect(backlog.frames.first?.resetDecoderBeforeDecode == true)
    #expect(backlog.waitingForVideoResync == false)
}

@Test func decodeBacklogUsesLatencyLimitBeforeFrameLimit() {
    var backlog = RDPFrameDecodeBacklog(limits: RDPFrameDecodeQueueLimits(
        maxQueuedVideoFrames: 100,
        maxQueuedVideoLatency: 0.5,
        maxQueuedVideoBytes: 64 * 1024 * 1024
    ))
    let start = Date(timeIntervalSince1970: 10)

    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [7, 8, 5], receivedAt: start))
    _ = backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1], receivedAt: start.addingTimeInterval(0.2)))
    let dropped = backlog.append(pendingVideoFrame(
        id: 3,
        nalUnitTypes: [7, 8, 5],
        receivedAt: start.addingTimeInterval(0.6)
    ))

    #expect(dropped.map(\.frame.frameID) == [1, 2])
    #expect(backlog.frames.map(\.frame.frameID) == [3])
    #expect(backlog.frames.first?.resetDecoderBeforeDecode == true)
}

@Test func decodeBacklogCoalescesBitmapFramesToLatest() {
    var backlog = RDPFrameDecodeBacklog()

    #expect(backlog.append(pendingBitmapFrame(id: 1)).isEmpty)
    let dropped = backlog.append(pendingBitmapFrame(id: 2))

    #expect(dropped.map(\.frame.frameID) == [1])
    #expect(backlog.frames.map(\.frame.frameID) == [2])
    #expect(backlog.waitingForVideoResync == false)
}

@Test func decodeBacklogWaitsForVideoResyncWhenBitmapDropsPendingVideo() {
    var backlog = RDPFrameDecodeBacklog()

    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [7, 8, 5]))
    let dropped = backlog.append(pendingBitmapFrame(id: 2))

    #expect(dropped.map(\.frame.frameID) == [1])
    #expect(backlog.frames.map(\.frame.frameID) == [2])
    #expect(backlog.waitingForVideoResync)

    let droppedDelta = backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1]))
    #expect(droppedDelta.map(\.frame.frameID) == [3])
    #expect(backlog.frames.map(\.frame.frameID) == [2])
}

private func pendingVideoFrame(
    id: UInt32,
    nalUnitTypes: [UInt8],
    receivedAt: Date? = nil
) -> RDPPendingDecodeFrame {
    RDPPendingDecodeFrame(
        frame: RDPGraphicsFrameSnapshot(
            frameID: id,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444v2,
            codecName: "avc444v2",
            pixelFormat: 32,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            encodedVideoData: annexBData(nalUnitTypes: nalUnitTypes)
        ),
        receivedAt: receivedAt ?? Date(timeIntervalSince1970: Double(id))
    )
}

private func pendingBitmapFrame(id: UInt32) -> RDPPendingDecodeFrame {
    RDPPendingDecodeFrame(
        frame: RDPGraphicsFrameSnapshot(
            frameID: id,
            surfaceID: 1,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            pixelFormat: 32,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)],
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: Data([0, 0, 0, 255]),
            decodedBitmapBytesPerRow: 4
        ),
        receivedAt: Date(timeIntervalSince1970: Double(id))
    )
}

private func frameCountOnlyLimits(maxQueuedVideoFrames: Int) -> RDPFrameDecodeQueueLimits {
    RDPFrameDecodeQueueLimits(
        maxQueuedVideoFrames: maxQueuedVideoFrames,
        maxQueuedVideoLatency: 100,
        maxQueuedVideoBytes: 64 * 1024 * 1024
    )
}

private func annexBData(nalUnitTypes: [UInt8]) -> Data {
    var data = Data()
    for nalUnitType in nalUnitTypes {
        data.append(contentsOf: [0x00, 0x00, 0x01, nalUnitType, 0xFF])
    }
    return data
}
