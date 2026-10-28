import Foundation
@testable import RDPKit
import Testing

@Test(arguments: [RDPRemoteFXDecoder.EntropyAlgorithm.rlgr1, .rlgr3])
func rlgrDecodesSpecEncoderOutput(algorithm: RDPRemoteFXDecoder.EntropyAlgorithm) throws {
    var generator = SplitMix64(state: algorithm == .rlgr1 ? 1 : 3)
    var values = [Int16](repeating: 0, count: 64 * 64)
    for index in 0 ..< 4000 where Int.random(in: 0 ..< 3, using: &generator) == 0 {
        values[index] = Int16.random(in: -2000 ... 2000, using: &generator)
    }
    for index in 0 ..< 200 {
        values[index] = Int16.random(in: -3 ... 3, using: &generator)
    }

    var decoded = [Int16](repeating: 0, count: values.count)
    try RDPRemoteFXDecoder.decodeRLGR(
        rlgrEncode(values, algorithm: algorithm),
        algorithm: algorithm,
        into: &decoded
    )

    #expect(decoded == values)
}

@Test func caprogressiveUpgradePassesReconstructSimpleTile() throws {
    // Coefficients as a tile-simple block carries them, with LL3 (the last 81
    // reduce-extrapolate coefficients) differentially coded on the wire.
    var generator = SplitMix64(state: 5)
    var coefficients = [Int16](repeating: 0, count: 64 * 64)
    for index in 0 ..< 4015 where Int.random(in: 0 ..< 6, using: &generator) == 0 {
        coefficients[index] = Int16.random(in: -40 ... 40, using: &generator)
    }
    for index in 4015 ..< 4096 {
        coefficients[index] = Int16.random(in: -60 ... 60, using: &generator)
    }
    let simple = caprogressiveRemoteFXGrayTilesStream(tiles: [CAPROGRESSIVERemoteFXGrayTile(
        xIndex: 0,
        yIndex: 0,
        yData: rlgrEncode(differentialLL3(coefficients), algorithm: .rlgr1)
    )])

    // First pass at bit position 2: HL/LH/HH round toward zero, LL3 toward
    // negative infinity. The upgrade to full quality sends the two dropped bits:
    // SRL coded where nothing nonzero was sent yet, raw magnitudes elsewhere.
    let firstPass = coefficients.indices.map { index in
        index < 4015 ? coefficients[index] / 4 : coefficients[index] >> 2
    }
    var srlValues: [Int16] = []
    var raw = BitWriter()
    for index in coefficients.indices {
        let remainder = coefficients[index] - firstPass[index] * 4
        if index < 4015, firstPass[index] == 0 {
            srlValues.append(remainder)
        } else {
            raw.appendBits(UInt32(remainder.magnitude), count: 2)
        }
    }
    let zeroLL3RawBits = Data(repeating: 0, count: 21)
    let progressive = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: [Data([50] + Array(repeating: UInt8(0x22), count: 15))],
        tiles: [
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC6,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0,
                yData: rlgrEncode(differentialLL3(firstPass), algorithm: .rlgr1)
            ),
            CAPROGRESSIVERemoteFXGrayTile(
                blockType: 0xCCC7,
                xIndex: 0,
                yIndex: 0,
                progressiveQuality: 0xFF,
                ySrlData: srlEncode(srlValues, magnitudeBitCount: 2),
                yRawData: raw.data(),
                cbSrlData: srlAllZeroComponent(count: 4015),
                cbRawData: zeroLL3RawBits,
                crSrlData: srlAllZeroComponent(count: 4015),
                crRawData: zeroLL3RawBits
            ),
        ]
    )

    let expected = try #require(RDPRemoteFXDecoder().decodeProgressive(simple).tiles.first)
    let passes = try RDPRemoteFXDecoder().decodeProgressive(progressive).tiles

    #expect(passes.count == 2)
    #expect(passes.first?.bgraData != expected.bgraData)
    #expect(passes.last?.bgraData == expected.bgraData)
}

@Test func caprogressiveKeepsRefinementStateOfRecentCodecContextsOnly() throws {
    let quantTables = [Data([50] + Array(repeating: UInt8(0x22), count: 15))]
    let firstPass = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: quantTables,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(blockType: 0xCCC6, xIndex: 0, yIndex: 0, progressiveQuality: 0)]
    )
    let zeroLL3RawBits = Data(repeating: 0, count: 21)
    let upgrade = caprogressiveRemoteFXGrayTilesStream(
        progressiveQuantTables: quantTables,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC7,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0xFF,
            ySrlData: srlAllZeroComponent(count: 4015),
            yRawData: zeroLL3RawBits,
            cbSrlData: srlAllZeroComponent(count: 4015),
            cbRawData: zeroLL3RawBits,
            crSrlData: srlAllZeroComponent(count: 4015),
            crRawData: zeroLL3RawBits
        )]
    )
    let decoder = RDPRemoteFXDecoder()
    for codecContextID in UInt32(1) ... 5 {
        _ = try decoder.decodeProgressive(firstPass, codecContextID: codecContextID)
    }

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try decoder.decodeProgressive(upgrade, codecContextID: 1)
    }
    #expect(try decoder.decodeProgressive(upgrade, codecContextID: 2).tiles.count == 1)
}

@Test func caprogressiveDequantizesWithCombinedShift() throws {
    // A zero LL3 quantization value is valid (MS-RDPEGFX 2.2.4.2.1.5.2); with a
    // progressive bit position of 1 the LL3 shift is 0 + 1 - 1 = 0.
    let zeroLL3Quant = Data([0x60, 0x66, 0x77, 0x88, 0x98])
    let firstPass = caprogressiveRemoteFXGrayTilesStream(
        quantData: zeroLL3Quant,
        progressiveQuantTables: [Data([50] + Array(repeating: UInt8(0x11), count: 15))],
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            blockType: 0xCCC6,
            xIndex: 0,
            yIndex: 0,
            progressiveQuality: 0
        )]
    )
    let simple = caprogressiveRemoteFXGrayTilesStream(
        quantData: zeroLL3Quant,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 0, yIndex: 0)]
    )

    #expect(try RDPRemoteFXDecoder().decodeProgressive(firstPass).tiles.count == 1)
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(simple)
    }
}

@Test func caprogressiveRejectsTilesOutsideTheSurface() throws {
    let insideTile = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 1, yIndex: 1)]
    )
    let outsideTile = caprogressiveRemoteFXGrayTilesStream(
        tiles: [CAPROGRESSIVERemoteFXGrayTile(xIndex: 2, yIndex: 0)]
    )

    let frame = try RDPRemoteFXDecoder().decodeProgressive(insideTile, surfaceSize: (width: 65, height: 65))

    #expect(frame.tiles.map { [$0.x, $0.y] } == [[64, 64]])
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        _ = try RDPRemoteFXDecoder().decodeProgressive(outsideTile, surfaceSize: (width: 128, height: 64))
    }
}

@Test func cavideoRemoteFXDecodesLargeTileSetInOrder() throws {
    let positions = (0 ..< 12).map { (x: UInt16($0 % 4), y: UInt16($0 / 4)) }

    let frame = try RDPRemoteFXDecoder().decode(cavideoRemoteFXGrayTileStream(
        channelWidth: 256,
        channelHeight: 192,
        regionWidth: 256,
        regionHeight: 192,
        tilePositions: positions
    ))

    #expect(frame.tiles.map { [$0.x, $0.y] } == positions.map { [Int($0.x) * 64, Int($0.y) * 64] })
    #expect(frame.tiles.allSatisfy { $0.bgraData.prefix(4) == Data([0x80, 0x80, 0x80, 0xFF]) })
}

@Test func remoteFXDecodersAcceptDataSlices() throws {
    let progressive = caprogressiveRemoteFXGrayTilesStream(
        regionWidth: 256,
        regionHeight: 128,
        tiles: (0 ..< 8).map { CAPROGRESSIVERemoteFXGrayTile(xIndex: UInt16($0 % 4), yIndex: UInt16($0 / 4)) }
    )
    let classic = cavideoRemoteFXGrayTileStream()

    let progressiveSlice = (Data([0xAA, 0xBB]) + progressive).dropFirst(2)
    let classicSlice = (Data([0xAA, 0xBB]) + classic).dropFirst(2)

    #expect(progressiveSlice.startIndex == 2)
    #expect(try RDPRemoteFXDecoder().decodeProgressive(progressiveSlice)
        == RDPRemoteFXDecoder().decodeProgressive(progressive))
    #expect(try RDPRemoteFXDecoder().decode(classicSlice) == RDPRemoteFXDecoder().decode(classic))
}

private func differentialLL3(_ values: [Int16]) -> [Int16] {
    var encoded = values
    for index in 4016 ..< 4096 {
        encoded[index] = values[index] - values[index - 1]
    }
    return encoded
}

/// RLGR encoder transcribed from the MS-RDPRFX 3.1.8.1.7.1 pseudo-code.
private func rlgrEncode(_ values: [Int16], algorithm: RDPRemoteFXDecoder.EntropyAlgorithm) -> Data {
    var writer = BitWriter()
    var kp = 8
    var krp = 8
    var index = 0

    func update(_ parameter: inout Int, by delta: Int) {
        parameter = min(max(parameter + delta, 0), 80)
    }
    func codeGolombRice(_ value: Int) {
        let kr = krp >> 3
        let unary = value >> kr
        for _ in 0 ..< unary {
            writer.appendBit(1)
        }
        writer.appendBit(0)
        writer.appendBits(UInt32(value & ((1 << kr) - 1)), count: kr)
        if unary == 0 {
            update(&krp, by: -2)
        } else if unary > 1 {
            update(&krp, by: unary)
        }
    }
    func twoMagnitudeMinusSign(_ value: Int16) -> Int {
        value < 0 ? -2 * Int(value) - 1 : 2 * Int(value)
    }

    while index < values.count {
        if kp >> 3 > 0 {
            var zeroCount = 0
            while index < values.count, values[index] == 0 {
                zeroCount += 1
                index += 1
            }
            while zeroCount >= 1 << (kp >> 3) {
                zeroCount -= 1 << (kp >> 3)
                writer.appendBit(0)
                update(&kp, by: 4)
            }
            writer.appendBit(1)
            writer.appendBits(UInt32(zeroCount), count: kp >> 3)
            guard index < values.count else {
                break
            }
            writer.appendBit(values[index] < 0 ? 1 : 0)
            codeGolombRice(Int(values[index].magnitude) - 1)
            index += 1
            update(&kp, by: -6)
        } else if algorithm == .rlgr3 {
            let first = twoMagnitudeMinusSign(values[index])
            let second = index + 1 < values.count ? twoMagnitudeMinusSign(values[index + 1]) : 0
            index += 2
            let sum = first + second
            codeGolombRice(sum)
            writer.appendBits(UInt32(first), count: sum == 0 ? 0 : Int.bitWidth - sum.leadingZeroBitCount)
            if first != 0, second != 0 {
                update(&kp, by: -6)
            } else if first == 0, second == 0 {
                update(&kp, by: 6)
            }
        } else {
            let code = twoMagnitudeMinusSign(values[index])
            index += 1
            codeGolombRice(code)
            update(&kp, by: code == 0 ? 3 : -3)
        }
    }
    return writer.data()
}

/// SRL encoder (MS-RDPEGFX 3.1.8.1.5) for values whose magnitude fits `magnitudeBitCount` bits.
private func srlEncode(_ values: [Int16], magnitudeBitCount: Int) -> Data {
    var writer = BitWriter()
    var kp = 8
    var zeroCount = 0

    func writeZeroRun(terminated: Bool) {
        while zeroCount >= 1 << (kp >> 3) {
            zeroCount -= 1 << (kp >> 3)
            writer.appendBit(0)
            kp = min(kp + 4, 80)
        }
        if terminated || zeroCount > 0 {
            writer.appendBit(1)
            writer.appendBits(UInt32(zeroCount), count: kp >> 3)
            zeroCount = 0
            kp = max(kp - 6, 0)
        }
    }

    for value in values {
        guard value != 0 else {
            zeroCount += 1
            continue
        }
        writeZeroRun(terminated: true)
        writer.appendBit(value < 0 ? 1 : 0)
        let magnitude = Int(value.magnitude)
        for _ in 1 ..< magnitude {
            writer.appendBit(0)
        }
        if magnitude < (1 << magnitudeBitCount) - 1 {
            writer.appendBit(1)
        }
    }
    writeZeroRun(terminated: false)
    var data = writer.data()
    data.appendUInt8(0)
    return data
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
