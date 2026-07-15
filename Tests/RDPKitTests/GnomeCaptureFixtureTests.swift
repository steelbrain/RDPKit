import Foundation
@testable import RDPKit
import Testing

@Test func parsesProgressiveQuantizationInSpecBandOrder() throws {
    var cursor = ByteCursor(Data([0x21, 0x43, 0x65, 0x87, 0x18]))

    let quant = try RDPRemoteFXDecoder.parseProgressiveQuant(from: &cursor)

    #expect(quant.ll3 == 1)
    #expect(quant.hl3 == 2)
    #expect(quant.lh3 == 3)
    #expect(quant.hh3 == 4)
    #expect(quant.hl2 == 5)
    #expect(quant.lh2 == 6)
    #expect(quant.hh2 == 7)
    #expect(quant.hl1 == 8)
    #expect(quant.lh1 == 8)
    #expect(quant.hh1 == 1)
    #expect(cursor.remaining == 0)
}

@Test func decodesProgressiveSRLSpecExample() throws {
    var reader = RDPProgressiveSRLReader(Data([0xA0, 0x01, 0x80, 0x00, 0xC9, 0x49, 0xE0]))
    let bitCounts = [4, 4, 4, 4, 2, 2, 2, 2]
    var values: [Int16] = []
    for (index, bitCount) in bitCounts.enumerated() {
        values.append(try reader.readValue(
            magnitudeBitCount: bitCount,
            remainingValueCount: bitCounts.count - index
        ))
    }

    #expect(values == [-13, 15, -3, 0, 0, -3, 2, -1])
}

@Test func progressiveSRLStopsAtExpectedOutputInsideZeroPadding() throws {
    var reader = RDPProgressiveSRLReader(Data([0x00]))
    var values: [Int16] = []
    for index in 0 ..< 4 {
        values.append(try reader.readValue(
            magnitudeBitCount: 1,
            remainingValueCount: 4 - index
        ))
    }

    #expect(values == [0, 0, 0, 0])
}

// Fixtures captured from a live gnome-remote-desktop (GRD) server during this
// branch's debugging. These are real bytes off the wire, not hand-modelled, so
// they pin the client to GRD's actual behaviour rather than to our own
// assumptions about it — the gap that let the GNOME regressions land green.

@Test func parsesRealGnomeMCSConnectResponseChannelLayout() throws {
    // GRD assigns drdynvc and cliprdr as static channels plus a message channel
    // for connect-time auto-detect.
    let response = try MCSConnectResponse.parse(
        fromTPKT: gnomeHex("""
        03 00 00 72 02 f0 80 7f 66 68 0a 01 00 02 01 00 30 1a 02 01 22 02 01 03 \
        02 01 00 02 01 01 02 01 00 02 01 01 02 03 00 ff f8 02 01 02 04 44 00 05 \
        00 14 7c 00 01 2a 14 76 0a 01 01 00 01 c0 00 4d 63 44 6e 2e 01 0c 10 00 \
        05 00 08 00 03 00 00 00 00 00 00 00 03 0c 0c 00 eb 03 02 00 ec 03 ed 03 \
        02 0c 0c 00 00 00 00 00 00 00 00 00 04 0c 06 00 ee 03
        """),
        requestedChannels: [.drdynvc, .cliprdr],
        expectedMessageChannelAdvertised: true
    )

    #expect(response.result == 0)
    #expect(response.serverUserDataKey == "McDn")
    #expect(response.clientRequestedProtocols == [.tls, .credSSP])
    #expect(response.ioChannelID == 1003)
    #expect(response.messageChannelID == 1006)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1005),
    ])
}

@Test func realGnomeBandwidthMeasureStartParses() throws {
    // The exact auto-detect request GRD sends first, on the message channel
    // (1006), immediately after Client Info. The client must parse it as a
    // bandwidth-measure-start so it can short-circuit with network characteristics sync.
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(
        fromTPKT: gnomeHex("03 00 00 19 02 f0 80 68 00 06 03 ee 70 80 0a 00 10 00 00 06 00 00 00 14 10")
    ))

    #expect(request.channelID == 1006)
    #expect(request.sequenceNumber == 0)
    #expect(request.requestType == 0x1014)
    #expect(request.requestTypeName == "connect-time-bandwidth-measure-start")
    #expect(request.payloadByteCount == 0)
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.networkCharacteristicsSync)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVETileSimpleSummarizesAndDecodes() throws {
    // GRD can send its first frame as RDPGFX_WIRE_TO_SURFACE_2 with
    // CAPROGRESSIVE tile-simple blocks instead of AVC video. The tail bytes are
    // intentionally non-empty because CAPROGRESSIVE tile-simple carries a tail
    // field that the decoder must ignore.
    let bitmapStream = caprogressiveRemoteFXGrayTileStream(
        frameIndex: 7,
        tailData: Data([0xDE, 0xAD, 0xBE, 0xEF])
    )
    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(
        from: gnomeGraphicsMessage(
            commandID: RDPGFXCommandID.wireToSurface2,
            payload: gnomeWireToSurface2Payload(bitmapData: bitmapStream)
        )
    ))

    #expect(summary.typeName == "rdpgfx-wire-to-surface-2")
    #expect(summary.surfaceID == 0)
    #expect(summary.codecID == RDPGFXCodecID.caProgressive)
    #expect(summary.codecName == "caprogressive")
    #expect(summary.codecContextID == 0)
    #expect(summary.pixelFormat == 0x20)
    #expect(summary.progressiveBlockTypeNames == ["sync", "context", "frame-begin", "region", "frame-end"])
    #expect(summary.progressiveContextTileSizes == [64])
    #expect(summary.progressiveFrameIndexes == [7])
    #expect(summary.progressiveRegionRects == [
        RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
    ])
    #expect(summary.progressiveRegionTileCount == 1)
    #expect(summary.progressiveTileSimpleCount == 1)
    #expect(summary.progressiveTileFirstCount == 0)
    #expect(summary.progressiveTileUpgradeCount == 0)

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    let tile = try #require(frame.tiles.first)

    #expect(frame.frameIndex == 7)
    #expect(frame.tiles.count == 1)
    #expect(tile.x == 0)
    #expect(tile.y == 0)
    #expect(tile.bytesPerRow == 256)
    #expect(
        gnomePixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow)
            == [0x80, 0x80, 0x80, 0xFF]
    )
    #expect(gnomePixel(atX: 63, y: 63, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEMultiTileDecodePreservesOrder() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 8,
        regionWidth: 256,
        regionHeight: 128,
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 2, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 3, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 2, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 3, yIndex: 1),
        ]
    )

    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(
        from: gnomeGraphicsMessage(
            commandID: RDPGFXCommandID.wireToSurface2,
            payload: gnomeWireToSurface2Payload(bitmapData: bitmapStream)
        )
    ))
    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(summary.progressiveRegionTileCount == 8)
    #expect(summary.progressiveTileSimpleCount == 8)
    #expect(frame.frameIndex == 8)
    #expect(frame.tiles.map { [$0.x, $0.y] } == [
        [0, 0],
        [64, 0],
        [128, 0],
        [192, 0],
        [0, 64],
        [64, 64],
        [128, 64],
        [192, 64],
    ])
    for tile in frame.tiles {
        #expect(gnomePixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsAdvertisedTileCountMismatch() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        advertisedTileCount: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsUnsupportedTileBlockType() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(blockType: 0xCCC8, xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEDecodesFullQualityFirstPass() throws {
    let simpleStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0, yData: rlgrSingleOneComponent())]
    )
    let firstPassStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF,
            yData: rlgrSingleOneComponent()
        )]
    )

    let simple = try #require(RDPRemoteFXDecoder().decodeProgressive(simpleStream).tiles.first)
    let firstPass = try #require(RDPRemoteFXDecoder().decodeProgressive(firstPassStream).tiles.first)

    #expect(firstPass.bgraData == simple.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEValidatesFirstPassQualityIndex() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0
        )]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEAppliesFirstPassQuantization() throws {
    let progressiveQuant = Data([25] + Array(repeating: UInt8(0x11), count: 15))
    let quantizedStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [progressiveQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0,
            yData: rlgrSingleOneComponent()
        )]
    )
    let fullQualityStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF,
            yData: rlgrSingleOneComponent()
        )]
    )

    let quantized = try #require(RDPRemoteFXDecoder().decodeProgressive(quantizedStream).tiles.first)
    let fullQuality = try #require(RDPRemoteFXDecoder().decodeProgressive(fullQualityStream).tiles.first)

    #expect(quantized.bgraData != fullQuality.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEAppliesUpgradePass() throws {
    let progressiveQuant = Data([50] + Array(repeating: UInt8(0x11), count: 15))
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [progressiveQuant],
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC6,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0
            ),
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC7,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0xFF,
                ySrlData: srlAllZeroComponent(count: 4015),
                yRawData: Data(repeating: 0, count: 11),
                cbSrlData: srlAllZeroComponent(count: 4015),
                cbRawData: Data(repeating: 0, count: 11),
                crSrlData: srlAllZeroComponent(count: 4015),
                crRawData: Data(repeating: 0, count: 11)
            ),
        ]
    )

    let tiles = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream).tiles

    #expect(tiles.count == 2)
    #expect(tiles[1].bgraData == tiles[0].bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEKeepsCodecContextReferencesIndependent() throws {
    let progressiveQuant = Data([50] + Array(repeating: UInt8(0x11), count: 15))
    let firstPassStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [progressiveQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0
        )]
    )
    let unrelatedContextStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )
    let upgradeStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        progressiveQuantTables: [progressiveQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC7,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF,
            ySrlData: srlAllZeroComponent(count: 4015),
            yRawData: Data(repeating: 0, count: 11),
            cbSrlData: srlAllZeroComponent(count: 4015),
            cbRawData: Data(repeating: 0, count: 11),
            crSrlData: srlAllZeroComponent(count: 4015),
            crRawData: Data(repeating: 0, count: 11)
        )]
    )
    let decoder = RDPRemoteFXDecoder()

    let firstPass = try #require(decoder.decodeProgressive(
        firstPassStream,
        surfaceID: 1,
        codecContextID: 10
    ).tiles.first)
    _ = try decoder.decodeProgressive(
        unrelatedContextStream,
        surfaceID: 1,
        codecContextID: 11
    )
    let upgraded = try #require(decoder.decodeProgressive(
        upgradeStream,
        surfaceID: 1,
        codecContextID: 10
    ).tiles.first)

    #expect(upgraded.bgraData == firstPass.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEDifferenceUsesSurfaceTileAcrossCodecContexts() throws {
    let originalStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )
    let differenceStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            flags: 0x01,
            progressiveQuality: 0xFF
        )]
    )
    let decoder = RDPRemoteFXDecoder()

    let original = try #require(decoder.decodeProgressive(
        originalStream,
        surfaceID: 1,
        codecContextID: 20
    ).tiles.first)
    let difference = try #require(decoder.decodeProgressive(
        differenceStream,
        surfaceID: 1,
        codecContextID: 21
    ).tiles.first)

    #expect(difference.bgraData == original.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEContextDeletionKeepsSurfaceDifferenceState() throws {
    let originalStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )
    let differenceStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            flags: 0x01,
            progressiveQuality: 0xFF
        )]
    )
    let decoder = RDPRemoteFXDecoder()

    let original = try #require(decoder.decodeProgressive(
        originalStream,
        surfaceID: 1,
        codecContextID: 30
    ).tiles.first)
    decoder.removeProgressiveState(surfaceID: 1, codecContextID: 30)
    let difference = try #require(decoder.decodeProgressive(
        differenceStream,
        surfaceID: 1,
        codecContextID: 31
    ).tiles.first)

    #expect(difference.bgraData == original.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEUpgradesOriginalTransform() throws {
    let progressiveQuant = Data([50] + Array(repeating: UInt8(0x11), count: 15))
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionFlags: 0,
        progressiveQuantTables: [progressiveQuant],
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC6,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0
            ),
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC7,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0xFF,
                ySrlData: srlAllZeroComponent(count: 4032),
                yRawData: Data(repeating: 0, count: 8),
                cbSrlData: srlAllZeroComponent(count: 4032),
                cbRawData: Data(repeating: 0, count: 8),
                crSrlData: srlAllZeroComponent(count: 4032),
                crRawData: Data(repeating: 0, count: 8)
            ),
        ]
    )

    let tiles = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream).tiles

    #expect(tiles.count == 2)
    #expect(tiles[1].bgraData == tiles[0].bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEUsesReduceExtrapolateBandSizes() {
    var coefficients = [Int16](repeating: 0, count: 64 * 64)
    for index in 4015 ..< 4096 {
        coefficients[index] = 7
    }

    RDPRemoteFXDecoder.decodeProgressiveDWT(&coefficients)

    #expect(coefficients.allSatisfy { $0 == 7 })
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEMatchesReduceExtrapolateReference() {
    var coefficients: [Int16] = []
    coefficients.reserveCapacity(64 * 64)
    for index in 0 ..< 64 * 64 {
        coefficients.append(Int16((index * 37) % 511 - 255))
    }

    RDPRemoteFXDecoder.decodeProgressiveDWT(&coefficients)

    let expected: [Int: Int16] = [
        0: -352, 1: -69, 2: 510, 31: 56, 32: 293, 33: 96, 63: 91, 64: -140,
        65: -757, 511: 411, 512: -288, 1023: -215, 2047: -194, 3000: 103,
        4031: -95, 4095: 116,
    ]
    for (index, value) in expected {
        #expect(coefficients[index] == value)
    }
    let sum = coefficients.reduce(0) { $0 + Int($1) }
    var weightedSum = 0
    for (index, coefficient) in coefficients.enumerated() {
        weightedSum += (index + 1) * Int(coefficient)
    }
    #expect(sum == -5_407)
    #expect(weightedSum == -17_777_692)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsUpgradeWithoutFirstPass() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC7,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF
        )]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsBackwardUpgradeQuality() throws {
    let lowerBitPosition = Data([25] + Array(repeating: UInt8(0x11), count: 15))
    let higherBitPosition = Data([10] + Array(repeating: UInt8(0x22), count: 15))
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [lowerBitPosition, higherBitPosition],
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC6,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0
            ),
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC7,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 1
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsInvalidProgressiveQuantFactor() throws {
    let invalidQuant = Data([25, 0x19] + Array(repeating: UInt8(0x11), count: 14))
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [invalidQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsQuantIndexOutsideTable() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(yQuantIndex: 1, xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEParallelDecodeReportsTileErrors() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionWidth: 256,
        regionHeight: 128,
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 2, yIndex: 0),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 3, yIndex: 0, flags: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 2, yIndex: 1),
            CAPROGRESSIVERemoteFXGrayTile(xIndex: 3, yIndex: 1),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEDecodesMultipleRegionsInOneFrame() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 9,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
            caprogressiveRemoteFXGrayRegionBlock(
                regionX: 64,
                regionY: 0,
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 0)]
            ),
        ]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.frameIndex == 9)
    #expect(frame.tiles.map { [$0.x, $0.y] } == [[0, 0], [64, 0]])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEAcceptsRegionWithoutNewTiles() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 10,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
            caprogressiveRemoteFXGrayRegionBlock(
                quantCount: 0,
                tiles: []
            ),
        ]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.tiles.map { [$0.x, $0.y] } == [[0, 0]])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVESaturatesDifferenceCoefficients() throws {
    let decoder = RDPRemoteFXDecoder()
    let original = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: 0,
            yIndex: 0,
            yData: rlgrSingleOneComponent()
        )]
    )
    let difference = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: 0,
            yIndex: 0,
            flags: 1,
            yData: rlgrSingleOneComponent()
        )]
    )

    _ = try decoder.decodeProgressive(original)
    var prior = try #require(decoder.decodeProgressive(difference).tiles.first)
    for _ in 0 ..< 253 {
        prior = try #require(decoder.decodeProgressive(difference).tiles.first)
    }
    let saturated = try #require(decoder.decodeProgressive(difference).tiles.first)

    #expect(saturated.bgraData == prior.bgraData)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsTransformChangeForDifferenceTile() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 10,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                regionFlags: 0,
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0, flags: 1)]
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEIgnoresOverstatedRegionCount() throws {
    var frameBeginBody = Data()
    frameBeginBody.appendLittleEndianUInt32(16)
    frameBeginBody.appendLittleEndianUInt16(2)
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 16,
        frameBeginBody: frameBeginBody,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.tiles.map { [$0.x, $0.y] } == [[0, 0]])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsMoreRegionsThanDeclared() throws {
    var frameBeginBody = Data()
    frameBeginBody.appendLittleEndianUInt32(17)
    frameBeginBody.appendLittleEndianUInt16(1)
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 17,
        frameBeginBody: frameBeginBody,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
            caprogressiveRemoteFXGrayRegionBlock(
                regionX: 64,
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 0)]
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEIgnoresRegionOutsideFrame() throws {
    let bitmapStream = caprogressiveRemoteFXGrayRegionBlock(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.frameIndex == nil)
    #expect(frame.tiles.isEmpty)
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEIgnoresUnknownEnvelopeBlock() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 10,
        regions: [
            caprogressiveRemoteFXBlock(type: 0xCAFE, body: Data()),
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.tiles.map { [$0.x, $0.y] } == [[0, 0]])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsInvalidContextTileSize() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 11,
        contextTileSize: 32,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsNonEmptyFrameEnd() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 12,
        frameEndBody: Data([0x00]),
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsInvalidRegionTileSize() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tileSize: 32,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVESupportsOriginalTransform() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionFlags: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    let tile = try #require(RDPRemoteFXDecoder().decodeProgressive(bitmapStream).tiles.first)

    #expect(gnomePixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsReservedRegionFlags() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionFlags: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsAdvertisedTileDataSizeMismatch() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        advertisedTileDataSize: 1,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsTileBodyLengthMismatch() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(
                xIndex: 0,
                yIndex: 0,
                tailData: Data([0x00]),
                advertisedTailByteCount: 2
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsTruncatedRLGRComponent() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: 0,
            yIndex: 0,
            yData: Data([0x80])
        )]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVEIgnoresSyncMagic() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 13,
        syncMagic: 0,
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.tiles.map { [$0.x, $0.y] } == [[0, 0]])
}

@Test func cavideoRemoteFXRejectsInvalidSyncMagic() throws {
    var bitmapStream = cavideoRemoteFXGrayTileStream()
    bitmapStream[6] = 0

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decode(bitmapStream)
    }
}

@Test func cavideoRemoteFXIgnoresRegionFlags() throws {
    for regionFlags: UInt8 in [0, 0xFE] {
        let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
            regionFlags: regionFlags
        ))

        #expect(frame.tiles.count == 1)
    }
}

@Test func cavideoRemoteFXIgnoresCodecVersionProperties() throws {
    let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
        codecVersionID: 42,
        codecVersion: 42
    ))

    #expect(frame.tiles.count == 1)
}

@Test func cavideoRemoteFXTracksFrameSequenceAcrossPayloads() throws {
    let blocks = cavideoRemoteFXBlocks(cavideoRemoteFXGrayTileStream())
    let decoder = RDPRemoteFXDecoder()

    _ = try decoder.decode(cavideoRemoteFXStream(blocks[0 ... 3]))
    let frame = try decoder.decode(cavideoRemoteFXStream(blocks[4 ... 7]))

    #expect(frame.tiles.count == 1)
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

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsInvalidFrameBeginLength() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 14,
        frameBeginBody: Data([0x00]),
        regions: [
            caprogressiveRemoteFXGrayRegionBlock(
                tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
            ),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsZeroRegionRectangles() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        rectangleCount: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsZeroQuantTableCount() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        quantCount: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsTooManyQuantTables() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        quantCount: 8,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func gnomeRemoteDesktopCAPROGRESSIVERejectsTruncatedTileBlockHeader() throws {
    let bitmapStream = caprogressiveRemoteFXEnvelope(
        frameIndex: 15,
        regions: [
            caprogressiveRemoteFXRegionBlock(tileData: Data([0xC5, 0xCC, 0x06])),
        ]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

private func gnomeHex(_ string: String) -> Data {
    let scalars = string.unicodeScalars.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
    let characters = Array(scalars)
    precondition(characters.count.isMultiple(of: 2), "hex fixture must have an even digit count")

    var bytes = [UInt8]()
    bytes.reserveCapacity(characters.count / 2)
    var index = 0
    while index < characters.count {
        let pair = String(String.UnicodeScalarView(characters[index ..< index + 2]))
        guard let byte = UInt8(pair, radix: 16) else {
            preconditionFailure("invalid hex pair \(pair)")
        }
        bytes.append(byte)
        index += 2
    }
    return Data(bytes)
}

private func gnomeWireToSurface2Payload(bitmapData: Data) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.caProgressive)
    payload.appendLittleEndianUInt32(0)
    payload.appendUInt8(0x20)
    payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
    payload.append(bitmapData)
    return payload
}

private func caprogressiveRemoteFXEnvelope(
    frameIndex: UInt32,
    syncMagic: UInt32 = 0xCACC_ACCA,
    contextTileSize: UInt16 = 64,
    frameBeginBody: Data? = nil,
    frameEndBody: Data = Data(),
    regions: [Data]
) -> Data {
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(syncMagic)
    sync.appendLittleEndianUInt16(0x0100)
    stream.append(caprogressiveRemoteFXBlock(type: 0xCCC0, body: sync))

    var context = Data()
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(contextTileSize)
    context.appendUInt8(1)
    stream.append(caprogressiveRemoteFXBlock(type: 0xCCC3, body: context))

    let frameBegin: Data
    if let frameBeginBody {
        frameBegin = frameBeginBody
    } else {
        var body = Data()
        body.appendLittleEndianUInt32(frameIndex)
        body.appendLittleEndianUInt16(UInt16(regions.count))
        frameBegin = body
    }
    stream.append(caprogressiveRemoteFXBlock(type: 0xCCC1, body: frameBegin))

    for region in regions {
        stream.append(region)
    }
    stream.append(caprogressiveRemoteFXBlock(type: 0xCCC2, body: frameEndBody))
    return stream
}

private func caprogressiveRemoteFXRegionBlock(tileData: Data) -> Data {
    var region = Data()
    region.appendUInt8(64)
    region.appendLittleEndianUInt16(1)
    region.appendUInt8(1)
    region.appendUInt8(0)
    region.appendUInt8(1)
    region.appendLittleEndianUInt16(1)
    region.appendLittleEndianUInt32(UInt32(tileData.count))
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(64)
    region.appendLittleEndianUInt16(64)
    region.append(contentsOf: [0x66, 0x66, 0x77, 0x88, 0x98])
    region.append(tileData)
    return caprogressiveRemoteFXBlock(type: 0xCCC4, body: region)
}

private func caprogressiveRemoteFXBlock(type: UInt16, body: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt32(UInt32(6 + body.count))
    data.append(body)
    return data
}

private func cavideoRemoteFXBlocks(_ stream: Data) -> [Data] {
    var blocks: [Data] = []
    var offset = 0
    while offset < stream.count {
        let length = Int(UInt32(stream[offset + 2])
            | UInt32(stream[offset + 3]) << 8
            | UInt32(stream[offset + 4]) << 16
            | UInt32(stream[offset + 5]) << 24)
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

private func gnomeGraphicsMessage(commandID: UInt16, payload: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(commandID)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt32(UInt32(payload.count + 8))
    data.append(payload)
    return data
}

private func gnomePixel(atX x: Int, y: Int, data: Data, bytesPerRow: Int) -> [UInt8] {
    let index = y * bytesPerRow + x * 4
    return Array(data[index ..< index + 4])
}
