import CoreVideo
import Foundation
@testable import RDPKit
import Testing

@Test func decodedVideoCompositorBlitsPartialUpdatesIntoPersistentSurface() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let firstPresentation = try compositor.presented(
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

    let secondPresentation = try compositor.presented(
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
    let presentation = try compositor.presented(
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
    _ = try compositor.presented(
        for: videoFrame(
            id: 1,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )
    let presentation = try compositor.presented(
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
    _ = try compositor.presented(
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
    let presentation = try compositor.presented(
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
    _ = try compositor.presented(
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
    let presentation = try compositor.presented(
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
    let presentation = try compositor.presented(
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

/// Regions are in surface coordinates when any of them ends past the update's size, the one
/// that fits it too: each region the presentation names is where the update copied it.
@Test func decodedVideoCompositorPresentsSurfaceCoordinateRegionsWhereItCopiesThem() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let regionRects = [
        RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2),
        RDPFrameRect(left: 8, top: 0, right: 10, bottom: 2),
    ]
    let presentation = try compositor.presented(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 12, bottom: 2),
            destinationRect: RDPFrameRect(left: 2, top: 0, right: 10, bottom: 2),
            regionRects: regionRects
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 8, height: 2, pixel: [0x33, 0x44, 0x55, 0xFF])
    )

    #expect(presentation.frame.regionRects == regionRects)
    #expect(try bgraPixel(atX: 2, y: 0, in: presentation.imageBuffer) == [0x33, 0x44, 0x55, 0xFF])
    #expect(try bgraPixel(atX: 4, y: 0, in: presentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])
}

@Test func decodedVideoCompositorAppliesScaledOutputMapping() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let presentation = try compositor.presented(
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

    let presentation = try compositor.presented(
        for: frame,
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    #expect(presentation.frame.regionRects == [
        RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2),
    ])
    #expect(try bgraPixel(atX: 3, y: 1, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
}

/// A surface recreated with a deleted surface's ID starts empty, not with its pixels.
@Test func decodedVideoCompositorForgetsDeletedSurfaces() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let surfaceRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    _ = try compositor.presented(
        for: videoFrame(id: 1, surfaceRect: surfaceRect, destinationRect: surfaceRect, regionRects: [surfaceRect]),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    var update = videoFrame(
        id: 2,
        surfaceRect: surfaceRect,
        destinationRect: RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
        nalUnitTypes: [1]
    )
    update.deletedSurfaceIDs = [1]
    let presentation = try compositor.presented(
        for: update,
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])
}

/// Windows mixed mode draws text with other codecs over a video surface; the text shows
/// only inside its regions, and later video keeps it until an update covers the surface.
@Test func decodedVideoCompositorKeepsTextDrawnOverVideo() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    let text: [UInt8] = [0xA0, 0xB0, 0xC0, 0xFF]
    let firstVideo: [UInt8] = [0x10, 0x20, 0x30, 0xFF]
    _ = try compositor.presented(
        for: videoFrame(
            id: 1,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: firstVideo)
    )

    var textFrame = bitmapFrame(id: 2, width: 4, height: 4, pixel: text, graphicsOutputRect: outputRect)
    textFrame.surfaceRect = outputRect
    textFrame.regionRects = [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 2)]
    let textPresentation = try compositor.presented(for: textFrame, decodedImageBuffer: bgraPixelBuffer(
        width: 1,
        height: 1,
        pixel: [0, 0, 0, 0]
    ))
    #expect(try bgraPixel(atX: 1, y: 1, in: textPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 0, y: 0, in: textPresentation.imageBuffer) == firstVideo)
    #expect(try bgraPixel(atX: 3, y: 3, in: textPresentation.imageBuffer) == firstVideo)

    // A full-surface picture that changed only its lower half.
    let secondVideo: [UInt8] = [0x11, 0x21, 0x31, 0xFF]
    let partialPresentation = try compositor.presented(
        for: videoFrame(
            id: 3,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [RDPFrameRect(left: 0, top: 2, right: 4, bottom: 4)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: secondVideo)
    )
    #expect(try bgraPixel(atX: 1, y: 1, in: partialPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 0, y: 0, in: partialPresentation.imageBuffer) == firstVideo)
    #expect(try bgraPixel(atX: 0, y: 3, in: partialPresentation.imageBuffer) == secondVideo)

    let thirdVideo: [UInt8] = [0x12, 0x22, 0x32, 0xFF]
    let resyncPresentation = try compositor.presented(
        for: videoFrame(
            id: 4,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [RDPFrameRect(left: 3, top: 0, right: 4, bottom: 4)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: thirdVideo)
    )
    #expect(try bgraPixel(atX: 1, y: 1, in: resyncPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 3, y: 0, in: resyncPresentation.imageBuffer) == thirdVideo)

    let coveringVideo: [UInt8] = [0x13, 0x23, 0x33, 0xFF]
    let coveringBuffer = try bgraPixelBuffer(width: 4, height: 4, pixel: coveringVideo)
    let coveringPresentation = try compositor.presented(
        for: videoFrame(
            id: 5,
            graphicsOutputRect: outputRect,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: [outputRect],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: coveringBuffer
    )
    #expect(coveringPresentation.imageBuffer === coveringBuffer)
}

/// Only the block a partial update copies is converted from the YUV picture, at the rows
/// the regions name (Core Image counts rows from the bottom).
@Test func decodedVideoCompositorCopiesPartialUpdatesFromYUVPictures() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let surfaceRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)
    let presentation = try compositor.presented(
        for: videoFrame(
            id: 1,
            surfaceRect: surfaceRect,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 32, bottom: 20),
            regionRects: [RDPFrameRect(left: 4, top: 4, right: 12, bottom: 10)]
        ),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    )

    #expect(try bgraPixel(atX: 4, y: 4, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 11, y: 7, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 4, y: 8, in: presentation.imageBuffer)[1] > 215)
    #expect(try bgraPixel(atX: 11, y: 9, in: presentation.imageBuffer)[1] > 215)
    #expect(try bgraPixel(atX: 3, y: 8, in: presentation.imageBuffer) == [0, 0, 0, 0])
    #expect(try bgraPixel(atX: 4, y: 10, in: presentation.imageBuffer) == [0, 0, 0, 0])
}

/// On a surface mapped to scaled output, text drawn over video is merged into the unscaled
/// surface and scaled with it, and later video keeps it.
@Test func decodedVideoCompositorKeepsTextDrawnOverScaledVideo() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let surfaceRect = RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    let video: [UInt8] = [0x10, 0x20, 0x30, 0xFF]
    let text: [UInt8] = [0xA0, 0xB0, 0xC0, 0xFF]
    _ = try compositor.presented(
        for: videoFrame(
            id: 1,
            graphicsOutputRect: outputRect,
            surfaceRect: surfaceRect,
            mappedOutputRect: outputRect,
            destinationRect: surfaceRect,
            regionRects: [surfaceRect]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: video)
    )

    var textFrame = bitmapFrame(id: 2, width: 2, height: 2, pixel: text, graphicsOutputRect: outputRect)
    textFrame.surfaceRect = surfaceRect
    textFrame.mappedOutputRect = outputRect
    textFrame.regionRects = [RDPFrameRect(left: 1, top: 0, right: 2, bottom: 1)]
    let textPresentation = try compositor.presented(for: textFrame, decodedImageBuffer: bgraPixelBuffer(
        width: 2,
        height: 2,
        pixel: text
    ))
    #expect(textPresentation.frame.regionRects == [RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2)])
    #expect(try bgraPixel(atX: 2, y: 0, in: textPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 3, y: 1, in: textPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 1, y: 1, in: textPresentation.imageBuffer) == video)
    #expect(try bgraPixel(atX: 3, y: 3, in: textPresentation.imageBuffer) == video)

    let laterVideo: [UInt8] = [0x11, 0x21, 0x31, 0xFF]
    let videoPresentation = try compositor.presented(
        for: videoFrame(
            id: 3,
            graphicsOutputRect: outputRect,
            surfaceRect: surfaceRect,
            mappedOutputRect: outputRect,
            destinationRect: surfaceRect,
            regionRects: [RDPFrameRect(left: 0, top: 1, right: 2, bottom: 2)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 2, height: 2, pixel: laterVideo)
    )
    #expect(try bgraPixel(atX: 3, y: 1, in: videoPresentation.imageBuffer) == text)
    #expect(try bgraPixel(atX: 0, y: 0, in: videoPresentation.imageBuffer) == video)
    #expect(try bgraPixel(atX: 0, y: 3, in: videoPresentation.imageBuffer) == laterVideo)
}

/// A scroll of a surface whose video went straight to the output copies the decoded
/// picture, not black.
@Test func decodedVideoCompositorCopiesDecodedVideoWithinASurface() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)
    _ = try compositor.presented(
        for: videoFrame(id: 1, graphicsOutputRect: outputRect, surfaceRect: outputRect, destinationRect: outputRect, regionRects: [outputRect]),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    )

    let presentation = try #require(try compositor.presentation(applying: surfaceCopyFrame(
        id: 2,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .surface(1), destination: .surface(1), blocks: [.init(
            source: RDPFrameRect(left: 0, top: 4, right: 32, bottom: 12),
            destination: RDPFrameRect(left: 0, top: 24, right: 32, bottom: 32)
        )])
    )))

    #expect(presentation.frame.regionRects == [RDPFrameRect(left: 0, top: 24, right: 32, bottom: 32)])
    // Rows 4..<8 of the picture are dark and 8..<12 light.
    #expect(try bgraPixel(atX: 3, y: 25, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 3, y: 29, in: presentation.imageBuffer)[1] > 215)
    #expect(try bgraPixel(atX: 3, y: 2, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 3, y: 20, in: presentation.imageBuffer)[1] > 215)
}

/// The cache holds decoded pixels until the server evicts the entry.
@Test func decodedVideoCompositorRestoresCachedVideoUntilEvicted() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)
    _ = try compositor.presented(
        for: videoFrame(id: 1, graphicsOutputRect: outputRect, surfaceRect: outputRect, destinationRect: outputRect, regionRects: [outputRect]),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    )
    let entry = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 8)
    let store = RDPGraphicsSurfaceCopy(source: .surface(1), destination: .cacheSlot(3), blocks: [.init(
        source: RDPFrameRect(left: 0, top: 4, right: 32, bottom: 12),
        destination: entry
    )])
    let restore = RDPGraphicsSurfaceCopy(source: .cacheSlot(3), destination: .surface(1), blocks: [.init(
        source: entry,
        destination: RDPFrameRect(left: 0, top: 24, right: 32, bottom: 32)
    )])

    #expect(try compositor.presentation(applying: surfaceCopyFrame(id: 2, outputRect: outputRect, copy: store)) == nil)
    let presentation = try #require(try compositor.presentation(applying: surfaceCopyFrame(id: 2, outputRect: outputRect, copy: restore)))
    #expect(try bgraPixel(atX: 3, y: 25, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 3, y: 29, in: presentation.imageBuffer)[1] > 215)
    #expect(try compositor.presentation(applying: surfaceCopyFrame(
        id: 3,
        outputRect: outputRect,
        copy: restore,
        evictedCacheSlots: [3]
    )) == nil)
}

/// Video of a surface not mapped to the output shows nothing until a copy brings it there.
@Test func decodedVideoCompositorKeepsVideoOfUnmappedSurfacesForCopies() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)

    #expect(try compositor.presentation(
        for: videoFrame(id: 1, surfaceID: 2, graphicsOutputRect: outputRect, destinationRect: outputRect, regionRects: [outputRect]),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    ) == nil)
    let presentation = try #require(try compositor.presentation(applying: surfaceCopyFrame(
        id: 1,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .surface(2), destination: .surface(1), blocks: [.init(
            source: RDPFrameRect(left: 0, top: 4, right: 32, bottom: 12),
            destination: RDPFrameRect(left: 0, top: 24, right: 32, bottom: 32)
        )])
    )))

    #expect(try bgraPixel(atX: 3, y: 25, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 3, y: 29, in: presentation.imageBuffer)[1] > 215)
    #expect(try bgraPixel(atX: 3, y: 2, in: presentation.imageBuffer) == [0, 0, 0, 0])
}

/// A ClearCodec glyph stored over decoded video keeps that video for where it is drawn.
@Test func decodedVideoCompositorDrawsClearCodecGlyphsOfDecodedVideo() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)
    _ = try compositor.presented(
        for: videoFrame(id: 1, graphicsOutputRect: outputRect, surfaceRect: outputRect, destinationRect: outputRect, regionRects: [outputRect]),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    )
    let glyph = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)

    #expect(try compositor.presentation(applying: surfaceCopyFrame(
        id: 2,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .surface(1), destination: .clearCodecGlyph(5), blocks: [.init(source: glyph, destination: glyph)])
    )) == nil)
    let presentation = try #require(try compositor.presentation(applying: surfaceCopyFrame(
        id: 2,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .clearCodecGlyph(5), destination: .surface(1), blocks: [.init(
            source: glyph,
            destination: RDPFrameRect(left: 8, top: 24, right: 12, bottom: 28)
        )])
    )))

    #expect(try bgraPixel(atX: 9, y: 25, in: presentation.imageBuffer)[1] < 40)
    #expect(try bgraPixel(atX: 13, y: 25, in: presentation.imageBuffer)[1] > 215)
}

/// Alpha for decoded video keeps the video's colour.
@Test func decodedVideoCompositorSetsTheAlphaOfDecodedVideo() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 32, bottom: 32)
    _ = try compositor.presented(
        for: videoFrame(id: 1, graphicsOutputRect: outputRect, surfaceRect: outputRect, destinationRect: outputRect, regionRects: [outputRect]),
        decodedImageBuffer: try yuvPixelBuffer(width: 32, height: 32, darkRows: 0 ..< 8)
    )
    var alpha = bitmapFrame(id: 2, width: 4, height: 4, pixel: [0, 0, 0, 0x40], graphicsOutputRect: outputRect)
    alpha.contentKind = .alpha
    alpha.surfaceRect = outputRect
    alpha.regionRects = [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)]

    let presentation = try #require(try compositor.presentation(applying: alpha))

    #expect(presentation.frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)])
    let changed = try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer)
    #expect(changed[1] < 40)
    #expect(changed[3] == 0x40)
    #expect(try bgraPixel(atX: 3, y: 3, in: presentation.imageBuffer)[3] == 0xFF)
}

/// MS-RDPEGFX 2.2.4.4 crops every picture by its region rectangles, a keyframe's too: the
/// surface keeps its pixels outside them.
@Test func decodedVideoCompositorKeepsPixelsOutsideAKeyframesRegions() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let surfaceRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    _ = try compositor.presented(
        for: videoFrame(id: 1, surfaceRect: surfaceRect, destinationRect: surfaceRect, regionRects: [surfaceRect]),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    let presentation = try compositor.presented(
        for: videoFrame(
            id: 2,
            surfaceRect: surfaceRect,
            destinationRect: surfaceRect,
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            nalUnitTypes: [7, 8, 5]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 1, y: 1, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
    #expect(try bgraPixel(atX: 3, y: 3, in: presentation.imageBuffer) == [0x10, 0x20, 0x30, 0xFF])
}

@Test func decodedVideoCompositorSynchronizesBitmapFramesBeforeLaterVideoDeltas() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    _ = try compositor.presented(
        for: videoFrame(
            id: 1,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 3, bottom: 3)]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 3, height: 3, pixel: [0x10, 0x20, 0x30, 0xFF])
    )
    _ = try compositor.presented(
        for: bitmapFrame(
            id: 2,
            width: 3,
            height: 3,
            pixel: [0x60, 0x70, 0x80, 0xFF]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 3, height: 3, pixel: [0x60, 0x70, 0x80, 0xFF])
    )
    let presentation = try compositor.presented(
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

@Test func decodedVideoCompositorDiscardsBitmapSurfaceShorterThanItsLayout() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    var truncatedBitmap = bitmapFrame(id: 1, width: 4, height: 4, pixel: [0x60, 0x70, 0x80, 0xFF])
    truncatedBitmap.decodedBitmapData = truncatedBitmap.decodedBitmapData?.prefix(16)
    _ = try compositor.presented(
        for: truncatedBitmap,
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0x60, 0x70, 0x80, 0xFF])
    )

    let presentation = try compositor.presented(
        for: videoFrame(
            id: 2,
            surfaceRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
            regionRects: [RDPFrameRect(left: 0, top: 3, right: 4, bottom: 4)],
            nalUnitTypes: [1]
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 4, pixel: [0xA0, 0xB0, 0xC0, 0xFF])
    )

    #expect(try bgraPixel(atX: 0, y: 0, in: presentation.imageBuffer) == [0x00, 0x00, 0x00, 0x00])
    #expect(try bgraPixel(atX: 3, y: 3, in: presentation.imageBuffer) == [0xA0, 0xB0, 0xC0, 0xFF])
}

@Test func decodedVideoCompositorCombinesMappedSurfacesInGraphicsOutput() throws {
    let compositor = RDPDecodedVideoSurfaceCompositor()
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2)
    let leftPresentation = try compositor.presented(
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

    let rightPresentation = try compositor.presented(
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
    _ = try compositor.presented(
        for: bitmapFrame(
            id: 1,
            width: 4,
            height: 2,
            pixel: [0x10, 0x20, 0x30, 0xFF],
            graphicsOutputRect: RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2)
        ),
        decodedImageBuffer: try bgraPixelBuffer(width: 4, height: 2, pixel: [0x10, 0x20, 0x30, 0xFF])
    )

    let presentation = try compositor.presented(
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

@Test func latestFrameDecodeQueueReportsSuccessfulSynchronousProcessing() throws {
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in }
    )

    let completion = queue.submitAndWait(
        queuedBitmapFrame(id: 1),
        receivedAt: Date(),
        shouldContinue: { true }
    )

    #expect(completion == .decoded)
    try completion.requireDecoded()
    queue.cancel()
}

@Test func frameDecodeQueuePresentsUpdatesOfItsOwnPixelsWithoutDecoding() throws {
    let presented = Locked<[RDPGraphicsFrameSnapshot]>([])
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { presentation, _, _, _ in presented.withLock { $0.append(presentation.frame) } },
        onDecodeFailed: { _, _ in }
    )
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    var bitmap = bitmapFrame(id: 1, width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF], graphicsOutputRect: outputRect)
    bitmap.surfaceRect = outputRect
    let copy = surfaceCopyFrame(
        id: 1,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .surface(1), destination: .surface(1), blocks: [.init(
            source: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            destination: RDPFrameRect(left: 2, top: 2, right: 4, bottom: 4)
        )])
    )

    #expect(queue.submitAndWait(bitmap, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    #expect(queue.submitAndWait(copy, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    #expect(presented.value.map(\.regionRects).last == [RDPFrameRect(left: 2, top: 2, right: 4, bottom: 4)])
    var alpha = bitmapFrame(id: 1, width: 4, height: 4, pixel: [0, 0, 0, 0x40], graphicsOutputRect: outputRect)
    alpha.contentKind = .alpha
    alpha.surfaceRect = outputRect
    alpha.regionRects = [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)]
    #expect(queue.submitAndWait(alpha, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    #expect(presented.value.map(\.regionRects).last == [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)])
    queue.cancel()
}

/// The session reports deletions and evictions once, on the next snapshot, whether or not
/// that snapshot decodes.
@Test func frameDecodeQueueForgetsDeletedStateOfFramesThatFail() throws {
    let presented = Locked<[RDPGraphicsFrameSnapshot]>([])
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { presentation, _, _, _ in presented.withLock { $0.append(presentation.frame) } },
        onDecodeFailed: { _, _ in }
    )
    let outputRect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    var bitmap = bitmapFrame(id: 1, width: 4, height: 4, pixel: [0x10, 0x20, 0x30, 0xFF], graphicsOutputRect: outputRect)
    bitmap.surfaceRect = outputRect
    let corner = RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)
    let store = surfaceCopyFrame(
        id: 1,
        outputRect: outputRect,
        copy: RDPGraphicsSurfaceCopy(source: .surface(1), destination: .cacheSlot(3), blocks: [.init(source: corner, destination: corner)])
    )
    #expect(queue.submitAndWait(bitmap, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    #expect(queue.submitAndWait(store, receivedAt: Date(), shouldContinue: { true }) == .decoded)
    let presentedCount = presented.value.count

    var failing = videoFrame(id: 2, surfaceRect: outputRect, destinationRect: outputRect, regionRects: [outputRect], nalUnitTypes: [1])
    failing.deletedSurfaceIDs = [1]
    failing.evictedCacheSlots = [3]
    guard case .failed = queue.submitAndWait(failing, receivedAt: Date(), shouldContinue: { true }) else {
        Issue.record("expected the video update to fail")
        queue.cancel()
        return
    }

    let later = RDPFrameRect(left: 2, top: 2, right: 4, bottom: 4)
    for copy in [
        RDPGraphicsSurfaceCopy(source: .surface(1), destination: .surface(1), blocks: [.init(source: corner, destination: later)]),
        RDPGraphicsSurfaceCopy(source: .cacheSlot(3), destination: .surface(1), blocks: [.init(source: corner, destination: later)]),
    ] {
        #expect(queue.submitAndWait(surfaceCopyFrame(id: 3, outputRect: outputRect, copy: copy), receivedAt: Date(), shouldContinue: { true }) == .decoded)
    }
    #expect(presented.value.count == presentedCount)
    queue.cancel()
}

@Test func latestFrameDecodeQueueReportsDecodeFailure() {
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in }
    )

    let completion = queue.submitAndWait(
        videoFrame(
            id: 1,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
            regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
            nalUnitTypes: [1]
        ),
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
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { true },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in }
    )

    let completion = queue.submitAndWait(
        queuedBitmapFrame(id: 1),
        receivedAt: Date(),
        shouldContinue: { true }
    )

    #expect(completion == .cancelled)
    #expect(throws: RDPFrameDecodeQueueError.cancelled) {
        try completion.requireDecoded()
    }
}

@Test func latestFrameDecodeQueueReportsFramesSubmittedAfterCancelAsCancelled() {
    let queue = RDPFrameDecodeQueue(
        shouldCancel: { false },
        onDecoded: { _, _, _, _ in },
        onDecodeFailed: { _, _ in }
    )
    queue.cancel()

    let completion = queue.submitAndWait(
        queuedBitmapFrame(id: 1),
        receivedAt: Date(),
        shouldContinue: { true }
    )

    #expect(completion == .cancelled)
}

private extension RDPDecodedVideoSurfaceCompositor {
    /// The presentation of a frame for a surface that has one.
    func presented(for frame: RDPGraphicsFrameSnapshot, decodedImageBuffer: CVImageBuffer) throws -> RDPDecodedFramePresentation {
        try #require(try presentation(for: frame, decodedImageBuffer: decodedImageBuffer))
    }
}

private func videoFrame(
    id: UInt32,
    surfaceID: UInt16 = 1,
    graphicsOutputRect: RDPFrameRect? = nil,
    surfaceRect: RDPFrameRect? = nil,
    mappedOutputRect: RDPFrameRect? = nil,
    destinationRect: RDPFrameRect,
    regionRects: [RDPFrameRect],
    nalUnitTypes: [UInt8] = [7, 8, 5]
) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: surfaceID,
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

/// A full-range 4:2:0 picture, black in `darkRows` and white elsewhere.
private func yuvPixelBuffer(width: Int, height: Int, darkRows: Range<Int>) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw PixelBufferTestError.createFailed(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
        throw PixelBufferTestError.missingBaseAddress
    }
    for row in 0 ..< height {
        memset(
            luma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            darkRows.contains(row) ? 0 : 255,
            width
        )
    }
    for row in 0 ..< height / 2 {
        memset(chroma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)), 128, width)
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

private func surfaceCopyFrame(
    id: UInt32,
    outputRect: RDPFrameRect,
    copy: RDPGraphicsSurfaceCopy,
    evictedCacheSlots: [UInt16] = []
) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "rdpgfx-surface-to-surface",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        graphicsOutputRect: outputRect,
        surfaceRect: outputRect,
        destinationRect: outputRect,
        regionRects: copy.blocks.map(\.destination),
        encodedVideoData: Data(),
        contentKind: .surfaceCopy,
        surfaceCopy: copy,
        evictedCacheSlots: evictedCacheSlots
    )
}

private enum PixelBufferTestError: Error {
    case createFailed(CVReturn)
    case missingBaseAddress
}

private func queuedBitmapFrame(id: UInt32) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
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
    )
}

private func annexBData(nalUnitTypes: [UInt8]) -> Data {
    var data = Data()
    for nalUnitType in nalUnitTypes {
        data.append(contentsOf: [0x00, 0x00, 0x01, nalUnitType, 0xFF])
    }
    return data
}
