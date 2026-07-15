import CoreVideo
import Foundation
@testable import RDPKit
import Testing

@Test func decodesWindowsClearCodecRLEXTile() throws {
    let stream = Data([
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x15, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x10, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x02,
        0x01,
        0x00, 0x00, 0x00,
        0x00, 0xFF, 0xFF, 0x03,
    ])

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 64, height: 16)

    #expect(bitmap.width == 64)
    #expect(bitmap.height == 16)
    #expect(bitmap.bytesPerRow == 256)
    #expect(bitmap.bgraData.count == 64 * 16 * 4)
    #expect(bitmap.bgraData.prefix(4) == Data([0x00, 0x00, 0x00, 0xFF]))
    #expect(bitmap.bgraData.suffix(4) == Data([0x00, 0x00, 0x00, 0xFF]))
}

@Test func decodesClearCodecRawSubcodecRegion() throws {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(19)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(2)
    stream.appendLittleEndianUInt16(1)
    stream.appendLittleEndianUInt32(6)
    stream.appendUInt8(0)
    stream.append(contentsOf: [
        0x10, 0x20, 0x30,
        0x40, 0x50, 0x60,
    ])

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 2, height: 1)

    #expect(bitmap.bgraData == Data([
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
    ]))
}

@Test func decodesClearCodecRLEXMultiPaletteSuite() throws {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(25)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(5)
    stream.appendLittleEndianUInt16(1)
    stream.appendLittleEndianUInt32(12)
    stream.appendUInt8(0x02)
    stream.appendUInt8(3)
    stream.append(contentsOf: [
        0x10, 0x20, 0x30,
        0x40, 0x50, 0x60,
        0x70, 0x80, 0x90,
    ])
    stream.appendUInt8(0x0A)
    stream.appendUInt8(2)

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 5, height: 1)

    #expect(bitmap.bgraData == Data([
        0x10, 0x20, 0x30, 0xFF,
        0x10, 0x20, 0x30, 0xFF,
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
        0x70, 0x80, 0x90, 0xFF,
    ]))
}

@Test func decodesClearCodecNSCodecSubcodecRegion() throws {
    var stream = Data([0x00, 0x00])
    let nsCodec = nsCodecFrame(
        yPlane: [63, 127],
        coPlane: [127, 0],
        cgPlane: [0xC0, 127],
        alphaPlane: [0xFF, 0xFF],
        colorLossLevel: 1
    )
    var subcodec = Data()
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(2)
    subcodec.appendLittleEndianUInt16(1)
    subcodec.appendLittleEndianUInt32(UInt32(nsCodec.count))
    subcodec.appendUInt8(0x01)
    subcodec.append(nsCodec)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(subcodec.count))
    stream.append(subcodec)

    let summary = try RDPClearCodecDecoder.summarize(stream)
    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 2, height: 1)

    #expect(summary.subcodecRegions == [
        RDPClearCodecSubcodecSummary(
            rect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 1),
            byteCount: UInt32(nsCodec.count),
            codecID: 0x01,
            nsCodecYByteCount: 2,
            nsCodecCoByteCount: 2,
            nsCodecCgByteCount: 2,
            nsCodecAlphaByteCount: 2,
            nsCodecColorLossLevel: 1,
            nsCodecChromaSubsamplingLevel: 0
        ),
    ])
    #expect(bitmap.bgraData == Data([
        0x00, 0x00, 0xFE, 0xFF,
        0x00, 0xFE, 0x00, 0xFF,
    ]))
}

@Test func decodesClearCodecNSCodecSubcodecWithoutAlphaPlane() throws {
    var stream = Data([0x00, 0x00])
    let nsCodec = nsCodecFrame(
        yPlane: [127, 127],
        coPlane: [0, 0],
        cgPlane: [0, 0],
        alphaPlane: [],
        colorLossLevel: 3
    )
    var subcodec = Data()
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(2)
    subcodec.appendLittleEndianUInt16(1)
    subcodec.appendLittleEndianUInt32(UInt32(nsCodec.count))
    subcodec.appendUInt8(0x01)
    subcodec.append(nsCodec)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(subcodec.count))
    stream.append(subcodec)

    let summary = try RDPClearCodecDecoder.summarize(stream)
    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 2, height: 1)

    #expect(summary.subcodecRegions.first?.nsCodecAlphaByteCount == 0)
    #expect(bitmap.bgraData == Data([
        0x7F, 0x7F, 0x7F, 0xFF,
        0x7F, 0x7F, 0x7F, 0xFF,
    ]))
}

@Test func decodesClearCodecNSCodecRawPlaneLongerThanRLETail() throws {
    var stream = Data([0x00, 0x00])
    let nsCodec = nsCodecFrame(
        yPlane: [10, 20, 30, 40, 50],
        coPlane: [0, 0, 0, 0, 0],
        cgPlane: [0, 0, 0, 0, 0],
        alphaPlane: [],
        colorLossLevel: 3
    )
    var subcodec = Data()
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(5)
    subcodec.appendLittleEndianUInt16(1)
    subcodec.appendLittleEndianUInt32(UInt32(nsCodec.count))
    subcodec.appendUInt8(0x01)
    subcodec.append(nsCodec)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(subcodec.count))
    stream.append(subcodec)

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 5, height: 1)

    #expect(bitmap.bgraData == Data([
        10, 10, 10, 0xFF,
        20, 20, 20, 0xFF,
        30, 30, 30, 0xFF,
        40, 40, 40, 0xFF,
        50, 50, 50, 0xFF,
    ]))
}

@Test func decodesClearCodecNSCodecChromaShiftWithSignedTruncation() throws {
    var stream = Data([0x00, 0x00])
    let nsCodec = nsCodecFrame(
        yPlane: [127],
        coPlane: [127],
        cgPlane: [0],
        alphaPlane: [],
        colorLossLevel: 3
    )
    var subcodec = Data()
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(0)
    subcodec.appendLittleEndianUInt16(1)
    subcodec.appendLittleEndianUInt16(1)
    subcodec.appendLittleEndianUInt32(UInt32(nsCodec.count))
    subcodec.appendUInt8(0x01)
    subcodec.append(nsCodec)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(subcodec.count))
    stream.append(subcodec)

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 1, height: 1)

    #expect(bitmap.bgraData == Data([
        131, 127, 123, 0xFF,
    ]))
}

@Test func decodesClearCodecGlyphCacheHitWithoutPayload() throws {
    let decoder = RDPClearCodecDecoder()
    let glyphIndex: UInt16 = 7
    let cached = try decoder.decode(clearCodecGlyphMissStream(glyphIndex: glyphIndex), width: 2, height: 1)

    var hit = Data([0x03, 0x01])
    hit.appendLittleEndianUInt16(glyphIndex)

    let bitmap = try decoder.decode(hit, width: 2, height: 1)

    #expect(bitmap == cached)
}

@Test func rejectsClearCodecGlyphCacheHitWithPayload() throws {
    let decoder = RDPClearCodecDecoder()
    let glyphIndex: UInt16 = 7
    _ = try decoder.decode(clearCodecGlyphMissStream(glyphIndex: glyphIndex), width: 2, height: 1)

    var hit = Data([0x03, 0x01])
    hit.appendLittleEndianUInt16(glyphIndex)
    hit.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try decoder.decode(hit, width: 2, height: 1)
    }
}

@Test func rejectsClearCodecOutOfSequenceStreams() throws {
    let decoder = RDPClearCodecDecoder()
    _ = try decoder.decode(clearCodecBandsStream(seqNumber: 0, bandsData: Data()), width: 1, height: 1)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try decoder.decode(clearCodecBandsStream(seqNumber: 2, bandsData: Data()), width: 1, height: 1)
    }
    _ = try decoder.decode(clearCodecBandsStream(seqNumber: 1, bandsData: Data()), width: 1, height: 1)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPClearCodecDecoder().decode(
            clearCodecBandsStream(seqNumber: 1, bandsData: Data()),
            width: 1,
            height: 1
        )
    }
}

@Test func rejectsClearCodecReservedFlagsAndInvalidGlyphIndices() {
    var reservedFlagsStream = clearCodecBandsStream(seqNumber: 0, bandsData: Data())
    reservedFlagsStream[0] = 0x08
    var invalidGlyphStream = Data([0x01, 0x00])
    invalidGlyphStream.appendLittleEndianUInt16(4_000)

    for stream in [reservedFlagsStream, invalidGlyphStream] {
        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            try RDPClearCodecDecoder().decode(stream, width: 1, height: 1)
        }
        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            try RDPClearCodecDecoder.summarize(stream)
        }
    }
}

@Test func rejectsOversizedClearCodecGlyphsBeforeAllocation() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPClearCodecDecoder().decode(
            clearCodecGlyphMissStream(glyphIndex: 0),
            width: 1_025,
            height: 1_024
        )
    }
}

@Test func decodesClearCodecResidualRuns() throws {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(8)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.append(contentsOf: [
        0x01, 0x02, 0x03, 0x02,
        0x04, 0x05, 0x06, 0x02,
    ])

    let bitmap = try RDPClearCodecDecoder().decode(stream, width: 2, height: 2)

    #expect(bitmap.bgraData == Data([
        0x01, 0x02, 0x03, 0xFF,
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
    ]))
}

@Test func rejectsClearCodecResidualRunWithZeroFirstFactor() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPClearCodecDecoder().decode(
            clearCodecResidualStream(Data([0x01, 0x02, 0x03, 0x00])),
            width: 1,
            height: 1
        )
    }
}

@Test func rejectsClearCodecResidualRunWithZeroSecondFactor() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPClearCodecDecoder().decode(
            clearCodecResidualStream(Data([0x01, 0x02, 0x03, 0xFF, 0x00, 0x00])),
            width: 1,
            height: 1
        )
    }
}

@Test func rejectsClearCodecResidualRunWithZeroThirdFactor() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPClearCodecDecoder().decode(
            clearCodecResidualStream(Data([
                0x01, 0x02, 0x03,
                0xFF,
                0xFF, 0xFF,
                0x00, 0x00, 0x00, 0x00,
            ])),
            width: 1,
            height: 1
        )
    }
}

@Test func decodesClearCodecBandsWithShortVBarMisses() throws {
    let stream = clearCodecBandsStream(seqNumber: 0, bandsData: clearCodecTwoColumnBandsData())
    let summary = try RDPClearCodecDecoder.summarize(stream)
    let bitmap = try RDPClearCodecDecoder().decode(
        stream,
        width: 2,
        height: 3
    )

    #expect(summary.flags == 0)
    #expect(summary.sequenceNumber == 0)
    #expect(summary.residualByteCount == 0)
    #expect(summary.bandsByteCount == UInt32(clearCodecTwoColumnBandsData().count))
    #expect(summary.subcodecByteCount == 0)
    #expect(bitmap.bgraData == Data([
        0x00, 0x00, 0x00, 0xFF,
        0x70, 0x80, 0x90, 0xFF,
        0x10, 0x20, 0x30, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
    ]))
}

@Test func decodesClearCodecBandsWithVBarAndShortVBarCacheHits() throws {
    let decoder = RDPClearCodecDecoder()
    _ = try decoder.decode(
        clearCodecBandsStream(seqNumber: 0, bandsData: clearCodecTwoColumnBandsData()),
        width: 2,
        height: 3
    )

    var bandsData = Data()
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(1)
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(2)
    bandsData.append(contentsOf: [0x01, 0x02, 0x03])
    bandsData.appendLittleEndianUInt16(0x8000)
    bandsData.appendLittleEndianUInt16(0x4001)
    bandsData.appendUInt8(0)

    let bitmap = try decoder.decode(
        clearCodecBandsStream(seqNumber: 1, bandsData: bandsData),
        width: 2,
        height: 3
    )

    #expect(bitmap.bgraData == Data([
        0x00, 0x00, 0x00, 0xFF,
        0x70, 0x80, 0x90, 0xFF,
        0x10, 0x20, 0x30, 0xFF,
        0x01, 0x02, 0x03, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
        0x01, 0x02, 0x03, 0xFF,
    ]))
}

@Test func decodesBitmapFrameSnapshotToPixelBuffer() throws {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 0,
        codecID: RDPGFXCodecID.clearCodec,
        codecName: RDPGFXCodecID.name(for: RDPGFXCodecID.clearCodec),
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 1),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 1)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data([
            0x10, 0x20, 0x30, 0xFF,
            0x40, 0x50, 0x60, 0xFF,
        ]),
        decodedBitmapBytesPerRow: 8
    )

    let decoded = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame)

    #expect(decoded.decodedPixelFormat == kCVPixelFormatType_32BGRA)
    #expect(decoded.usesHardwareAcceleration == nil)
}

private func clearCodecBandsStream(seqNumber: UInt8, bandsData: Data) -> Data {
    var stream = Data([0x00, seqNumber])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(bandsData.count))
    stream.appendLittleEndianUInt32(0)
    stream.append(bandsData)
    return stream
}

private func clearCodecTwoColumnBandsData() -> Data {
    var bandsData = Data()
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(1)
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(2)
    bandsData.append(contentsOf: [0x00, 0x00, 0x00])
    bandsData.appendLittleEndianUInt16(0x0301)
    bandsData.append(contentsOf: [
        0x10, 0x20, 0x30,
        0x40, 0x50, 0x60,
    ])
    bandsData.appendLittleEndianUInt16(0x0100)
    bandsData.append(contentsOf: [
        0x70, 0x80, 0x90,
    ])
    return bandsData
}

private func nsCodecFrame(
    yPlane: [UInt8],
    coPlane: [UInt8],
    cgPlane: [UInt8],
    alphaPlane: [UInt8],
    colorLossLevel: UInt8
) -> Data {
    var data = Data()
    data.appendLittleEndianUInt32(UInt32(yPlane.count))
    data.appendLittleEndianUInt32(UInt32(coPlane.count))
    data.appendLittleEndianUInt32(UInt32(cgPlane.count))
    data.appendLittleEndianUInt32(UInt32(alphaPlane.count))
    data.appendUInt8(colorLossLevel)
    data.appendUInt8(0)
    data.appendUInt8(0)
    data.appendUInt8(0)
    data.append(contentsOf: yPlane)
    data.append(contentsOf: coPlane)
    data.append(contentsOf: cgPlane)
    data.append(contentsOf: alphaPlane)
    return data
}

private func clearCodecResidualStream(_ residualData: Data) -> Data {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(UInt32(residualData.count))
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.append(residualData)
    return stream
}

private func clearCodecGlyphMissStream(glyphIndex: UInt16) -> Data {
    var stream = Data([0x01, 0x00])
    stream.appendLittleEndianUInt16(glyphIndex)
    return stream
}
