import Foundation
@testable import RDPKit
import Testing

@Test func compositorCopiesSurfaceCacheEntriesBackToSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 4, height: 4), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 1,
            cacheKey: 0x0102_0304_0506_0708,
            cacheSlot: 7,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x09, 0x08, 0x07, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try cacheToSurfaceMessage(cacheSlot: 7, surfaceID: 1, points: [RDPGFXPoint16(x: 2, y: 2)]),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 42))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.frameID == 42)
    #expect(frame.codecName == "surface-bgra")
    #expect(frame.contentKind == .bitmap)
    #expect(frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(frame.decodedBitmapBytesPerRow == 16)
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 16) == [0x09, 0x08, 0x07, 0xFF])
    #expect(pixel(atX: 2, y: 2, data: bitmapData, bytesPerRow: 16) == [0x01, 0x02, 0x03, 0xFF])
    #expect(compositor.makeFrame(frameID: 43) == nil)
}

@Test func compositorDeletesSurfaceState() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 20, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 20,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(try deleteSurfaceMessage(surfaceID: 20), clearCodec: clearCodec)

    #expect(compositor.makeFrame(frameID: 25) == nil)
    #expect(compositor.surfaceRect(surfaceID: 20) == nil)
}

@Test func compositorPreservesSurfacesCacheAndContextsAcrossGraphicsReset() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 1,
            cacheKey: 1,
            cacheSlot: 1,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 1,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 7,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    try compositor.process(try resetGraphicsMessage(width: 1920, height: 1080), clearCodec: clearCodec)
    try compositor.process(
        try cacheToSurfaceMessage(cacheSlot: 1, surfaceID: 1, points: [RDPGFXPoint16(x: 1, y: 1)]),
        clearCodec: clearCodec
    )
    try compositor.process(
        try deleteEncodingContextMessage(surfaceID: 1, codecContextID: 7),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 26))
    let bitmapData = try #require(frame.decodedBitmapData)
    #expect(compositor.outputRect() == RDPFrameRect(left: 0, top: 0, right: 1920, bottom: 1080))
    #expect(frame.graphicsOutputRect == compositor.outputRect())
    #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 256) == [0x01, 0x02, 0x03, 0xFF])
}

@Test func compositorValidatesResetAndSurfaceLifetime() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try createSurfaceMessage(surfaceID: 1, width: 2, height: 2),
            clearCodec: clearCodec
        )
    }
    try compositor.process(try deleteSurfaceMessage(surfaceID: 1), clearCodec: clearCodec)
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(try deleteSurfaceMessage(surfaceID: 1), clearCodec: clearCodec)
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try makeGraphicsMessage(commandID: RDPGFXCommandID.resetGraphics, payload: Data()),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorEmitsEveryDirtySurfaceAtFrameEnd() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 4, outputHeight: 2)
    let clearCodec = RDPClearCodecDecoder()
    for surfaceID: UInt16 in [1, 2] {
        try compositor.process(
            try createSurfaceMessage(surfaceID: surfaceID, width: 2, height: 2),
            clearCodec: clearCodec
        )
        try compositor.process(
            try mapSurfaceToOutputMessage(surfaceID: surfaceID, x: UInt32(surfaceID - 1) * 2, y: 0),
            clearCodec: clearCodec
        )
        try compositor.process(
            try solidFillMessage(
                surfaceID: surfaceID,
                color: [UInt8(surfaceID), 0x02, 0x03, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
            ),
            clearCodec: clearCodec
        )
    }

    let frames = compositor.makeFrames(frameID: 27)

    #expect(frames.map(\.surfaceID) == [1, 2])
    #expect(frames.map(\.frameID) == [27, 27])
    #expect(frames.map(\.graphicsOutputRect) == [
        RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2),
        RDPFrameRect(left: 0, top: 0, right: 4, bottom: 2),
    ])
    #expect(frames.map(\.destinationRect) == [
        RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        RDPFrameRect(left: 2, top: 0, right: 4, bottom: 2),
    ])
    #expect(compositor.makeFrames(frameID: 28).isEmpty)
}

@Test func compositorDoesNotEmitUnmappedOffscreenSurfaces() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
        ),
        clearCodec: clearCodec
    )

    #expect(compositor.surfaceRect(surfaceID: 1) == nil)
    #expect(compositor.makeFrames(frameID: 29).isEmpty)
}

@Test func compositorUsesSolidFillAlphaOnlyForARGBSurfaces() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    for (surfaceID, pixelFormat) in [
        (UInt16(1), RDPGFXPixelFormat.argb8888),
        (UInt16(2), RDPGFXPixelFormat.xrgb8888),
    ] {
        try compositor.process(
            try createSurfaceMessage(surfaceID: surfaceID, width: 1, height: 1, pixelFormat: pixelFormat),
            clearCodec: clearCodec
        )
        try compositor.process(
            try mapSurfaceToOutputMessage(surfaceID: surfaceID, x: 0, y: 0),
            clearCodec: clearCodec
        )
        try compositor.process(
            try solidFillMessage(
                surfaceID: surfaceID,
                color: [0x01, 0x02, 0x03, 0x40],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
            ),
            clearCodec: clearCodec
        )
    }

    let frames = compositor.makeFrames(frameID: 30)
    let argbData = try #require(frames.first { $0.surfaceID == 1 }?.decodedBitmapData)
    let xrgbData = try #require(frames.first { $0.surfaceID == 2 }?.decodedBitmapData)
    #expect(Array(argbData) == [0x01, 0x02, 0x03, 0x40])
    #expect(Array(xrgbData) == [0x01, 0x02, 0x03, 0xFF])
}

/// Windows mixed mode draws text beside video on one surface. The snapshot keeps only what
/// other codecs drew last, so the decoded video is not painted over from this compositor.
@Test func compositorLeavesAreasVideoWroteLastOutOfItsSnapshots() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    for surfaceID: UInt16 in [1, 2] {
        try compositor.process(
            try createSurfaceMessage(surfaceID: surfaceID, width: 2, height: 2),
            clearCodec: clearCodec
        )
        try compositor.process(
            try mapSurfaceToOutputMessage(surfaceID: surfaceID, x: 0, y: 0),
            clearCodec: clearCodec
        )
        try compositor.process(
            try solidFillMessage(
                surfaceID: surfaceID,
                color: [UInt8(surfaceID), 0x02, 0x03, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
            ),
            clearCodec: clearCodec
        )
    }

    compositor.noteVideo(RDPGraphicsFrameSnapshot(
        frameID: 29,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 2)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    ))
    let frames = compositor.makeFrames(frameID: 29)

    #expect(frames.map(\.surfaceID) == [1, 2])
    #expect(frames.map(\.regionRects) == [
        [RDPFrameRect(left: 1, top: 0, right: 2, bottom: 2)],
        [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
    ])
    #expect(compositor.makeFrames(frameID: 30).isEmpty)
}

/// Video regions are relative to the update's destination; the area around them stays dirty.
@Test func compositorKeepsTextAroundVideoDrawnInsideIt() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 4, height: 4), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4)]
        ),
        clearCodec: clearCodec
    )

    compositor.noteVideo(RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    ))

    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[
        RDPFrameRect(left: 0, top: 0, right: 4, bottom: 1),
        RDPFrameRect(left: 0, top: 3, right: 4, bottom: 4),
        RDPFrameRect(left: 0, top: 1, right: 1, bottom: 3),
        RDPFrameRect(left: 3, top: 1, right: 4, bottom: 3),
    ]])
}

/// gnome-remote-desktop encodes AVC420 into unmapped surface 1 and copies it
/// to mapped surface 0 every frame (gnome fixture, sequence 143-144). The copy
/// brings pixels the compositor never decoded; neither this frame nor a later
/// one without video may paint them as a black bitmap over the video.
@Test func compositorDoesNotPaintCopiedVideoAsBlackInALaterFrame() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 64, outputHeight: 32)
    let clearCodec = RDPClearCodecDecoder()
    let fullSurface = RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 32)
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 64, height: 32), clearCodec: clearCodec)
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 64, height: 32), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    let video = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(fullSurface),
        regionRects: [RDPFrameRect(fullSurface)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
    compositor.noteVideo(video)
    let copy = try surfaceToSurfaceMessage(
        sourceSurfaceID: 1,
        destinationSurfaceID: 0,
        sourceRect: fullSurface,
        destinationPoints: [RDPGFXPoint16(x: 0, y: 0)]
    )

    // The decoder never got surface 1, so the client retargets its video instead.
    #expect(try compositor.process(copy, clearCodec: clearCodec) == nil)
    #expect(compositor.makeFrames(frameID: 1).isEmpty)
    // The next frame has no updates.
    #expect(compositor.makeFrames(frameID: 2).isEmpty)
}

/// A scroll of a surface carrying video copies pixels only the decoder holds, so the
/// decoder makes the copy; the session paints only what it drew there itself.
@Test func compositorHandsCopiesOfDecodedVideoToTheDecoder() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 64, outputHeight: 32)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 64, height: 32), clearCodec: clearCodec)
    try compositor.process(try createSurfaceMessage(surfaceID: 2, width: 64, height: 32), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    compositor.noteVideo(fullSurfaceVideo(surfaceID: 0, width: 64, height: 32))
    #expect(compositor.makeFrames(frameID: 1).isEmpty)

    // Text over the video, then its top half scrolled down.
    try compositor.process(
        try solidFillMessage(surfaceID: 0, color: [0x01, 0x02, 0x03, 0xFF], rects: [RDPGFXRect16(left: 0, top: 0, right: 8, bottom: 8)]),
        clearCodec: clearCodec
    )
    let scroll = try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 0,
            destinationSurfaceID: 0,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 16),
            destinationPoints: [RDPGFXPoint16(x: 0, y: 16)]
        ),
        clearCodec: clearCodec
    )
    #expect(scroll?.surfaceCopy == RDPGraphicsSurfaceCopy(source: .surface(0), destination: .surface(0), blocks: [.init(
        source: RDPFrameRect(left: 0, top: 0, right: 64, bottom: 16),
        destination: RDPFrameRect(left: 0, top: 16, right: 64, bottom: 32)
    )]))
    // The decoder's copy lacks the text, which the session paints at both places.
    #expect(compositor.makeFrames(frameID: 2).map(\.regionRects) == [[
        RDPFrameRect(left: 0, top: 0, right: 8, bottom: 8),
        RDPFrameRect(left: 0, top: 16, right: 8, bottom: 24),
    ]])

    // A copy of pixels only the session holds is the session's to paint.
    try compositor.process(
        try solidFillMessage(surfaceID: 2, color: [0x04, 0x05, 0x06, 0xFF], rects: [RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 32)]),
        clearCodec: clearCodec
    )
    let sessionCopy = try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 2,
            destinationSurfaceID: 0,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 16, bottom: 16),
            destinationPoints: [RDPGFXPoint16(x: 48, y: 0)]
        ),
        clearCodec: clearCodec
    )
    #expect(sessionCopy == nil)
    #expect(compositor.makeFrames(frameID: 3).map(\.regionRects) == [[RDPFrameRect(left: 48, top: 0, right: 64, bottom: 16)]])

    // The decoder holds what its copies put into an unmapped surface, and copies it on.
    #expect(!compositor.isOnDecoder(surfaceID: 2))
    try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 0,
            destinationSurfaceID: 2,
            sourceRect: RDPGFXRect16(left: 16, top: 16, right: 32, bottom: 32),
            destinationPoints: [RDPGFXPoint16(x: 0, y: 0)]
        ),
        clearCodec: clearCodec
    )
    #expect(compositor.isOnDecoder(surfaceID: 2))
    let copyBack = try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 2,
            destinationSurfaceID: 0,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 16, bottom: 16),
            destinationPoints: [RDPGFXPoint16(x: 48, y: 16)]
        ),
        clearCodec: clearCodec
    )
    #expect(copyBack?.surfaceCopy?.source == .surface(2))
    #expect(compositor.makeFrames(frameID: 4).isEmpty)
}

/// Cache entries of decoded video are the decoder's too. It drops them when the server
/// evicts them, or refills their slots with pixels only the session holds.
@Test func compositorHandsCacheCopiesOfDecodedVideoToTheDecoder() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 64, outputHeight: 32)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 64, height: 32), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    compositor.noteVideo(fullSurfaceVideo(surfaceID: 0, width: 64, height: 32))

    let store = try compositor.process(
        try surfaceToCacheMessage(surfaceID: 0, cacheKey: 1, cacheSlot: 3, sourceRect: RDPGFXRect16(left: 0, top: 0, right: 16, bottom: 16)),
        clearCodec: clearCodec
    )
    #expect(store?.surfaceCopy == RDPGraphicsSurfaceCopy(source: .surface(0), destination: .cacheSlot(3), blocks: [.init(
        source: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        destination: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)
    )]))
    let restore = try compositor.process(
        try cacheToSurfaceMessage(cacheSlot: 3, surfaceID: 0, points: [RDPGFXPoint16(x: 48, y: 16)]),
        clearCodec: clearCodec
    )
    #expect(restore?.surfaceCopy == RDPGraphicsSurfaceCopy(source: .cacheSlot(3), destination: .surface(0), blocks: [.init(
        source: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        destination: RDPFrameRect(left: 48, top: 16, right: 64, bottom: 32)
    )]))
    #expect(compositor.makeFrames(frameID: 1).isEmpty)
    #expect(compositor.decoderCacheSlots == [3])

    try compositor.process(try evictCacheEntryMessage(cacheSlot: 3), clearCodec: clearCodec)
    try compositor.process(
        try surfaceToCacheMessage(surfaceID: 0, cacheKey: 2, cacheSlot: 4, sourceRect: RDPGFXRect16(left: 16, top: 0, right: 32, bottom: 16)),
        clearCodec: clearCodec
    )
    try compositor.process(
        try solidFillMessage(surfaceID: 0, color: [0x01, 0x02, 0x03, 0xFF], rects: [RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 32)]),
        clearCodec: clearCodec
    )
    let refill = try compositor.process(
        try surfaceToCacheMessage(surfaceID: 0, cacheKey: 3, cacheSlot: 4, sourceRect: RDPGFXRect16(left: 16, top: 0, right: 32, bottom: 16)),
        clearCodec: clearCodec
    )
    #expect(refill == nil)
    #expect(compositor.takeEvictedDecoderCacheSlots() == [3, 4])
    #expect(compositor.takeEvictedDecoderCacheSlots().isEmpty)
    #expect(compositor.decoderCacheSlots.isEmpty)
}

/// ClearCodec layers draw over the destination: over video, only what they drew is the
/// session's to paint.
@Test func compositorKeepsVideoThatClearCodecLayersDoNotCover() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 8, outputHeight: 8)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 8, height: 8), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    compositor.noteVideo(fullSurfaceVideo(surfaceID: 0, width: 8, height: 8))

    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 0,
            codecID: RDPGFXCodecID.clearCodec,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 2, top: 2, right: 6, bottom: 6),
            bitmapData: clearCodecRawRegionStream(width: 2, height: 1, pixels: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        ),
        clearCodec: clearCodec
    )

    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[RDPFrameRect(left: 2, top: 2, right: 4, bottom: 3)]])
}

/// A ClearCodec glyph stored over video keeps video pixels only the decoder holds, so the
/// decoder stores the glyph too, and draws it where the server hits it.
@Test func compositorHandsClearCodecGlyphsOverVideoToTheDecoder() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 8, outputHeight: 8)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 8, height: 8), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    compositor.noteVideo(fullSurfaceVideo(surfaceID: 0, width: 8, height: 8))
    let glyphRect = RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)

    // One covered pixel; the glyph's other three are video.
    var store = clearCodecRawRegionStream(width: 1, height: 1, pixels: [0x10, 0x20, 0x30])
    store[0] = 0x01
    store.insert(contentsOf: [0x05, 0x00], at: 2)
    let stored = try compositor.process(
        try wireToSurface1Message(
            surfaceID: 0,
            codecID: RDPGFXCodecID.clearCodec,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2),
            bitmapData: store
        ),
        clearCodec: clearCodec
    )
    #expect(stored?.surfaceCopy == RDPGraphicsSurfaceCopy(source: .surface(0), destination: .clearCodecGlyph(5), blocks: [.init(
        source: glyphRect,
        destination: glyphRect
    )]))
    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)]])

    let hit = try compositor.process(
        try wireToSurface1Message(
            surfaceID: 0,
            codecID: RDPGFXCodecID.clearCodec,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 4, top: 4, right: 6, bottom: 6),
            bitmapData: Data([0x03, 0x01, 0x05, 0x00])
        ),
        clearCodec: clearCodec
    )
    #expect(hit?.surfaceCopy == RDPGraphicsSurfaceCopy(source: .clearCodecGlyph(5), destination: .surface(0), blocks: [.init(
        source: glyphRect,
        destination: RDPFrameRect(left: 4, top: 4, right: 6, bottom: 6)
    )]))
    // The decoder's glyph lacks the covered pixel, which the session paints.
    #expect(compositor.makeFrames(frameID: 2).map(\.regionRects) == [[RDPFrameRect(left: 4, top: 4, right: 5, bottom: 5)]])
}

/// Alpha over video, as Windows sends for RemoteApp windows: only the decoder has the
/// colour of what video wrote last, so it takes the alpha there itself.
@Test func compositorHandsAlphaOverVideoToTheDecoder() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 4, outputHeight: 4)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 0, width: 4, height: 4), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 0, x: 0, y: 0), clearCodec: clearCodec)
    var video = fullSurfaceVideo(surfaceID: 0, width: 4, height: 4)
    video.regionRects = [RDPFrameRect(left: 0, top: 1, right: 4, bottom: 4)]
    compositor.noteVideo(video)

    let alpha = try #require(try compositor.process(
        try wireToSurface1Message(
            surfaceID: 0,
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4),
            bitmapData: alphaBitmapStream(compressed: 0, payload: Data(repeating: 0x40, count: 16))
        ),
        clearCodec: clearCodec
    ))

    #expect(alpha.contentKind == .alpha)
    #expect(alpha.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(alpha.regionRects == [RDPFrameRect(left: 0, top: 1, right: 4, bottom: 4)])
    #expect(pixel(atX: 2, y: 3, data: try #require(alpha.decodedBitmapData), bytesPerRow: 16)[3] == 0x40)
    // The row video never wrote is the session's, colour and alpha.
    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[RDPFrameRect(left: 0, top: 0, right: 4, bottom: 1)]])
}

@Test func compositorCollapsesHeldBackDirtyRectsIntoBoundingBox() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 1_026, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: (0 ..< 1_024).map { RDPGFXRect16(left: $0, top: 0, right: $0 + 1, bottom: 1) }
                + [RDPGFXRect16(left: 1_025, top: 1, right: 1_026, bottom: 2)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)

    let frame = try #require(compositor.makeFrame(frameID: 1))

    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 1_026, bottom: 2)])
}

/// An area drawn twice, or inside one already drawn, is listed once.
@Test func compositorListsEachChangedAreaOnce() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 4, outputHeight: 4)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 4, height: 4), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    let row = RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 1)
    let pixel = RDPGFXRect16(left: 1, top: 0, right: 2, bottom: 1)

    try compositor.process(
        try solidFillMessage(surfaceID: 1, color: [0x01, 0x02, 0x03, 0xFF], rects: [row, row, pixel]),
        clearCodec: clearCodec
    )
    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[RDPFrameRect(row)]])
    try compositor.process(
        try solidFillMessage(surfaceID: 1, color: [0x01, 0x02, 0x03, 0xFF], rects: [pixel, row]),
        clearCodec: clearCodec
    )
    #expect(compositor.makeFrames(frameID: 2).map(\.regionRects) == [[RDPFrameRect(row)]])
}

/// Areas drawn over each other in part list their shared pixels once, cutting whichever
/// side leaves fewer rectangles.
@Test func compositorListsPartlyOverlappingAreasOnce() throws {
    let compositor = RDPGFXSurfaceCompositor(outputWidth: 8, outputHeight: 4)
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 8, height: 4), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    func fill(_ rects: [RDPGFXRect16]) throws {
        try compositor.process(try solidFillMessage(surfaceID: 1, color: [0x01, 0x02, 0x03, 0xFF], rects: rects), clearCodec: clearCodec)
    }

    // Either cut leaves three rectangles; the earlier one loses the shared pixels.
    try fill([RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 2), RDPGFXRect16(left: 1, top: 1, right: 4, bottom: 4)])
    #expect(compositor.makeFrames(frameID: 1).map(\.regionRects) == [[
        RDPFrameRect(left: 0, top: 0, right: 3, bottom: 1),
        RDPFrameRect(left: 0, top: 1, right: 1, bottom: 2),
        RDPFrameRect(left: 1, top: 1, right: 4, bottom: 4),
    ]])
    // A glyph over the edge of a fill keeps only what sticks out, not three pieces of the fill.
    try fill([RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 4), RDPGFXRect16(left: 3, top: 1, right: 6, bottom: 3)])
    #expect(compositor.makeFrames(frameID: 2).map(\.regionRects) == [[
        RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4),
        RDPFrameRect(left: 4, top: 1, right: 6, bottom: 3),
    ]])
}

@Test func compositorEvictsCachedSurfaceEntries() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 21, width: 3, height: 3), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 21,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 21,
            cacheKey: 0x0102_0304_0506_0708,
            cacheSlot: 9,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)
        ),
        clearCodec: clearCodec
    )
    _ = compositor.makeFrame(frameID: 26)

    try compositor.process(try evictCacheEntryMessage(cacheSlot: 9), clearCodec: clearCodec)
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(try evictCacheEntryMessage(cacheSlot: 9), clearCodec: clearCodec)
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try cacheToSurfaceMessage(cacheSlot: 9, surfaceID: 21, points: [RDPGFXPoint16(x: 1, y: 1)]),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorEnforcesNegotiatedSmallCacheSlotLimit() throws {
    let compositor = RDPGFXSurfaceCompositor(
        capabilitySet: .version8(flags: RDPGFXCapabilityFlags.smallCache)
    )
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 30, width: 1, height: 1), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToCacheMessage(
                surfaceID: 30,
                cacheKey: 1,
                cacheSlot: RDPGFXCacheSlot.smallCacheMaximumSlot + 1,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorEnforcesImplicitVersion103SmallCacheLimit() throws {
    var capabilityData = Data()
    capabilityData.appendLittleEndianUInt32(0)
    let compositor = RDPGFXSurfaceCompositor(capabilitySet: RDPGFXCapabilitySet(
        version: RDPGFXCapabilityVersion.version103,
        data: capabilityData
    ))
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 30, width: 1, height: 1), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToCacheMessage(
                surfaceID: 30,
                cacheKey: 1,
                cacheSlot: RDPGFXCacheSlot.smallCacheMaximumSlot + 1,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorEnforcesCacheByteBudgetAndAccountsForReplacement() throws {
    let compositor = RDPGFXSurfaceCompositor(maximumCacheByteCount: 16, maximumCacheSlot: 2)
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 31, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 31,
            cacheKey: 1,
            cacheSlot: 1,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)
        ),
        clearCodec: clearCodec
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToCacheMessage(
                surfaceID: 31,
                cacheKey: 2,
                cacheSlot: 2,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
            ),
            clearCodec: clearCodec
        )
    }

    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 31,
            cacheKey: 3,
            cacheSlot: 1,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 31,
            cacheKey: 4,
            cacheSlot: 2,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
        ),
        clearCodec: clearCodec
    )
    try compositor.process(try evictCacheEntryMessage(cacheSlot: 2), clearCodec: clearCodec)
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 31,
            cacheKey: 5,
            cacheSlot: 1,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)
        ),
        clearCodec: clearCodec
    )
}

@Test func compositorBlitsClearCodecTilesIntoMappedSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 3, width: 3, height: 3), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 3, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 3,
            codecID: RDPGFXCodecID.clearCodec,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2),
            bitmapData: clearCodecRawRegionStream(width: 2, height: 1, pixels: [
                0x10, 0x20, 0x30,
                0x40, 0x50, 0x60,
            ])
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 9))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.frameID == 9)
    #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 13, bottom: 23))
    #expect(frame.regionRects == [RDPFrameRect(left: 11, top: 21, right: 13, bottom: 22)])
    #expect(frame.decodedBitmapBytesPerRow == 12)
    #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 12) == [0x10, 0x20, 0x30, 0xFF])
    #expect(pixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 12) == [0x40, 0x50, 0x60, 0xFF])
}

@Test func compositorKeepsSurfacePixelsThatClearCodecLayersDoNotCover() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 3, width: 3, height: 1), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 3, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 3,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 1)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 3,
            codecID: RDPGFXCodecID.clearCodec,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 1),
            bitmapData: clearCodecRawRegionStream(width: 1, height: 1, pixels: [0x10, 0x20, 0x30])
        ),
        clearCodec: clearCodec
    )

    let bitmapData = try #require(compositor.makeFrame(frameID: 1)?.decodedBitmapData)

    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 12) == [0x10, 0x20, 0x30, 0xFF])
    #expect(pixel(atX: 1, y: 0, data: bitmapData, bytesPerRow: 12) == [0x01, 0x02, 0x03, 0xFF])
    #expect(pixel(atX: 2, y: 0, data: bitmapData, bytesPerRow: 12) == [0x01, 0x02, 0x03, 0xFF])
}

@Test func compositorLeavesEmittedFramePixelsUnchanged() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 1, height: 1), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 1, x: 0, y: 0), clearCodec: clearCodec)
    for color: UInt8 in [0x01, 0x02] {
        try compositor.process(
            try solidFillMessage(
                surfaceID: 1,
                color: [color, color, color, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
            ),
            clearCodec: clearCodec
        )
    }
    let first = try #require(compositor.makeFrame(frameID: 1)?.decodedBitmapData)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x03, 0x03, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
        ),
        clearCodec: clearCodec
    )
    let second = try #require(compositor.makeFrame(frameID: 2)?.decodedBitmapData)

    #expect(first == Data([0x02, 0x02, 0x02, 0xFF]))
    #expect(second == Data([0x03, 0x03, 0x03, 0xFF]))
}

@Test func compositorRejectsDestinationRectOutsideSurfaceBeforeDecoding() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 4, height: 4), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 1,
                codecID: RDPGFXCodecID.planar,
                pixelFormat: RDPGFXPixelFormat.xrgb8888,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 0xFFFF, bottom: 0xFFFF),
                bitmapData: Data([0x30, 0x10])
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorAppliesScaledOutputOriginToSurfaceFrame() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 19, width: 3, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try mapSurfaceToScaledOutputMessage(
            surfaceID: 19,
            x: 40,
            y: 50,
            targetWidth: 6,
            targetHeight: 4
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try solidFillMessage(
            surfaceID: 19,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 1, top: 0, right: 3, bottom: 2)]
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 24))

    #expect(frame.surfaceRect == RDPFrameRect(left: 40, top: 50, right: 43, bottom: 52))
    #expect(frame.mappedOutputRect == RDPFrameRect(left: 40, top: 50, right: 46, bottom: 54))
    #expect(compositor.mappedOutputRect(surfaceID: 19) == RDPFrameRect(left: 40, top: 50, right: 46, bottom: 54))
    // The snapshot is unscaled, like video; the decoder scales what it composes.
    #expect(frame.destinationRect == RDPFrameRect(left: 40, top: 50, right: 43, bottom: 52))
    #expect(frame.regionRects == [RDPFrameRect(left: 41, top: 50, right: 43, bottom: 52)])
    #expect(frame.decodedBitmapBytesPerRow == 12)
}

@Test func compositorBlitsUncompressedBitmapIntoMappedSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 11, width: 4, height: 3), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 11, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 11,
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2),
            bitmapData: Data([
                0x10, 0x20, 0x30, 0x40,
                0x50, 0x60, 0x70, 0x80,
            ])
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 16))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 14, bottom: 23))
    #expect(frame.regionRects == [RDPFrameRect(left: 11, top: 21, right: 13, bottom: 22)])
    #expect(frame.decodedBitmapBytesPerRow == 16)
    #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 16) == [0x10, 0x20, 0x30, 0xFF])
    #expect(pixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 16) == [0x50, 0x60, 0x70, 0xFF])
}

@Test func compositorBlitsPlanarBitmapIntoMappedSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 32, width: 3, height: 2), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 32, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 32,
            codecID: RDPGFXCodecID.planar,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2),
            bitmapData: Data([
                0x00,
                0x40, 0x80,
                0x11, 0x22,
                0x33, 0x44,
                0x55, 0x66,
                0x00,
            ])
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 30))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 13, bottom: 22))
    #expect(frame.regionRects == [RDPFrameRect(left: 11, top: 21, right: 13, bottom: 22)])
    #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 12) == [0x55, 0x33, 0x11, 0x40])
    #expect(pixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 12) == [0x66, 0x44, 0x22, 0x80])
}

@Test func compositorAppliesAlphaBitmapWithoutChangingColorChannels() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 13, width: 3, height: 2), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 13, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 13,
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 2),
            bitmapData: Data(repeating: 0x44, count: 24)
        ),
        clearCodec: clearCodec
    )
    _ = compositor.makeFrame(frameID: 17)

    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 13,
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 1, top: 0, right: 3, bottom: 1),
            bitmapData: alphaBitmapStream(compressed: 0, payload: Data([0x11, 0x22]))
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 18))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 11, top: 20, right: 13, bottom: 21)])
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 12) == [0x44, 0x44, 0x44, 0xFF])
    #expect(pixel(atX: 1, y: 0, data: bitmapData, bytesPerRow: 12) == [0x44, 0x44, 0x44, 0x11])
    #expect(pixel(atX: 2, y: 0, data: bitmapData, bytesPerRow: 12) == [0x44, 0x44, 0x44, 0x22])
}

@Test func compositorAppliesCompressedAlphaBitmap() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 14, width: 3, height: 1), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 14, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 14,
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 1),
            bitmapData: alphaBitmapStream(compressed: 1, payload: Data([0x7F, 0x03]))
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 19))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 12) == [0x00, 0x00, 0x00, 0x7F])
    #expect(pixel(atX: 2, y: 0, data: bitmapData, bytesPerRow: 12) == [0x00, 0x00, 0x00, 0x7F])
}

@Test func compositorCopiesBetweenSurfaces() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 16, width: 3, height: 2), clearCodec: clearCodec)
    try compositor.process(try createSurfaceMessage(surfaceID: 17, width: 4, height: 3), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 17, x: 30, y: 40), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 16,
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 2),
            bitmapData: Data([
                0x01, 0x02, 0x03, 0xFF,
                0x04, 0x05, 0x06, 0xFF,
                0x07, 0x08, 0x09, 0xFF,
                0x10, 0x20, 0x30, 0xFF,
                0x40, 0x50, 0x60, 0xFF,
                0x70, 0x80, 0x90, 0xFF,
            ])
        ),
        clearCodec: clearCodec
    )
    _ = compositor.makeFrame(frameID: 20)

    try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 16,
            destinationSurfaceID: 17,
            sourceRect: RDPGFXRect16(left: 1, top: 0, right: 3, bottom: 2),
            destinationPoints: [RDPGFXPoint16(x: 1, y: 1)]
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 21))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.surfaceID == 17)
    #expect(frame.regionRects == [RDPFrameRect(left: 31, top: 41, right: 33, bottom: 43)])
    #expect(pixel(atX: 1, y: 1, data: bitmapData, bytesPerRow: 16) == [0x04, 0x05, 0x06, 0xFF])
    #expect(pixel(atX: 2, y: 1, data: bitmapData, bytesPerRow: 16) == [0x07, 0x08, 0x09, 0xFF])
    #expect(pixel(atX: 1, y: 2, data: bitmapData, bytesPerRow: 16) == [0x40, 0x50, 0x60, 0xFF])
    #expect(pixel(atX: 2, y: 2, data: bitmapData, bytesPerRow: 16) == [0x70, 0x80, 0x90, 0xFF])
}

@Test func compositorReplicatesWithinSameSurfaceUsingSourceSnapshot() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 18, width: 4, height: 1), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 18, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 18,
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 4, bottom: 1),
            bitmapData: Data([
                0x01, 0x00, 0x00, 0xFF,
                0x02, 0x00, 0x00, 0xFF,
                0x03, 0x00, 0x00, 0xFF,
                0x04, 0x00, 0x00, 0xFF,
            ])
        ),
        clearCodec: clearCodec
    )
    _ = compositor.makeFrame(frameID: 22)

    try compositor.process(
        try surfaceToSurfaceMessage(
            sourceSurfaceID: 18,
            destinationSurfaceID: 18,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 3, bottom: 1),
            destinationPoints: [RDPGFXPoint16(x: 1, y: 0)]
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 23))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 0, right: 4, bottom: 1)])
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 16) == [0x01, 0x00, 0x00, 0xFF])
    #expect(pixel(atX: 1, y: 0, data: bitmapData, bytesPerRow: 16) == [0x01, 0x00, 0x00, 0xFF])
    #expect(pixel(atX: 2, y: 0, data: bitmapData, bytesPerRow: 16) == [0x02, 0x00, 0x00, 0xFF])
    #expect(pixel(atX: 3, y: 0, data: bitmapData, bytesPerRow: 16) == [0x03, 0x00, 0x00, 0xFF])
}

@Test func compositorBlitsCAVideoRemoteFXTilesIntoMappedSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 5, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 5, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 5,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 11))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.frameID == 11)
    #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84))
    #expect(frame.regionRects == [RDPFrameRect(left: 10, top: 20, right: 74, bottom: 84)])
    #expect(frame.decodedBitmapBytesPerRow == 256)
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorOffsetsCAVideoRemoteFXTileByDestinationRect() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 6, width: 96, height: 96), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 6, x: 10, y: 20), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 6,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 16, top: 8, right: 80, bottom: 72),
            bitmapData: cavideoRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 12))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.destinationRect == RDPFrameRect(left: 10, top: 20, right: 106, bottom: 116))
    #expect(frame.regionRects == [RDPFrameRect(left: 26, top: 28, right: 90, bottom: 92)])
    #expect(frame.decodedBitmapBytesPerRow == 384)
    #expect(pixel(atX: 15, y: 8, data: bitmapData, bytesPerRow: 384) == [0x00, 0x00, 0x00, 0x00])
    #expect(pixel(atX: 16, y: 8, data: bitmapData, bytesPerRow: 384) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 79, y: 71, data: bitmapData, bytesPerRow: 384) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 80, y: 71, data: bitmapData, bytesPerRow: 384) == [0x00, 0x00, 0x00, 0x00])
}

@Test func compositorClipsCAVideoRemoteFXTileToSurfaceBounds() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 7, width: 32, height: 32), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 7, x: 3, y: 4), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 7,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 13))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.destinationRect == RDPFrameRect(left: 3, top: 4, right: 35, bottom: 36))
    #expect(frame.regionRects == [RDPFrameRect(left: 3, top: 4, right: 35, bottom: 36)])
    #expect(frame.decodedBitmapBytesPerRow == 128)
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 128) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 31, y: 31, data: bitmapData, bytesPerRow: 128) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorClipsCAVideoRemoteFXTileToRegion() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 8, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 8,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream(
                regionX: 16,
                regionY: 8,
                regionWidth: 10,
                regionHeight: 12
            )
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 27))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 16, top: 8, right: 26, bottom: 20)])
    #expect(pixel(atX: 15, y: 8, data: bitmapData, bytesPerRow: 256) == [0, 0, 0, 0])
    #expect(pixel(atX: 16, y: 8, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 25, y: 19, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 26, y: 19, data: bitmapData, bytesPerRow: 256) == [0, 0, 0, 0])
}

@Test func compositorBlitsCAVideoRemoteFXRLGR1Tile() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 8, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 8,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream(
                contextProperties: 0xA228,
                tileSetProperties: 0x4451
            )
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 14))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64)])
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorBlitsCAPROGRESSIVETileSimple() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 27, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 27, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 27,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 16))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.codecName == "surface-bgra")
    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64)])
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorMarksCAPROGRESSIVERegionsWithSharedTiles() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 27, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 27, x: 0, y: 0), clearCodec: clearCodec)
    let bitmapData = caprogressiveRemoteFXRegionsStream(regions: [
        caprogressiveRemoteFXGrayRegionBlock(
            regionWidth: 32,
            tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
        ),
        caprogressiveRemoteFXGrayRegionBlock(
            regionX: 32,
            regionWidth: 32,
            quantCount: 0,
            tiles: []
        ),
    ])
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 27,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: bitmapData
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 28))
    let decoded = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [
        RDPFrameRect(left: 0, top: 0, right: 32, bottom: 64),
        RDPFrameRect(left: 32, top: 0, right: 64, bottom: 64),
    ])
    #expect(pixel(atX: 0, y: 0, data: decoded, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 63, y: 63, data: decoded, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorClipsCAPROGRESSIVETileSimpleAtSurfaceBounds() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 28, width: 96, height: 96), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 28, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 28,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream(
                regionX: 64,
                regionY: 64,
                tileXIndex: 1,
                tileYIndex: 1
            )
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 17))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 64, top: 64, right: 96, bottom: 96)])
    #expect(pixel(atX: 63, y: 63, data: bitmapData, bytesPerRow: 384) == [0x00, 0x00, 0x00, 0x00])
    #expect(pixel(atX: 64, y: 64, data: bitmapData, bytesPerRow: 384) == [0x80, 0x80, 0x80, 0xFF])
    #expect(pixel(atX: 95, y: 95, data: bitmapData, bytesPerRow: 384) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorRejectsSurfacesBeyondTheAllocationBudget() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try createSurfaceMessage(surfaceID: 1, width: 65_535, height: 65_535),
            clearCodec: clearCodec
        )
    }
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 1_920, height: 1_080), clearCodec: clearCodec)
}

// Like FreeRDP, a progressive tile outside the surface's tile grid rejects the PDU, so a
// server cannot grow per-tile state for positions the surface does not have.
@Test func compositorRejectsCAPROGRESSIVETilesOutsideSurfaceBounds() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 32, width: 64, height: 64), clearCodec: clearCodec)
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 32,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 0,
                pixelFormat: 0x20,
                bitmapData: caprogressiveRemoteFXGrayTileStream(
                    regionX: 64,
                    regionY: 0,
                    tileXIndex: 1,
                    tileYIndex: 0
                )
            ),
            clearCodec: clearCodec
        )
    }
    #expect(compositor.makeFrame(frameID: 18) == nil)
}

@Test func compositorIgnoresCAPROGRESSIVETileSimpleTailData() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 30, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 30, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 30,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream(tailData: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 18))
    let bitmapData = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64)])
    #expect(pixel(atX: 32, y: 32, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorRejectsCAPROGRESSIVEDifferenceTileWithoutReference() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 29, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 29,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 0,
                pixelFormat: 0x20,
                bitmapData: caprogressiveRemoteFXGrayTileStream(tileFlags: 1)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorAppliesCAPROGRESSIVESubBandDifferenceTile() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 29, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 29, x: 0, y: 0), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 29,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTilesStream(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(
                    xIndex: 0,
                    yIndex: 0,
                    yData: rlgrSingleOneComponent()
                )]
            )
        ),
        clearCodec: clearCodec
    )
    let originalFrame = try #require(compositor.makeFrame(frameID: 18))
    let originalBitmapData = try #require(originalFrame.decodedBitmapData)
    let grayBitmapData = Data((0 ..< 64 * 64).flatMap { _ in [UInt8](arrayLiteral: 0x80, 0x80, 0x80, 0xFF) })
    #expect(originalBitmapData != grayBitmapData)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 29,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 1,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream(frameIndex: 2, tileFlags: 1)
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 19))
    let bitmapData = try #require(frame.decodedBitmapData)
    #expect(bitmapData == originalBitmapData)
}

@Test func compositorDiscardsCAPROGRESSIVEReferenceWhenSurfaceIsDeleted() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 29, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 29,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 0,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )
    try compositor.process(try deleteSurfaceMessage(surfaceID: 29), clearCodec: clearCodec)
    try compositor.process(try createSurfaceMessage(surfaceID: 29, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 29,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 1,
                pixelFormat: 0x20,
                bitmapData: caprogressiveRemoteFXGrayTileStream(frameIndex: 2, tileFlags: 1)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsWireToSurface2WithNonCAPROGRESSIVECodec() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 31, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 31,
                codecID: RDPGFXCodecID.cavideo,
                codecContextID: 0,
                pixelFormat: 0x20,
                bitmapData: Data()
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsCAVideoRemoteFXUnsupportedContextProperties() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 8,
                codecID: RDPGFXCodecID.cavideo,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
                bitmapData: cavideoRemoteFXGrayTileStream(contextProperties: 0xA808)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorIgnoresCAVideoRemoteFXAdvisoryProperties() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(try mapSurfaceToOutputMessage(surfaceID: 8, x: 0, y: 0), clearCodec: clearCodec)

    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 8,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream(
                contextID: 42,
                contextProperties: 0x8027,
                tileSetIndex: 42,
                tileSetProperties: 0xD3CE,
                tileSetTileSize: 42
            )
        ),
        clearCodec: clearCodec
    )

    let frame = try #require(compositor.makeFrame(frameID: 16))
    let bitmapData = try #require(frame.decodedBitmapData)
    #expect(pixel(atX: 0, y: 0, data: bitmapData, bytesPerRow: 256) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func compositorRejectsCAVideoRemoteFXUnsupportedTileSetEntropy() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 8,
                codecID: RDPGFXCodecID.cavideo,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
                bitmapData: cavideoRemoteFXGrayTileStream(tileSetProperties: 0x4851)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorIgnoresCAVideoRemoteFXTilesOutsideSurfaceBounds() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 9, width: 32, height: 32), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface1Message(
            surfaceID: 9,
            codecID: RDPGFXCodecID.cavideo,
            pixelFormat: 0x20,
            destinationRect: RDPGFXRect16(left: 0, top: 0, right: 128, bottom: 64),
            bitmapData: cavideoRemoteFXGrayTileStream(
                channelWidth: 128,
                tileXIndex: 1
            )
        ),
        clearCodec: clearCodec
    )

    #expect(compositor.makeFrame(frameID: 15) == nil)
}

@Test func compositorReportsClearCodecDecodeFailures() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 4, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.truncated(needed: 1, remaining: 0)) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 4,
                codecID: RDPGFXCodecID.clearCodec,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2),
                bitmapData: Data([0x00])
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorReportsUncompressedBitmapLengthMismatch() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 12, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 12,
                codecID: RDPGFXCodecID.uncompressed,
                pixelFormat: RDPGFXPixelFormat.xrgb8888,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2),
                bitmapData: Data(repeating: 0, count: 15)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorReportsAlphaBitmapDecodeFailures() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 15, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 15,
                codecID: RDPGFXCodecID.alpha,
                pixelFormat: RDPGFXPixelFormat.argb8888,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2),
                bitmapData: alphaBitmapStream(compressed: 0, payload: Data([0xAA, 0xBB, 0xCC]))
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSurfaceToCacheSourceRectOutsideSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 22, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToCacheMessage(
                surfaceID: 22,
                cacheKey: 0x0102_0304_0506_0708,
                cacheSlot: 10,
                sourceRect: RDPGFXRect16(left: 1, top: 1, right: 3, bottom: 2)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSurfaceToCacheWithMissingSourceSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToCacheMessage(
                surfaceID: 99,
                cacheKey: 0x0102_0304_0506_0708,
                cacheSlot: 10,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSurfaceToSurfaceSourceRectOutsideSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 23, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(try createSurfaceMessage(surfaceID: 24, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToSurfaceMessage(
                sourceSurfaceID: 23,
                destinationSurfaceID: 24,
                sourceRect: RDPGFXRect16(left: 0, top: 1, right: 2, bottom: 3),
                destinationPoints: [RDPGFXPoint16(x: 0, y: 0)]
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSurfaceToSurfaceWithMissingSourceSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 24, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToSurfaceMessage(
                sourceSurfaceID: 99,
                destinationSurfaceID: 24,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1),
                destinationPoints: [RDPGFXPoint16(x: 0, y: 0)]
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsCacheToSurfaceWithMissingCacheSlot() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 25, width: 2, height: 2), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try cacheToSurfaceMessage(cacheSlot: 10, surfaceID: 25, points: [RDPGFXPoint16(x: 0, y: 0)]),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsNegativeSignedDestinationPoints() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 26, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try solidFillMessage(
            surfaceID: 26,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
        ),
        clearCodec: clearCodec
    )
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 26,
            cacheKey: 0x0102_0304_0506_0708,
            cacheSlot: 11,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
        ),
        clearCodec: clearCodec
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try cacheToSurfaceMessage(cacheSlot: 11, surfaceID: 26, points: [RDPGFXPoint16(x: -1, y: 0)]),
            clearCodec: clearCodec
        )
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToSurfaceMessage(
                sourceSurfaceID: 26,
                destinationSurfaceID: 26,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1),
                destinationPoints: [RDPGFXPoint16(x: 0, y: -1)]
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSurfaceMappingWithMissingSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try mapSurfaceToOutputMessage(surfaceID: 99, x: 0, y: 0),
            clearCodec: clearCodec
        )
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try mapSurfaceToScaledOutputMessage(
                surfaceID: 99,
                x: 0,
                y: 0,
                targetWidth: 2,
                targetHeight: 2
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorIgnoresSurfaceMappingsOutsideCoordinateRange() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 2, height: 2), clearCodec: clearCodec)
    try compositor.process(
        try mapSurfaceToOutputMessage(surfaceID: 1, x: UInt32.max, y: UInt32.max),
        clearCodec: clearCodec
    )
    try compositor.process(
        try solidFillMessage(
            surfaceID: 1,
            color: [0x01, 0x02, 0x03, 0xFF],
            rects: [RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2)]
        ),
        clearCodec: clearCodec
    )

    #expect(compositor.surfaceRect(surfaceID: 1) == nil)
    #expect(compositor.makeFrames(frameID: 1).isEmpty)

    try compositor.process(
        try mapSurfaceToScaledOutputMessage(
            surfaceID: 1,
            x: UInt32.max,
            y: UInt32.max,
            targetWidth: 2,
            targetHeight: 2
        ),
        clearCodec: clearCodec
    )

    #expect(compositor.mappedOutputRect(surfaceID: 1) == nil)
    #expect(compositor.makeFrames(frameID: 2).isEmpty)
}

/// Every frame allocates the scaled target, so its size is bounded like a surface.
@Test func compositorRejectsOversizedScaledOutputTargets() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 2, height: 2), clearCodec: clearCodec)

    for (width, height): (UInt32, UInt32) in [(UInt32.max, 2), (2, 32_767), (32_766, 32_766)] {
        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            try compositor.process(
                try mapSurfaceToScaledOutputMessage(surfaceID: 1, x: 0, y: 0, targetWidth: width, targetHeight: height),
                clearCodec: clearCodec
            )
        }
    }
    try compositor.process(
        try mapSurfaceToScaledOutputMessage(surfaceID: 1, x: 0, y: 0, targetWidth: 16_384, targetHeight: 16_384),
        clearCodec: clearCodec
    )
}

@Test func compositorRejectsVideoUpdatesWithInvalidSurfaceBounds() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 99,
                codecID: RDPGFXCodecID.avc420,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 2, bottom: 2),
                bitmapData: Data([0x01])
            ),
            clearCodec: clearCodec
        )
    }

    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 2, height: 2), clearCodec: clearCodec)
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 1,
                codecID: RDPGFXCodecID.avc444,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 1, top: 0, right: 3, bottom: 2),
                bitmapData: Data([0x01])
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorTracksAndDeletesProgressiveCodecContexts() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 1,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 42,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTileStream()
        ),
        clearCodec: clearCodec
    )

    try compositor.process(
        try deleteEncodingContextMessage(surfaceID: 1, codecContextID: 42),
        clearCodec: clearCodec
    )
    try compositor.process(
        try deleteEncodingContextMessage(surfaceID: 1, codecContextID: 42),
        clearCodec: clearCodec
    )
}

@Test func compositorRequiresKnownCodecContextForProgressiveUpgrade() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 41, width: 64, height: 64), clearCodec: clearCodec)
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 41,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 7,
            pixelFormat: 0x20,
            bitmapData: caprogressiveRemoteFXGrayTilesStream(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(
                    blockType: 0xCCC6,
                    xIndex: 0,
                    yIndex: 0,
                    progressiveQuality: 0xFF
                )]
            )
        ),
        clearCodec: clearCodec
    )
    let upgradeStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC7,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF
        )]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 41,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 8,
                pixelFormat: 0x20,
                bitmapData: upgradeStream
            ),
            clearCodec: clearCodec
        )
    }
    try compositor.process(
        try wireToSurface2Message(
            surfaceID: 41,
            codecID: RDPGFXCodecID.caProgressive,
            codecContextID: 7,
            pixelFormat: 0x20,
            bitmapData: upgradeStream
        ),
        clearCodec: clearCodec
    )
}

@Test func compositorRejectsProgressiveUpdateWithMissingSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface2Message(
                surfaceID: 99,
                codecID: RDPGFXCodecID.caProgressive,
                codecContextID: 1,
                pixelFormat: 0x20,
                bitmapData: caprogressiveRemoteFXGrayTileStream()
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorRejectsSolidFillWithMissingSurface() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try solidFillMessage(
                surfaceID: 99,
                color: [0x01, 0x02, 0x03, 0xFF],
                rects: [RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)]
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorValidatesDestinationSurfacesEvenWithoutDestinationPoints() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()
    try compositor.process(try createSurfaceMessage(surfaceID: 1, width: 1, height: 1), clearCodec: clearCodec)
    try compositor.process(
        try surfaceToCacheMessage(
            surfaceID: 1,
            cacheKey: 1,
            cacheSlot: 1,
            sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1)
        ),
        clearCodec: clearCodec
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try cacheToSurfaceMessage(cacheSlot: 1, surfaceID: 99, points: []),
            clearCodec: clearCodec
        )
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try surfaceToSurfaceMessage(
                sourceSurfaceID: 1,
                destinationSurfaceID: 99,
                sourceRect: RDPGFXRect16(left: 0, top: 0, right: 1, bottom: 1),
                destinationPoints: []
            ),
            clearCodec: clearCodec
        )
    }
}

@Test func compositorReportsCAVideoRemoteFXDecodeFailures() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 10, width: 64, height: 64), clearCodec: clearCodec)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try compositor.process(
            try wireToSurface1Message(
                surfaceID: 10,
                codecID: RDPGFXCodecID.cavideo,
                pixelFormat: 0x20,
                destinationRect: RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 64),
                bitmapData: Data([0x00])
            ),
            clearCodec: clearCodec
        )
    }
}

private func fullSurfaceVideo(surfaceID: UInt16, width: UInt16, height: UInt16) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: surfaceID,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: RDPGFXPixelFormat.xrgb8888,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: width, bottom: height)],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )
}

private func createSurfaceMessage(
    surfaceID: UInt16,
    width: UInt16,
    height: UInt16,
    pixelFormat: UInt8 = RDPGFXPixelFormat.argb8888
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(width)
    payload.appendLittleEndianUInt16(height)
    payload.appendUInt8(pixelFormat)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: payload)
}

private func deleteSurfaceMessage(surfaceID: UInt16) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.deleteSurface, payload: payload)
}

private func mapSurfaceToOutputMessage(surfaceID: UInt16, x: UInt32, y: UInt32) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(x)
    payload.appendLittleEndianUInt32(y)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToOutput, payload: payload)
}

private func mapSurfaceToScaledOutputMessage(
    surfaceID: UInt16,
    x: UInt32,
    y: UInt32,
    targetWidth: UInt32,
    targetHeight: UInt32
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(x)
    payload.appendLittleEndianUInt32(y)
    payload.appendLittleEndianUInt32(targetWidth)
    payload.appendLittleEndianUInt32(targetHeight)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToScaledOutput, payload: payload)
}

private func solidFillMessage(surfaceID: UInt16, color: [UInt8], rects: [RDPGFXRect16]) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.append(contentsOf: color)
    payload.appendLittleEndianUInt16(UInt16(rects.count))
    for rect in rects {
        payload.append(rectangleData(rect))
    }
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.solidFill, payload: payload)
}

private func surfaceToCacheMessage(
    surfaceID: UInt16,
    cacheKey: UInt64,
    cacheSlot: UInt16,
    sourceRect: RDPGFXRect16
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt64(cacheKey)
    payload.appendLittleEndianUInt16(cacheSlot)
    payload.append(rectangleData(sourceRect))
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.surfaceToCache, payload: payload)
}

private func evictCacheEntryMessage(cacheSlot: UInt16) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(cacheSlot)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.evictCacheEntry, payload: payload)
}

private func surfaceToSurfaceMessage(
    sourceSurfaceID: UInt16,
    destinationSurfaceID: UInt16,
    sourceRect: RDPGFXRect16,
    destinationPoints: [RDPGFXPoint16]
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(sourceSurfaceID)
    payload.appendLittleEndianUInt16(destinationSurfaceID)
    payload.append(rectangleData(sourceRect))
    payload.appendLittleEndianUInt16(UInt16(destinationPoints.count))
    for point in destinationPoints {
        payload.appendLittleEndianUInt16(UInt16(bitPattern: point.x))
        payload.appendLittleEndianUInt16(UInt16(bitPattern: point.y))
    }
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.surfaceToSurface, payload: payload)
}

private func cacheToSurfaceMessage(
    cacheSlot: UInt16,
    surfaceID: UInt16,
    points: [RDPGFXPoint16]
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(cacheSlot)
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(UInt16(points.count))
    for point in points {
        payload.appendLittleEndianUInt16(UInt16(bitPattern: point.x))
        payload.appendLittleEndianUInt16(UInt16(bitPattern: point.y))
    }
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.cacheToSurface, payload: payload)
}

private func wireToSurface1Message(
    surfaceID: UInt16,
    codecID: UInt16,
    pixelFormat: UInt8,
    destinationRect: RDPGFXRect16,
    bitmapData: Data
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(codecID)
    payload.appendUInt8(pixelFormat)
    payload.append(rectangleData(destinationRect))
    payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
    payload.append(bitmapData)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload)
}

private func wireToSurface2Message(
    surfaceID: UInt16,
    codecID: UInt16,
    codecContextID: UInt32,
    pixelFormat: UInt8,
    bitmapData: Data
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(codecID)
    payload.appendLittleEndianUInt32(codecContextID)
    payload.appendUInt8(pixelFormat)
    payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
    payload.append(bitmapData)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.wireToSurface2, payload: payload)
}

private func deleteEncodingContextMessage(
    surfaceID: UInt16,
    codecContextID: UInt32
) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt32(codecContextID)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.deleteEncodingContext, payload: payload)
}

private func resetGraphicsMessage(width: UInt32, height: UInt32) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt32(width)
    payload.appendLittleEndianUInt32(height)
    payload.appendLittleEndianUInt32(0)
    payload.append(Data(repeating: 0, count: 320))
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.resetGraphics, payload: payload)
}

private func makeGraphicsMessage(commandID: UInt16, payload: Data) throws -> RDPGFXHeader {
    try RDPGFXHeader.parse(from: graphicsMessage(commandID: commandID, payload: payload))
}

private func alphaBitmapStream(compressed: UInt16, payload: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(0x414C)
    data.appendLittleEndianUInt16(compressed)
    data.append(payload)
    return data
}
