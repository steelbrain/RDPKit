import Foundation
@testable import RDPKit
import Testing

// RemoteFX Progressive (CAPROGRESSIVE, [MS-RDPEGFX] 2.2.4.2 and 3.1.8.1) decoding,
// on synthetic streams. gnome-remote-desktop sends it as RDPGFX_WIRE_TO_SURFACE_2.

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

/// gnome-remote-desktop 51 with the `legacy` graphics profile: its first frame is one
/// WireToSurface2 of 240 RFX_PROGRESSIVE_TILE_SIMPLE tiles (original DWT, no reduce-extrapolate)
/// covering the 1280x720 surface. The screen shows a 1000x562 colour-bar test pattern,
/// letterboxed in black, beside the desktop background.
@Test func replaysGnomeProgressiveTranscriptToTestPatternColours() throws {
    let report = try replayTranscriptFixture("gnome-progressive-transcript", graphicsCapabilityProfile: .legacy).report
    #expect(report.status == "success")
    #expect(report.rdpGraphicsUpdateMessages?.contains {
        $0.codecName == "caprogressive" && $0.progressiveTileSimpleCount == 240
    } == true)
    let frame = try #require(report.rdpGraphicsFirstFrame)
    #expect(frame.contentKind == .bitmap)
    #expect(frame.surfaceRect == RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720))
    #expect(frame.regionRects == [RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720)])
    let data = try #require(frame.decodedBitmapData)
    let bytesPerRow = try #require(frame.decodedBitmapBytesPerRow)

    // Red, green, yellow, blue, magenta and cyan bars, as RGB.
    let expected: [(x: Int, y: Int, rgb: [Int])] = [
        (80, 300, [254, 23, 0]), (250, 300, [0, 215, 0]), (420, 300, [254, 239, 0]),
        (580, 300, [0, 15, 255]), (750, 300, [254, 38, 255]), (920, 300, [0, 231, 255]),
        // The grey bar, the letterbox and the desktop background.
        (249, 500, [128, 127, 128]), (500, 40, [0, 0, 0]), (640, 690, [0, 0, 0]), (1100, 300, [20, 56, 92]),
    ]
    for (x, y, rgb) in expected {
        let bgra = pixel(atX: x, y: y, data: data, bytesPerRow: bytesPerRow)
        let decoded = [Int(bgra[2]), Int(bgra[1]), Int(bgra[0])]
        #expect(zip(decoded, rgb).allSatisfy { abs($0 - $1) <= 2 } && bgra[3] == 0xFF, "(\(x), \(y)): \(decoded)")
    }
}

@Test func caprogressiveTileSimpleSummarizesAndDecodes() throws {
    // GRD can send its first frame as RDPGFX_WIRE_TO_SURFACE_2 with
    // CAPROGRESSIVE tile-simple blocks instead of AVC video. The tail bytes are
    // intentionally non-empty because CAPROGRESSIVE tile-simple carries a tail
    // field that the decoder must ignore.
    let bitmapStream = caprogressiveRemoteFXGrayTileStream(
        frameIndex: 7,
        tailData: Data([0xDE, 0xAD, 0xBE, 0xEF])
    )
    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(
        from: graphicsMessage(
            commandID: RDPGFXCommandID.wireToSurface2,
            payload: wireToSurface2Payload(bitmapData: bitmapStream)
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
        pixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow)
            == [0x80, 0x80, 0x80, 0xFF]
    )
    #expect(pixel(atX: 63, y: 63, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func caprogressiveMultiTileDecodePreservesOrder() throws {
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
        from: graphicsMessage(
            commandID: RDPGFXCommandID.wireToSurface2,
            payload: wireToSurface2Payload(bitmapData: bitmapStream)
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
        #expect(pixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
    }
}

@Test func caprogressiveRejectsAdvertisedTileCountMismatch() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        advertisedTileCount: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsUnsupportedTileBlockType() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(blockType: 0xCCC8, xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveDecodesFullQualityFirstPass() throws {
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

@Test func caprogressiveValidatesFirstPassQualityIndex() throws {
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

@Test func caprogressiveAppliesFirstPassQuantization() throws {
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

@Test func caprogressiveAppliesUpgradePass() throws {
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

@Test func caprogressiveKeepsCodecContextReferencesIndependent() throws {
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
        regionX: 64,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 0)]
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

@Test func caprogressiveTileFromAnotherCodecContextEndsTheUpgrades() throws {
    let progressiveQuant = Data([50] + Array(repeating: UInt8(0x11), count: 15))
    let firstPassStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [progressiveQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(blockType: 0xCCC6, xIndex: 0, yIndex: 0, progressiveQuality: 0)]
    )
    let upgradeStream = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 3,
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
    _ = try decoder.decodeProgressive(firstPassStream, surfaceID: 1, codecContextID: 10)

    // Context 11 replaces the tile, so context 10's first pass no longer describes it.
    _ = try decoder.decodeProgressive(
        caprogressiveRemoteFXGrayTilesStream(frameIndex: 2, tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]),
        surfaceID: 1,
        codecContextID: 11
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try decoder.decodeProgressive(upgradeStream, surfaceID: 1, codecContextID: 10)
    }
}

@Test func caprogressiveDifferenceUsesSurfaceTileAcrossCodecContexts() throws {
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

@Test func caprogressiveContextDeletionKeepsSurfaceDifferenceState() throws {
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

@Test func caprogressiveUpgradesOriginalTransform() throws {
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

@Test func caprogressiveUsesReduceExtrapolateBandSizes() {
    var coefficients = [Int16](repeating: 0, count: 64 * 64)
    for index in 4015 ..< 4096 {
        coefficients[index] = 7
    }

    RDPRemoteFXDecoder.decodeProgressiveDWT(&coefficients)

    #expect(coefficients.allSatisfy { $0 == 7 })
}

@Test func caprogressiveMatchesReduceExtrapolateReference() {
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

@Test func caprogressiveRejectsUpgradeWithoutFirstPass() throws {
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

@Test func caprogressiveRejectsBackwardUpgradeQuality() throws {
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

@Test func caprogressiveRejectsInvalidProgressiveQuantFactor() throws {
    let invalidQuant = Data([25, 0x19] + Array(repeating: UInt8(0x11), count: 14))
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [invalidQuant],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsQuantIndexOutsideTable() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(yQuantIndex: 1, xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveParallelDecodeReportsTileErrors() throws {
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

@Test func caprogressiveDecodesMultipleRegionsInOneFrame() throws {
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

@Test func caprogressiveAcceptsRegionWithoutNewTiles() throws {
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

@Test func caprogressiveSaturatesDifferenceCoefficients() throws {
    // With every quantization factor at 15 the coefficient of magnitude 1
    // dequantizes to 1 << 14, so adding it twice leaves the Int16 range.
    let quantData = Data(repeating: 0xFF, count: 5)
    let decoder = RDPRemoteFXDecoder()
    let original = caprogressiveRemoteFXGrayTilesStream(
        quantData: quantData,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: 0,
            yIndex: 0,
            yData: rlgrSingleOneComponent()
        )]
    )
    let difference = caprogressiveRemoteFXGrayTilesStream(
        frameIndex: 2,
        quantData: quantData,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: 0,
            yIndex: 0,
            flags: 1,
            yData: rlgrSingleOneComponent()
        )]
    )

    _ = try decoder.decodeProgressive(original)
    let prior = try #require(decoder.decodeProgressive(difference).tiles.first)
    let saturated = try #require(decoder.decodeProgressive(difference).tiles.first)

    #expect(saturated.bgraData == prior.bgraData)
}

@Test func caprogressiveRejectsTransformChangeForDifferenceTile() throws {
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

@Test func caprogressiveIgnoresOverstatedRegionCount() throws {
    // The decoder SHOULD ignore a regionCount above the regions present (MS-RDPEGFX 2.2.4.2.1.2).
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

@Test func caprogressiveRejectsMoreRegionsThanDeclared() throws {
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

@Test func caprogressiveIgnoresRegionOutsideFrame() throws {
    // Regions outside FRAME_BEGIN/FRAME_END MUST be ignored (MS-RDPEGFX 2.2.4.2.1.5).
    let bitmapStream = caprogressiveRemoteFXGrayRegionBlock(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)

    #expect(frame.frameIndex == nil)
    #expect(frame.tiles.isEmpty)
}

@Test func caprogressiveIgnoresUnknownEnvelopeBlock() throws {
    // Unknown block types SHOULD be skipped (MS-RDPEGFX 2.2.4.2.1).
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

@Test func caprogressiveRejectsInvalidContextTileSize() throws {
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

@Test func caprogressiveRejectsNonEmptyFrameEnd() throws {
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

@Test func caprogressiveRejectsInvalidRegionTileSize() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        tileSize: 32,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveSupportsOriginalTransform() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionFlags: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    let tile = try #require(RDPRemoteFXDecoder().decodeProgressive(bitmapStream).tiles.first)

    #expect(pixel(atX: 0, y: 0, data: tile.bgraData, bytesPerRow: tile.bytesPerRow) == [0x80, 0x80, 0x80, 0xFF])
}

@Test func caprogressiveRejectsReservedRegionFlags() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        regionFlags: 2,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsAdvertisedTileDataSizeMismatch() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        advertisedTileDataSize: 1,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsTileBodyLengthMismatch() throws {
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

@Test func caprogressiveRejectsTruncatedRLGRComponent() throws {
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

@Test func caprogressiveIgnoresSyncMagic() throws {
    // The decoder SHOULD ignore the progressive sync magic (MS-RDPEGFX 2.2.4.2.1.1).
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

@Test func caprogressiveRejectsInvalidFrameBeginLength() throws {
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

@Test func caprogressiveRejectsZeroRegionRectangles() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        rectangleCount: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsZeroQuantTableCount() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        quantCount: 0,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsTooManyQuantTables() throws {
    let bitmapStream = caprogressiveRemoteFXGrayTilesStream(
        quantCount: 8,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(bitmapStream)
    }
}

@Test func caprogressiveRejectsTruncatedTileBlockHeader() throws {
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

private func wireToSurface2Payload(bitmapData: Data) -> Data {
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
