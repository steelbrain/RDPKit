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

@Test func decodedVideoCompositorPresentsFullOutputWithoutCPUCopy() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    let decodedImageBuffer = try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 1,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect]
        ),
        decodedImageBuffer: decodedImageBuffer
    )

    #expect(presentation.imageBuffer === decodedImageBuffer)
    #expect(presentation.frame.contentKind == .video)
    #expect(presentation.frame.destinationRect == outputRect)
}

@Test func decodedVideoCompositorMaterializesDirectFrameForLaterPartialUpdate() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    _ = try compositor.presentation(
        for: videoFrame(
            id: 1,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )
    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 2,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
}

@Test func decodedVideoCompositorPreservesAVC444ChromaOutsideLaterLumaMask() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    let initialBuffer = try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    _ = try compositor.presentation(
        for: RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444v2,
            codecName: "avc444v2",
            pixelFormat: 32,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            mappedOutputRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect],
            encodedVideoData: annexBData(nalUnitTypes: [7, 8, 5]),
            auxiliaryEncodedVideoData: annexBData(nalUnitTypes: [1]),
            auxiliaryRegionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            avc444SubframeLayout: .yuv420AndChroma420
        ),
        decodedImageBuffer: initialBuffer
    )

    let updatedBuffer = try bgraPixelBuffer(width: 4, height: 4, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    let presentation = try compositor.presentation(
        for: RDPGraphicsFrameSnapshot(
            frameID: 2,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444v2,
            codecName: "avc444v2",
            pixelFormat: 32,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            mappedOutputRect: outputRect,
            destinationRect: outputRect,
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            encodedVideoData: annexBData(nalUnitTypes: [1]),
            avc444SubframeLayout: .yuv420Only
        ),
        decodedImageBuffer: updatedBuffer
    )

    #expect(presentation.imageBuffer !== updatedBuffer)
    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 3, y: 3, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
}

@Test func decodedVideoCompositorMaterializesDirectFrameBehindBitmapOverlay() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2)
    _ = try compositor.presentation(
        for: RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc420,
            codecName: "avc420",
            pixelFormat: 32,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            mappedOutputRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect],
            encodedVideoData: annexBData(nalUnitTypes: [7, 8, 5])
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )
    let presentation = try compositor.presentation(
        for: bitmapFrame(
            id: 2,
            surfaceID: 2,
            width: 2,
            height: 2,
            pixel: [0xA0, 0xB0, 0xC0, 0xFF],
            graphicsOutputRect: outputRect,
            destinationRect: RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
    #expect(try bgraPixel(atX: 3, y: 0, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
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

@Test func decodedVideoCompositorAppliesScaledOutputMapping() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let presentation = try compositor.presentation(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 10, top: 20, right: 12, bottom: 22),
            mappedOutputRect: RDPFrameRect(left: 10, top: 20, right: 14, bottom: 23),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            regionRects: [RDPFrameRect(left: 1, top: 0, right: 2, bottom: 2)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0x33, 0x44, 0x55, 0xFF])
    )

    #expect(presentation.frame.surfaceRect == RDPFrameRect(left: 10, top: 20, right: 12, bottom: 22))
    #expect(presentation.frame.mappedOutputRect == RDPFrameRect(left: 10, top: 20, right: 14, bottom: 23))
    #expect(presentation.frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 14, bottom: 23))
    #expect(presentation.frame.regionRects == [RDPFrameRect(left: 12, top: 20, right: 14, bottom: 23)])
    #expect(CVPixelBufferGetWidth(presentation.imageBuffer) == 4)
    #expect(CVPixelBufferGetHeight(presentation.imageBuffer) == 3)
    #expect(try bgraPixel(atX: 3, y: 2, in: presentation.imageBuffer) == [0x33, 0x44, 0x55, 0xFF])
}

@Test func decodedVideoCompositorAppliesAVC444AuxiliaryRegions() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444,
        codecName: "avc444",
        pixelFormat: 32,
        surfaceRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2),
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65]),
        auxiliaryEncodedVideoData: Data([0x00, 0x00, 0x01, 0x41]),
        auxiliaryRegionRects: [RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2)],
        avc444SubframeLayout: .yuv420AndChroma420
    )

    let presentation = try compositor.presentation(
        for: frame,
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    #expect(presentation.frame.regionRects == [
        RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2),
    ])
    #expect(try bgraPixel(atX: 3, y: 1, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
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

@Test func decodedVideoCompositorCombinesMappedSurfacesInGraphicsOutput() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2)
    let leftPresentation = try compositor.presentation(
        for: bitmapFrame(
            id: 1,
            surfaceID: 1,
            width: 2,
            height: 2,
            pixel: [0x10, 0x20, 0x30, 0xFF],
            graphicsOutputRect: outputRect,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    #expect(leftPresentation.frame.destinationRect == outputRect)
    #expect(CVPixelBufferGetWidth(leftPresentation.imageBuffer) == 4)
    #expect(CVPixelBufferGetHeight(leftPresentation.imageBuffer) == 2)
    #expect(try bgraPixel(atX: 0, y: 0, in: leftPresentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
    #expect(try bgraPixel(atX: 2, y: 0, in: leftPresentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])

    let rightPresentation = try compositor.presentation(
        for: bitmapFrame(
            id: 1,
            surfaceID: 2,
            width: 2,
            height: 2,
            pixel: [0xA0, 0xB0, 0xC0, 0xFF],
            graphicsOutputRect: outputRect,
            destinationRect: RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(rightPresentation.frame.codecName == "graphics-output-bgra")
    #expect(rightPresentation.frame.destinationRect == outputRect)
    #expect(rightPresentation.frame.regionRects == [RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2)])
    #expect(try bgraPixel(atX: 1, y: 1, in: rightPresentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
    #expect(try bgraPixel(atX: 3, y: 1, in: rightPresentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
}

@Test func decodedVideoCompositorClearsGraphicsOutputAfterResize() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    _ = try compositor.presentation(
        for: bitmapFrame(
            id: 1,
            width: 4,
            height: 2,
            pixel: [0x10, 0x20, 0x30, 0xFF],
            graphicsOutputRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    let presentation = try compositor.presentation(
        for: bitmapFrame(
            id: 2,
            width: 1,
            height: 2,
            pixel: [0xA0, 0xB0, 0xC0, 0xFF],
            graphicsOutputRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 1, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(CVPixelBufferGetWidth(presentation.imageBuffer) == 2)
    #expect(try bgraPixel(atX: 0, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])
}

@Test func decodeBacklogKeepsVideoFramesInOrderWithinLimit() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 3))

    #expect(backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [7, 8, 5])).isEmpty)
    #expect(backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1])).isEmpty)
    #expect(backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1])).isEmpty)

    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.frames.contains(where: \.resetDecoderBeforeDecode) == false)
}

@Test func decodeBacklogDoesNotTreatAVC444ChromaOnlyUpdateAsResync() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 1))
    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [1]))
    _ = backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1]))
    #expect(backlog.waitingForVideoResync == false)

    let chromaOnly = RDPPendingDecodeFrame(
        frame: RDPGraphicsFrameSnapshot(
            frameID: 3,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444v2,
            codecName: "avc444v2",
            pixelFormat: 32,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
            encodedVideoData: annexBData(nalUnitTypes: [7, 8, 5]),
            avc444SubframeLayout: .chroma420Only
        ),
        receivedAt: Date(timeIntervalSince1970: 3)
    )
    let dropped = backlog.append(chromaOnly)

    #expect(dropped.isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.waitingForVideoResync == false)
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

@Test func decodeBacklogRetainsIndependentSurfaceResyncFrames() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 3))

    _ = backlog.append(pendingVideoFrame(id: 1, surfaceID: 1, nalUnitTypes: [7, 8, 5]))
    _ = backlog.append(pendingVideoFrame(id: 2, surfaceID: 2, nalUnitTypes: [7, 8, 5]))
    _ = backlog.append(pendingVideoFrame(id: 3, surfaceID: 1, nalUnitTypes: [1]))
    let dropped = backlog.append(pendingVideoFrame(id: 4, surfaceID: 2, nalUnitTypes: [7, 8, 5]))

    #expect(dropped.map(\.frame.frameID) == [2])
    #expect(backlog.frames.map(\.frame.frameID) == [1, 3, 4])
    #expect(backlog.frames.map(\.resetDecoderBeforeDecode) == [true, false, true])
    #expect(backlog.waitingForVideoResync == false)
}

@Test func decodeBacklogPreservesSurfacesWithoutARecoveryPoint() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 2))

    _ = backlog.append(pendingVideoFrame(id: 1, surfaceID: 1, nalUnitTypes: [1]))
    _ = backlog.append(pendingVideoFrame(id: 2, surfaceID: 2, nalUnitTypes: [7, 8, 5]))
    let dropped = backlog.append(pendingVideoFrame(id: 3, surfaceID: 1, nalUnitTypes: [1]))

    #expect(dropped.isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.waitingForVideoResync == false)

    #expect(backlog.append(pendingVideoFrame(id: 4, surfaceID: 2, nalUnitTypes: [1])).isEmpty)
    let droppedSurfaceOneDelta = backlog.append(pendingVideoFrame(id: 5, surfaceID: 1, nalUnitTypes: [1]))
    #expect(droppedSurfaceOneDelta.isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3, 4, 5])
}

@Test func decodeBacklogPreservesReferenceChainWhenOverflowHasNoKeyframe() {
    var backlog = RDPFrameDecodeBacklog(limits: frameCountOnlyLimits(maxQueuedVideoFrames: 2))

    _ = backlog.append(pendingVideoFrame(id: 1, nalUnitTypes: [1]))
    _ = backlog.append(pendingVideoFrame(id: 2, nalUnitTypes: [1]))
    let droppedOverflow = backlog.append(pendingVideoFrame(id: 3, nalUnitTypes: [1]))

    #expect(droppedOverflow.isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3])
    #expect(backlog.waitingForVideoResync == false)

    let droppedDelta = backlog.append(pendingVideoFrame(id: 4, nalUnitTypes: [1]))
    #expect(droppedDelta.isEmpty)
    #expect(backlog.frames.map(\.frame.frameID) == [1, 2, 3, 4])
    #expect(backlog.waitingForVideoResync == false)

    let droppedForRecovery = backlog.append(pendingVideoFrame(id: 5, nalUnitTypes: [7, 8, 5]))
    #expect(droppedForRecovery.map(\.frame.frameID) == [1, 2, 3, 4])
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

@Test func latestFrameDecodeQueueCompletesAfterPresentingFrame() {
    let processed = DispatchSemaphore(value: 0)
    let events = DecodeEventLog()
    let queue = RDPLatestFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in
            events.append("decoded")
        },
        onDecodeFailed: { _, _ in },
        onSkippedFrames: { _, _ in }
    )

    queue.submit(pendingBitmapFrame(id: 1).frame, receivedAt: Date()) {
        events.append("processed")
        processed.signal()
    }

    #expect(processed.wait(timeout: .now() + 2) == .success)
    #expect(events.snapshot == ["decoded", "processed"])
    queue.cancel()
}

@Test func latestFrameDecodeQueueReportsSuccessfulSynchronousProcessing() throws {
    let queue = RDPLatestFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in },
        onSkippedFrames: { _, _ in }
    )

    let completion = queue.submitAndWait(
        pendingBitmapFrame(id: 1).frame,
        receivedAt: Date(),
        shouldContinue: { true }
    )

    #expect(completion == .decoded)
    try completion.requireDecoded()
    queue.cancel()
}

@Test func latestFrameDecodeQueueReportsDecodeFailure() {
    let queue = RDPLatestFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in },
        onSkippedFrames: { _, _ in }
    )

    let completion = queue.submitAndWait(
        pendingVideoFrame(id: 1, nalUnitTypes: [1]).frame,
        receivedAt: Date(),
        shouldContinue: { true }
    )

    guard case .failed(let errorDescription) = completion else {
        Issue.record("expected decode failure, got \(completion)")
        queue.cancel()
        return
    }
    #expect(errorDescription.isEmpty == false)
    #expect(throws: RDPFrameDecodeQueueError.decodeFailed(errorDescription)) {
        try completion.requireDecoded()
    }
    queue.cancel()
}

@Test func latestFrameDecodeQueueReportsCancellation() {
    let queue = RDPLatestFrameDecodeQueue(
        shouldCancel: { true },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in },
        onSkippedFrames: { _, _ in }
    )

    let completion = queue.submitAndWait(
        pendingBitmapFrame(id: 1).frame,
        receivedAt: Date(),
        shouldContinue: { true }
    )

    #expect(completion == .cancelled)
    #expect(throws: RDPFrameDecodeQueueError.cancelled) {
        try completion.requireDecoded()
    }
}

@Test func latestFrameDecodeQueueReportsCoalescedFrameAsDropped() {
    let decodingStarted = DispatchSemaphore(value: 0)
    let allowDecodeToFinish = DispatchSemaphore(value: 0)
    let dropped = DispatchSemaphore(value: 0)
    let completions = DecodeCompletionLog()
    let queue = RDPLatestFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { presentation, _, _, _ in
            guard presentation.frame.frameID == 1 else {
                return
            }
            decodingStarted.signal()
            _ = allowDecodeToFinish.wait(timeout: .now() + 2)
        },
        onDecodeFailed: { _, _ in },
        onSkippedFrames: { _, _ in }
    )

    queue.submitReportingCompletion(
        pendingBitmapFrame(id: 1).frame,
        receivedAt: Date(),
        onCompleted: { completions.append(frameID: 1, completion: $0) }
    )
    #expect(decodingStarted.wait(timeout: .now() + 2) == .success)
    queue.submitReportingCompletion(
        pendingBitmapFrame(id: 2).frame,
        receivedAt: Date(),
        onCompleted: {
            completions.append(frameID: 2, completion: $0)
            dropped.signal()
        }
    )
    queue.submitReportingCompletion(
        pendingBitmapFrame(id: 3).frame,
        receivedAt: Date(),
        onCompleted: { completions.append(frameID: 3, completion: $0) }
    )

    #expect(dropped.wait(timeout: .now() + 2) == .success)
    #expect(completions.completion(for: 2) == .dropped)
    allowDecodeToFinish.signal()
    queue.cancel()
}

private final class DecodeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }
}

private final class DecodeCompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [UInt32: RDPFrameDecodeCompletion] = [:]

    func append(frameID: UInt32, completion: RDPFrameDecodeCompletion) {
        lock.withLock {
            completions[frameID] = completion
        }
    }

    func completion(for frameID: UInt32) -> RDPFrameDecodeCompletion? {
        lock.withLock { completions[frameID] }
    }
}

private func pendingVideoFrame(
    id: UInt32,
    surfaceID: UInt16 = 1,
    nalUnitTypes: [UInt8],
    receivedAt: Date? = nil
) -> RDPPendingDecodeFrame {
    RDPPendingDecodeFrame(
        frame: RDPGraphicsFrameSnapshot(
            frameID: id,
            surfaceID: surfaceID,
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
    graphicsOutputRect: RDPFrameRect? = nil,
    surfaceRect: RDPFrameRect? = nil,
    mappedOutputRect: RDPFrameRect? = nil,
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
        graphicsOutputRect: graphicsOutputRect,
        surfaceRect: surfaceRect,
        mappedOutputRect: mappedOutputRect,
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

private func bitmapFrame(
    id: UInt32,
    surfaceID: UInt16 = 1,
    width: UInt16,
    height: UInt16,
    pixel: [UInt8],
    graphicsOutputRect: RDPFrameRect? = nil,
    destinationRect: RDPFrameRect? = nil
) -> RDPGraphicsFrameSnapshot {
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
        surfaceID: surfaceID,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 32,
        graphicsOutputRect: graphicsOutputRect,
        destinationRect: destinationRect ?? RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [destinationRect ?? RDPFrameRect(left: 0, top: 0, right: width, bottom: height)],
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
