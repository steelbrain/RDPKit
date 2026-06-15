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

@Test func compositorBlitsCAVideoRemoteFXRLGR1Tile() throws {
    let compositor = RDPGFXSurfaceCompositor()
    let clearCodec = RDPClearCodecDecoder()

    try compositor.process(try createSurfaceMessage(surfaceID: 8, width: 64, height: 64), clearCodec: clearCodec)
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

private func createSurfaceMessage(surfaceID: UInt16, width: UInt16, height: UInt16) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(width)
    payload.appendLittleEndianUInt16(height)
    payload.appendUInt8(0x21)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: payload)
}

private func mapSurfaceToOutputMessage(surfaceID: UInt16, x: UInt32, y: UInt32) throws -> RDPGFXHeader {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(x)
    payload.appendLittleEndianUInt32(y)
    return try makeGraphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToOutput, payload: payload)
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
        payload.appendLittleEndianUInt16(point.x)
        payload.appendLittleEndianUInt16(point.y)
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

private func makeGraphicsMessage(commandID: UInt16, payload: Data) throws -> RDPGFXHeader {
    var data = Data()
    data.appendLittleEndianUInt16(commandID)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt32(UInt32(8 + payload.count))
    data.append(payload)
    return try RDPGFXHeader.parse(from: data)
}

private func rectangleData(_ rect: RDPGFXRect16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(rect.left)
    data.appendLittleEndianUInt16(rect.top)
    data.appendLittleEndianUInt16(rect.right)
    data.appendLittleEndianUInt16(rect.bottom)
    return data
}

private func clearCodecRawRegionStream(width: UInt16, height: UInt16, pixels: [UInt8]) -> Data {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(13 + pixels.count))
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(width)
    stream.appendLittleEndianUInt16(height)
    stream.appendLittleEndianUInt32(UInt32(pixels.count))
    stream.appendUInt8(0)
    stream.append(contentsOf: pixels)
    return stream
}

private func pixel(atX x: Int, y: Int, data: Data, bytesPerRow: Int) -> [UInt8] {
    let offset = y * bytesPerRow + x * 4
    return Array(data[offset ..< offset + 4])
}
