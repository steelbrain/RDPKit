import Foundation
@testable import RDPKit
import Testing

@Test func parsesSlowPathSynchronizeGraphicsUpdate() throws {
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x02,
        payload: Data([0x03, 0x00, 0xCD, 0xAB])
    )))

    #expect(pdu.typeName == "update")
    #expect(pdu.graphicsUpdate == .synchronize)
}

@Test func parsesSlowPathPaletteGraphicsUpdate() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(0x0002)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(256)
    payload.append(Data(repeating: 0x7F, count: 256 * 3))

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x02,
        payload: payload
    )))

    let update = try #require(pdu.graphicsUpdate)
    guard case let .palette(palette) = update else {
        Issue.record("Expected palette update")
        return
    }
    #expect(palette.entries.count == 256 * 3)
}

@Test func parsesSlowPathBitmapGraphicsUpdate() throws {
    let bitmapStream = Data([0x00, 0x00, 0x00, 0xFF])
    let payload = bitmapUpdatePayload(bitmapStream: bitmapStream)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x02,
        payload: payload
    )))

    let update = try #require(pdu.graphicsUpdate)
    guard case let .bitmap(bitmap) = update else {
        Issue.record("Expected bitmap update")
        return
    }
    #expect(bitmap.rectangles.count == 1)
    #expect(bitmap.rectangles[0].width == 1)
    #expect(bitmap.rectangles[0].height == 1)
    #expect(bitmap.rectangles[0].bitsPerPixel == 32)
    #expect(bitmap.rectangles[0].bitmapDataStream == bitmapStream)
}

@Test func rejectsMalformedSlowPathGraphicsUpdates() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: Data([0x04, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: Data([0x03, 0x00, 0x00, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0002)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt32(255)
        payload.append(Data(repeating: 0, count: 255 * 3))
        _ = try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(type: 0x02, payload: payload))
    }
}

@Test func rejectsSlowPathBitmapUpdateWithReservedFlags() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: bitmapUpdatePayload(
                flags: 0x0002,
                bitmapStream: Data([0x11, 0x22, 0x33, 0x44])
            )
        ))
    }
}

@Test func rejectsSlowPathBitmapUpdateWithNoRectangles() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: Data([0x01, 0x00, 0x00, 0x00])
        ))
    }
}

@Test func rejectsSlowPathBitmapNoCompressionHeaderWithoutCompression() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: bitmapUpdatePayload(
                flags: 0x0400,
                bitmapStream: Data([0x11, 0x22, 0x33, 0x44])
            )
        ))
    }
}

@Test func parsesSlowPathCompressedBitmapWithoutCompressionHeader() throws {
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x02,
        payload: bitmapUpdatePayload(
            flags: 0x0401,
            bitmapStream: Data([0x11, 0x22, 0x33, 0x44])
        )
    )))

    let update = try #require(pdu.graphicsUpdate)
    guard case let .bitmap(bitmap) = update else {
        Issue.record("Expected bitmap update")
        return
    }
    let rectangle = try #require(bitmap.rectangles.first)
    #expect(rectangle.isCompressed)
    #expect(rectangle.compressedHeader == nil)
    #expect(rectangle.bitmapDataStream == Data([0x11, 0x22, 0x33, 0x44]))
}

@Test func rejectsSlowPathCompressedBitmapHeaderWithFirstRowSize() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: bitmapUpdatePayload(
                flags: 0x0001,
                bitmapStream: compressedBitmapHeader(
                    firstRowSize: 1,
                    mainBodySize: 4,
                    scanWidth: 4,
                    uncompressedSize: 4
                ) + Data([0x11, 0x22, 0x33, 0x44])
            )
        ))
    }
}

@Test func rejectsSlowPathCompressedBitmapHeaderWithMismatchedBodySize() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: bitmapUpdatePayload(
                flags: 0x0001,
                bitmapStream: compressedBitmapHeader(
                    firstRowSize: 0,
                    mainBodySize: 3,
                    scanWidth: 4,
                    uncompressedSize: 4
                ) + Data([0x11, 0x22, 0x33, 0x44])
            )
        ))
    }
}

@Test func rejectsSlowPathCompressedBitmapHeaderWithUnalignedScanWidth() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            payload: bitmapUpdatePayload(
                flags: 0x0001,
                bitmapStream: compressedBitmapHeader(
                    firstRowSize: 0,
                    mainBodySize: 4,
                    scanWidth: 5,
                    uncompressedSize: 4
                ) + Data([0x11, 0x22, 0x33, 0x44])
            )
        ))
    }
}

@Test func parsesSlowPathCompressedBitmapWithCompressionHeader() throws {
    let compressedData = Data([0x11, 0x22, 0x33, 0x44])
    let compressedHeader = compressedBitmapHeader(
        firstRowSize: 0,
        mainBodySize: UInt16(compressedData.count),
        scanWidth: 4,
        uncompressedSize: 4
    )
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x02,
        payload: bitmapUpdatePayload(
            flags: 0x0001,
            bitmapStream: compressedHeader + compressedData
        )
    )))

    let update = try #require(pdu.graphicsUpdate)
    guard case let .bitmap(bitmap) = update else {
        Issue.record("Expected bitmap update")
        return
    }
    let rectangle = try #require(bitmap.rectangles.first)
    #expect(rectangle.compressedHeader == compressedHeader)
    #expect(rectangle.bitmapDataStream == compressedData)
}

private func compressedBitmapHeader(
    firstRowSize: UInt16,
    mainBodySize: UInt16,
    scanWidth: UInt16,
    uncompressedSize: UInt16
) -> Data {
    var compressedHeader = Data()
    compressedHeader.appendLittleEndianUInt16(firstRowSize)
    compressedHeader.appendLittleEndianUInt16(mainBodySize)
    compressedHeader.appendLittleEndianUInt16(scanWidth)
    compressedHeader.appendLittleEndianUInt16(uncompressedSize)
    return compressedHeader
}

@Test func fastPathBitmapUpdateValidatesSharedBitmapPayload() throws {
    let packet = fastPathPacket([
        fastPathUpdate(code: 0x1, payload: bitmapUpdatePayload(bitmapStream: Data([0x11, 0x22, 0x33, 0x44]))),
    ])

    let pdu = try RDPFastPathOutputPDU.parse(packet)

    #expect(pdu.updates[0].typeName == "fastpath-bitmap")
    #expect(pdu.updates[0].bitmapUpdate?.rectangles.count == 1)
    #expect(pdu.summaries[0].byteCount == pdu.updates[0].updateData.count)
}

@Test func rejectsFastPathBitmapUpdateWithMalformedSharedPayload() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x1, payload: Data([0x01, 0x00, 0x01, 0x00])),
        ]))
    }
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x1, payload: Data([0x01, 0x00, 0x00, 0x00])),
        ]))
    }
}

@Test func parsesFastPathSurfaceCommandsUpdate() throws {
    let payload = surfaceFrameMarker(action: 0, frameID: 7)
        + surfaceBitsCommand(type: 0x0001, bitmapData: Data([0xAA, 0xBB]))
        + surfaceBitsCommand(type: 0x0006, bitmapData: Data([0xCC]))
    let packet = fastPathPacket([
        fastPathUpdate(code: 0x4, payload: payload),
    ])

    let pdu = try RDPFastPathOutputPDU.parse(packet)
    let commands = try #require(pdu.updates[0].surfaceCommands)

    #expect(commands.map(\.typeName) == [
        "surface-frame-marker",
        "surface-set-bits",
        "surface-stream-bits",
    ])
    #expect(pdu.summaries[0].surfaceCommandTypeNames == commands.map(\.typeName))
}

@Test func rejectsMalformedFastPathSurfaceCommandsUpdate() throws {
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x4, payload: Data()),
        ]))
    }
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x4, payload: surfaceFrameMarker(action: 2, frameID: 7)),
        ]))
    }
    #expect(throws: RDPDecodeError.invalidFastPathOutputPDU) {
        _ = try RDPFastPathOutputPDU.parse(fastPathPacket([
            fastPathUpdate(code: 0x4, payload: surfaceBitsCommand(type: 0x0001, reserved: 1, bitmapData: Data())),
        ]))
    }
}

@Test func rejectsEmptySurfaceCommandPayload() throws {
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        _ = try RDPSurfaceCommand.parsePayload(Data())
    }
}

@Test func setSurfaceBitsIgnoresDestinationRightAndBottomExtents() throws {
    let payload = surfaceBitsCommand(
        type: 0x0001,
        destinationLeft: 4,
        destinationTop: 5,
        destinationRight: 1,
        destinationBottom: 2,
        bitmapData: Data([0xAA])
    )

    let commands = try RDPSurfaceCommand.parsePayload(payload)

    guard case let .setSurfaceBits(command) = try #require(commands.first) else {
        Issue.record("Expected Set Surface Bits")
        return
    }
    #expect(command.destinationLeft == 4)
    #expect(command.destinationTop == 5)
    #expect(command.destinationRight == 1)
    #expect(command.destinationBottom == 2)
}

@Test func streamSurfaceBitsRejectsInvertedDestinationExtents() throws {
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        _ = try RDPSurfaceCommand.parsePayload(surfaceBitsCommand(
            type: 0x0006,
            destinationLeft: 4,
            destinationTop: 5,
            destinationRight: 1,
            destinationBottom: 2,
            bitmapData: Data([0xAA])
        ))
    }
}

@Test func streamSurfaceBitsRejectsDestinationExtentsThatDoNotMatchBitmapDimensions() throws {
    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        _ = try RDPSurfaceCommand.parsePayload(surfaceBitsCommand(
            type: 0x0006,
            destinationLeft: 4,
            destinationTop: 5,
            destinationRight: 7,
            destinationBottom: 7,
            bitmapWidth: 2,
            bitmapHeight: 2,
            bitmapData: Data([0xAA])
        ))
    }
}

@Test func primarySurfaceCompositorEmitsRawSurfaceCommandFrame() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let pixelData = Data([
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ])
    let payload = surfaceFrameMarker(action: 0, frameID: 99)
        + surfaceBitsCommand(type: 0x0001, destinationLeft: 1, destinationTop: 1, bitmapData: pixelData)
        + surfaceFrameMarker(action: 1, frameID: 99)
    let commands = try RDPSurfaceCommand.parsePayload(payload)

    let frames = try compositor.process(commands)
    let frame = try #require(frames.first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frames.count == 1)
    #expect(frame.frameID == 99)
    #expect(frame.codecName == "surface-bgra")
    #expect(frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
    #expect(frame.decodedBitmapBytesPerRow == 16)
    #expect(bitmap[20 ..< 28] == pixelData[0 ..< 8])
    #expect(bitmap[36 ..< 44] == pixelData[8 ..< 16])
}

@Test func primarySurfaceCompositorEmitsUnframedRawSurfaceCommandBatch() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let pixelData = Data([
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ])
    let payload = surfaceBitsCommand(
        type: 0x0001,
        destinationLeft: 1,
        destinationTop: 1,
        bitmapData: pixelData
    )
    let commands = try RDPSurfaceCommand.parsePayload(payload)

    let frame = try #require(try compositor.process(commands).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.frameID == nil)
    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
    #expect(bitmap[20 ..< 28] == pixelData[0 ..< 8])
    #expect(bitmap[36 ..< 44] == pixelData[8 ..< 16])
}

@Test func primarySurfaceCompositorDecodesNSCodecSurfaceCommand() throws {
    var stream = Data()
    for _ in 0 ..< 4 {
        stream.appendLittleEndianUInt32(1)
    }
    stream.append(contentsOf: [1, 0, 0, 0, 100, 10, 5, 0x7F])
    let command = RDPSurfaceBitsCommand(
        destinationLeft: 1,
        destinationTop: 1,
        destinationRight: 2,
        destinationBottom: 2,
        bitmapData: RDPExtendedBitmapData(
            bitsPerPixel: 32,
            flags: 0,
            codecID: 1,
            width: 1,
            height: 1,
            extendedCompressionHeader: Data(repeating: 0xA5, count: 24),
            bitmapData: stream
        )
    )
    let compositor = RDPPrimarySurfaceCompositor(width: 3, height: 3)

    let frame = try #require(try compositor.process([.setSurfaceBits(command)]).first)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 2, bottom: 2)])
    #expect(frame.decodedBitmapData?[16 ..< 20] == Data([85, 105, 105, 0x7F]))
}

@Test func primarySurfaceCompositorDecodesRemoteFXSurfaceCommand() throws {
    let command = RDPSurfaceBitsCommand(
        destinationLeft: 1,
        destinationTop: 1,
        destinationRight: 65,
        destinationBottom: 65,
        bitmapData: RDPExtendedBitmapData(
            bitsPerPixel: 32,
            flags: 0,
            codecID: 3,
            width: 64,
            height: 64,
            extendedCompressionHeader: nil,
            bitmapData: cavideoRemoteFXGrayTileStream()
        )
    )
    let compositor = RDPPrimarySurfaceCompositor(width: 66, height: 66)

    let frame = try #require(try compositor.process([.setSurfaceBits(command)]).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 65, bottom: 65)])
    #expect(bitmap[268 ..< 272] == Data([0x80, 0x80, 0x80, 0xFF]))
}

@Test func primarySurfaceCompositorClipsRemoteFXTileToRegion() throws {
    let command = RDPSurfaceBitsCommand(
        destinationLeft: 1,
        destinationTop: 1,
        destinationRight: 65,
        destinationBottom: 65,
        bitmapData: RDPExtendedBitmapData(
            bitsPerPixel: 32,
            flags: 0,
            codecID: 3,
            width: 64,
            height: 64,
            extendedCompressionHeader: nil,
            bitmapData: cavideoRemoteFXGrayTileStream(
                regionX: 16,
                regionY: 8,
                regionWidth: 10,
                regionHeight: 12
            )
        )
    )
    let compositor = RDPPrimarySurfaceCompositor(width: 66, height: 66)

    let frame = try #require(try compositor.process([.setSurfaceBits(command)]).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 17, top: 9, right: 27, bottom: 21)])
    #expect(bitmap[(9 * 264 + 16 * 4) ..< (9 * 264 + 17 * 4)] == Data(repeating: 0, count: 4))
    #expect(bitmap[(9 * 264 + 17 * 4) ..< (9 * 264 + 18 * 4)] == Data([0x80, 0x80, 0x80, 0xFF]))
}

@Test func primarySurfaceCompositorKeepsMarkedFramePendingUntilEndMarker() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let pixelData = Data([
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ])
    let beginAndBits = try RDPSurfaceCommand.parsePayload(
        surfaceFrameMarker(action: 0, frameID: 102)
            + surfaceBitsCommand(type: 0x0001, destinationLeft: 1, destinationTop: 1, bitmapData: pixelData)
    )
    let end = try RDPSurfaceCommand.parsePayload(surfaceFrameMarker(action: 1, frameID: 102))

    #expect(try compositor.process(beginAndBits).isEmpty)
    let frame = try #require(try compositor.process(end).first)

    #expect(frame.frameID == 102)
    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
}

@Test func primarySurfaceCompositorConvertsRaw24BPPRowsToBGRA() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let pixelData = Data([
        0x01, 0x02, 0x03,
        0x04, 0x05, 0x06,
        0x00, 0x00,
        0x07, 0x08, 0x09,
        0x0A, 0x0B, 0x0C,
        0x00, 0x00,
    ])
    let payload = surfaceFrameMarker(action: 0, frameID: 100)
        + surfaceBitsCommand(
            type: 0x0001,
            destinationLeft: 1,
            destinationTop: 1,
            bitsPerPixel: 24,
            bitmapWidth: 2,
            bitmapHeight: 2,
            bitmapData: pixelData
        )
        + surfaceFrameMarker(action: 1, frameID: 100)
    let commands = try RDPSurfaceCommand.parsePayload(payload)

    let frame = try #require(try compositor.process(commands).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
    #expect(bitmap[20 ..< 28] == Data([0x01, 0x02, 0x03, 0xFF, 0x04, 0x05, 0x06, 0xFF]))
    #expect(bitmap[36 ..< 44] == Data([0x07, 0x08, 0x09, 0xFF, 0x0A, 0x0B, 0x0C, 0xFF]))
}

@Test func primarySurfaceCompositorAcceptsPaddedRaw32BPPRows() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let pixelData = Data([
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
    ])
    let payload = surfaceFrameMarker(action: 0, frameID: 101)
        + surfaceBitsCommand(
            type: 0x0001,
            destinationLeft: 1,
            destinationTop: 1,
            bitsPerPixel: 32,
            bitmapWidth: 2,
            bitmapHeight: 1,
            bitmapData: pixelData
        )
        + surfaceFrameMarker(action: 1, frameID: 101)
    let commands = try RDPSurfaceCommand.parsePayload(payload)

    let frame = try #require(try compositor.process(commands).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 2)])
    #expect(bitmap[20 ..< 28] == pixelData[0 ..< 8])
}

@Test func primarySurfaceCompositorEmitsSlowPathBitmapFrame() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 4)
    let bottomRow = Data([
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
    ])
    let topRow = Data([
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ])
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 1,
            destinationTop: 1,
            destinationRight: 2,
            destinationBottom: 2,
            width: 2,
            height: 2,
            bitsPerPixel: 32,
            flags: 0,
            compressedHeader: nil,
            bitmapDataStream: bottomRow + topRow
        ),
    ])

    let frame = try #require(try compositor.process(update).first)
    let bitmap = try #require(frame.decodedBitmapData)

    #expect(frame.frameID == nil)
    #expect(frame.codecName == "surface-bgra")
    #expect(frame.destinationRect == RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4))
    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 1, right: 3, bottom: 3)])
    #expect(frame.decodedBitmapBytesPerRow == 16)
    #expect(bitmap[20 ..< 28] == topRow)
    #expect(bitmap[36 ..< 44] == bottomRow)
}

@Test func primarySurfaceCompositorDecodesCompressed24BPPSlowPathBitmap() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 1)
    let pixels = Data([
        0x01, 0x02, 0x03,
        0x04, 0x05, 0x06,
        0x07, 0x08, 0x09,
        0x0A, 0x0B, 0x0C,
    ])
    var compressedHeader = Data()
    compressedHeader.appendLittleEndianUInt16(0)
    compressedHeader.appendLittleEndianUInt16(UInt16(pixels.count + 1))
    compressedHeader.appendLittleEndianUInt16(4)
    compressedHeader.appendLittleEndianUInt16(UInt16(pixels.count))
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 3,
            destinationBottom: 0,
            width: 4,
            height: 1,
            bitsPerPixel: 24,
            flags: 0x0001,
            compressedHeader: compressedHeader,
            bitmapDataStream: Data([0x84]) + pixels
        ),
    ])

    let frame = try #require(try compositor.process(update).first)
    #expect(frame.decodedBitmapData == Data([
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ]))
}

@Test func primarySurfaceCompositorConvertsCompressed16BPPBitmap() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 2, height: 1)
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 1,
            destinationBottom: 0,
            width: 2,
            height: 1,
            bitsPerPixel: 16,
            flags: 0x0401,
            compressedHeader: nil,
            bitmapDataStream: Data([0x82, 0x00, 0xF8, 0x1F, 0x00])
        ),
    ])

    let frame = try #require(try compositor.process(update).first)
    #expect(frame.decodedBitmapData == Data([
        0x00, 0x00, 0xFF, 0xFF,
        0xFF, 0x00, 0x00, 0xFF,
    ]))
}

@Test func primarySurfaceCompositorAppliesPaletteToCompressed8BPPBitmap() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 2, height: 1)
    var palette = Data(repeating: 0, count: 256 * 3)
    palette.replaceSubrange(3 ..< 6, with: [0x11, 0x22, 0x33])
    palette.replaceSubrange(6 ..< 9, with: [0x44, 0x55, 0x66])
    compositor.updatePalette(RDPPaletteUpdate(entries: palette))
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 1,
            destinationBottom: 0,
            width: 2,
            height: 1,
            bitsPerPixel: 8,
            flags: 0x0401,
            compressedHeader: nil,
            bitmapDataStream: Data([0x82, 0x01, 0x02])
        ),
    ])

    let frame = try #require(try compositor.process(update).first)
    #expect(frame.decodedBitmapData == Data([
        0x33, 0x22, 0x11, 0xFF,
        0x66, 0x55, 0x44, 0xFF,
    ]))
}

@Test func primarySurfaceCompositorDecodesCompressedRDP6Bitmap() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 2, height: 1)
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 1,
            destinationBottom: 0,
            width: 2,
            height: 1,
            bitsPerPixel: 32,
            flags: 0x0401,
            compressedHeader: nil,
            bitmapDataStream: Data([
                0x00,
                0x40, 0x80,
                0x11, 0x22,
                0x33, 0x44,
                0x55, 0x66,
            ])
        ),
    ])

    let frame = try #require(try compositor.process(update).first)
    #expect(frame.decodedBitmapData == Data([
        0x55, 0x33, 0x11, 0x40,
        0x66, 0x44, 0x22, 0x80,
    ]))
}

private func bitmapUpdatePayload(flags: UInt16 = 0, bitmapStream: Data) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(0x0001)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(32)
    payload.appendLittleEndianUInt16(flags)
    payload.appendLittleEndianUInt16(UInt16(bitmapStream.count))
    payload.append(bitmapStream)
    return payload
}

private func surfaceFrameMarker(action: UInt16, frameID: UInt32) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(0x0004)
    data.appendLittleEndianUInt16(action)
    data.appendLittleEndianUInt32(frameID)
    return data
}

private func surfaceBitsCommand(
    type: UInt16,
    destinationLeft: UInt16 = 0,
    destinationTop: UInt16 = 0,
    destinationRight: UInt16? = nil,
    destinationBottom: UInt16? = nil,
    reserved: UInt8 = 0,
    bitsPerPixel: UInt8 = 32,
    bitmapWidth: UInt16 = 2,
    bitmapHeight: UInt16 = 2,
    bitmapData: Data
) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt16(destinationLeft)
    data.appendLittleEndianUInt16(destinationTop)
    data.appendLittleEndianUInt16(destinationRight ?? destinationLeft + 2)
    data.appendLittleEndianUInt16(destinationBottom ?? destinationTop + 2)
    data.appendUInt8(bitsPerPixel)
    data.appendUInt8(0)
    data.appendUInt8(reserved)
    data.appendUInt8(0)
    data.appendLittleEndianUInt16(bitmapWidth)
    data.appendLittleEndianUInt16(bitmapHeight)
    data.appendLittleEndianUInt32(UInt32(bitmapData.count))
    data.append(bitmapData)
    return data
}

private func shareDataPacket(type: UInt8, pduSource: UInt16 = 1005, payload: Data) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(18 + payload.count))
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(pduSource)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(UInt16(payload.count + 4))
    userData.appendUInt8(type)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.append(payload)
    return mcsSendDataIndication(channelID: 1003, userData: userData)
}

private func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(1005 - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

private func fastPathPacket(_ updates: [Data]) -> Data {
    fastPathPacket(updates.reduce(into: Data()) { $0.append($1) })
}

private func fastPathPacket(_ updates: Data) -> Data {
    let length = 1 + (updates.count + 2 < 0x80 ? 1 : 2) + updates.count
    var data = Data()
    data.appendUInt8(0x00)
    if length < 0x80 {
        data.appendUInt8(UInt8(length))
    } else {
        data.appendUInt8(0x80 | UInt8((length >> 8) & 0x7F))
        data.appendUInt8(UInt8(length & 0xFF))
    }
    data.append(updates)
    return data
}

private func fastPathUpdate(code: UInt8, payload: Data) -> Data {
    var data = Data()
    data.appendUInt8(code)
    data.appendLittleEndianUInt16(UInt16(payload.count))
    data.append(payload)
    return data
}
