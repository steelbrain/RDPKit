import Foundation
@testable import RDPKit
import Testing

// RemoteFX (CAVIDEO, [MS-RDPRFX]) stream validation on synthetic streams.

@Test func cavideoRemoteFXRejectsInvalidSyncMagic() throws {
    var bitmapStream = cavideoRemoteFXGrayTileStream()
    bitmapStream[6] = 0

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(bitmapStream)
    }
}

@Test func cavideoRemoteFXIgnoresRegionFlags() throws {
    // lrf SHOULD and the reserved bits MUST be ignored (MS-RDPRFX 2.2.2.3.3).
    for regionFlags: UInt8 in [0, 0xFE] {
        let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
            regionFlags: regionFlags
        ))

        #expect(frame.tiles.count == 1)
    }
}

@Test func cavideoRemoteFXRejectsUnknownCodecVersion() throws {
    // TS_RFX_CODEC_VERSIONT MUST carry codec ID 1, version 0x0100 (MS-RDPRFX 2.2.2.2.2).
    for (codecVersionID, codecVersion): (UInt8, UInt16) in [(42, 0x0100), (1, 42)] {
        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
                codecVersionID: codecVersionID,
                codecVersion: codecVersion
            ))
        }
    }
}

@Test func cavideoRemoteFXTracksFrameSequenceAcrossPayloads() throws {
    let blocks = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream())
    let decoder = RDPRemoteFXDecoder()

    _ = try decoder.decode(cavideoRemoteFXStream(blocks[0 ... 3]))
    let frame = try decoder.decode(cavideoRemoteFXStream(blocks[4 ... 7]))

    #expect(frame.tiles.count == 1)
}

@Test func cavideoRemoteFXDecodesNextMessageAfterOneFailsInsideAFrame() throws {
    let decoder = RDPRemoteFXDecoder()
    // The tile set's quantization factor is invalid, so decoding fails after FRAME_BEGIN.
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try decoder.decode(cavideoRemoteFXGrayTileStream(quantData: Data([0x65, 0x66, 0x77, 0x88, 0x98])))
    }

    let frame = try decoder.decode(cavideoRemoteFXGrayTileStream(frameIndex: 2))

    #expect(frame.frameIndex == 2)
    #expect(frame.tiles.count == 1)
}

@Test func cavideoRemoteFXKeepsTheRegionOfEveryFrameInAMessage() throws {
    let first = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream(channelWidth: 128))
    let second = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream(
        frameIndex: 2,
        channelWidth: 128,
        regionX: 64,
        tileXIndex: 1
    ))

    let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXStream(first + second[4 ... 7]))

    #expect(frame.tiles.map(\.x) == [0, 64])
    #expect(frame.regionRects == [
        RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
        RDPFrameRect(left: 64, top: 0, right: 128, bottom: 64),
    ])
}

@Test func cavideoRemoteFXRejectsOutOfSequenceFrameBlocks() throws {
    let blocks = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream())
    let blockOrder = [0, 1, 2, 3, 4, 6, 5, 7]

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXStream(blockOrder.map { blocks[$0] }))
    }
}

@Test func cavideoRemoteFXRequiresCompleteInitialHeaders() throws {
    let blocks = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream())

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXStream(blocks[1 ... 7]))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXStream(
            [blocks[0], blocks[1], blocks[2]] + blocks[4 ... 7]
        ))
    }
}

@Test func cavideoRemoteFXRejectsInvalidFrameRegionCount() throws {
    for regionCount: UInt16 in [0, 2] {
        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
                frameRegionCount: regionCount
            ))
        }
    }
}

@Test func cavideoRemoteFXGeneratesFullChannelRegionForEmptyRectangles() throws {
    let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
        channelWidth: 96,
        channelHeight: 72,
        regionRectangleCount: 0
    ))

    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 96, bottom: 72)])
}

@Test func cavideoRemoteFXRejectsQuantizationFactorsBelowSix() throws {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
            quantData: Data([0x65, 0x66, 0x77, 0x88, 0x98])
        ))
    }
}

private func cavideoRemoteFXBlocks(_ stream: Data) -> [Data] {
    var blocks: [Data] = []
    var offset = 0
    while offset < stream.count {
        let length = Int(stream.littleEndianUInt32(at: offset + 2))
        blocks.append(stream.subdata(in: offset ..< offset + length))
        offset += length
    }
    return blocks
}

private func cavideoRemoteFXStream<S: Sequence>(_ blocks: S) -> Data where S.Element == Data {
    blocks.reduce(into: Data()) { stream, block in
        stream.append(block)
    }
}
