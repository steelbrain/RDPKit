import CoreVideo
import Foundation
@testable import RDPKit
import Testing

@Test func decodedVideoCompositorBlitsPartialUpdatesIntoPersistentSurface() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let firstPresentation = try compositor.presentation(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    #expect(firstPresentation.frame.contentKind == .bitmap)
    #expect(firstPresentation.frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(CVPixelBufferGetWidth(firstPresentation.imageBuffer) == 4)
    #expect(CVPixelBufferGetHeight(firstPresentation.imageBuffer) == 4)

    let secondPresentation = try compositor.presentation(
        for: videoFrame(
            id: 2,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            destinationRect: RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(secondPresentation.frame.contentKind == .bitmap)
    #expect(secondPresentation.frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(secondPresentation.frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
    #expect(CVPixelBufferGetWidth(secondPresentation.imageBuffer) == 4)
    #expect(CVPixelBufferGetHeight(secondPresentation.imageBuffer) == 4)
    #expect(try bgraPixel(atX: 0, y: 0, in: secondPresentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
    #expect(try bgraPixel(atX: 1, y: 1, in: secondPresentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 2, y: 2, in: secondPresentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 3, y: 3, in: secondPresentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
}

@Test func decodedVideoCompositorUsesSurfaceRectWhenFirstUpdateIsPartial() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 6, bottom: 5),
            destinationRect: RDPFrameRect(left: 2, top: 1, right: 5, bottom: 3),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 3, bottom: 2)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 3, height: 2, pixel: [0x33, 0x44, 0x55, 0xFF])
    )

    #expect(presentation.frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 6, bottom: 5))
    #expect(presentation.frame.regionRects == [RDPFrameRect(left: 2, top: 1, right: 5, bottom: 3)])
    #expect(CVPixelBufferGetWidth(presentation.imageBuffer) == 6)
    #expect(CVPixelBufferGetHeight(presentation.imageBuffer) == 5)
    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])
    #expect(try bgraPixel(atX: 2, y: 1, in: presentation.imageBuffer) == [0x33, 0x44, 0x55, 0xFF])
    #expect(try bgraPixel(atX: 4, y: 2, in: presentation.imageBuffer) == [0x33, 0x44, 0x55, 0xFF])
}

@Test func decodedVideoCompositorClearsStaleSurfaceOnFullResyncFrame() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    _ = try compositor.presentation(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 2,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(presentation.frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2))
    #expect(CVPixelBufferGetWidth(presentation.imageBuffer) == 2)
    #expect(CVPixelBufferGetHeight(presentation.imageBuffer) == 2)
    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
}

@Test func decodedVideoCompositorSynchronizesBitmapFramesBeforeLaterVideoDeltas() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    _ = try compositor.presentation(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 3, height: 3, pixel: [0x10, 0x20, 0x30, 0xFF])
    )
    _ = try compositor.presentation(
        for: bitmapFrame(
            id: 2,
            width: 3,
            height: 3,
            pixel: [0x60, 0x70, 0x80, 0xFF]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 3, height: 3, pixel: [0x60, 0x70, 0x80, 0xFF])
    )
    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 3,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3),
            destinationRect: RDPFrameRect(left: 1, top: 1, right: 2, bottom: 2),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 1, height: 1, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0x60, 0x70, 0x80, 0xFF])
    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
}

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

private func videoFrame(
    id: UInt32,
    surfaceRect: RDPFrameRect? = nil,
    destinationRect: RDPFrameRect,
    regionRects: [RDPFrameRect],
    nalUnitTypes: [UInt8] = [7, 8, 5]
) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        surfaceRect: surfaceRect,
        destinationRect: destinationRect,
        regionRects: regionRects,
        encodedVideoData: annexBData(nalUnitTypes: nalUnitTypes)
    )
}

private func bgraPixelBuffer(width: Int, height: Int, pixel: [UInt8]) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw PixelBufferTestError.createFailed(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw PixelBufferTestError.missingBaseAddress
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0 ..< height {
        let rowBase = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for column in 0 ..< width {
            let offset = column * 4
            rowBase[offset] = pixel[0]
            rowBase[offset + 1] = pixel[1]
            rowBase[offset + 2] = pixel[2]
            rowBase[offset + 3] = pixel[3]
        }
    }
    return pixelBuffer
}

private func bitmapFrame(id: UInt32, width: UInt16, height: UInt16, pixel: [UInt8]) -> RDPGraphicsFrameSnapshot {
    let bytesPerRow = Int(width) * 4
    var data = Data(repeating: 0, count: bytesPerRow * Int(height))
    data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return
        }
        for row in 0 ..< Int(height) {
            let rowBase = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< Int(width) {
                let offset = column * 4
                rowBase[offset] = pixel[0]
                rowBase[offset + 1] = pixel[1]
                rowBase[offset + 2] = pixel[2]
                rowBase[offset + 3] = pixel[3]
            }
        }
    }
    return RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: width, bottom: height)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: data,
        decodedBitmapBytesPerRow: bytesPerRow
    )
}

private func bgraPixel(atX x: Int, y: Int, in imageBuffer: CVImageBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }
    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
        throw PixelBufferTestError.missingBaseAddress
    }
    let offset = y * CVPixelBufferGetBytesPerRow(imageBuffer) + x * 4
    let pixel = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    return [pixel[0], pixel[1], pixel[2], pixel[3]]
}

private enum PixelBufferTestError: Error {
    case createFailed(CVReturn)
    case missingBaseAddress
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
