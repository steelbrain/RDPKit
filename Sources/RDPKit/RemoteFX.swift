import Foundation

struct RDPRemoteFXDecodedTile: Equatable, Sendable {
    var x: Int
    var y: Int
    var bgraData: Data
    var bytesPerRow: Int
}

struct RDPRemoteFXDecodedFrame: Equatable, Sendable {
    var frameIndex: UInt32?
    var tiles: [RDPRemoteFXDecodedTile]
}

final class RDPRemoteFXDecoder {
    private enum BlockType {
        static let tile: UInt16 = 0xCAC3
        static let sync: UInt16 = 0xCCC0
        static let codecVersions: UInt16 = 0xCCC1
        static let channels: UInt16 = 0xCCC2
        static let context: UInt16 = 0xCCC3
        static let frameBegin: UInt16 = 0xCCC4
        static let frameEnd: UInt16 = 0xCCC5
        static let region: UInt16 = 0xCCC6
        static let tileSet: UInt16 = 0xCCC7
    }

    private enum EntropyAlgorithm {
        case rlgr1
        case rlgr3
    }

    private struct Block {
        var type: UInt16
        var body: Data
    }

    private struct Quant {
        var ll3: UInt8
        var lh3: UInt8
        var hl3: UInt8
        var hh3: UInt8
        var lh2: UInt8
        var hl2: UInt8
        var hh2: UInt8
        var lh1: UInt8
        var hl1: UInt8
        var hh1: UInt8
    }

    private struct Tile {
        var yQuantIndex: Int
        var cbQuantIndex: Int
        var crQuantIndex: Int
        var xIndex: Int
        var yIndex: Int
        var yData: Data
        var cbData: Data
        var crData: Data
    }

    private var contextEntropyAlgorithm: EntropyAlgorithm = .rlgr1
    private var channelWidth: Int?
    private var channelHeight: Int?

    func decode(_ data: Data) throws -> RDPRemoteFXDecodedFrame {
        var cursor = ByteCursor(data)
        var frameIndex: UInt32?
        var decodedTiles: [RDPRemoteFXDecodedTile] = []

        while cursor.remaining > 0 {
            let block = try Self.readBlock(from: &cursor)
            switch block.type {
            case BlockType.sync:
                try Self.parseSync(block.body)
            case BlockType.codecVersions:
                try Self.parseCodecVersions(block.body)
            case BlockType.channels:
                try parseChannels(block.body)
            case BlockType.context:
                contextEntropyAlgorithm = try Self.parseContext(block.body)
            case BlockType.frameBegin:
                frameIndex = try Self.parseFrameBegin(block.body)
            case BlockType.region:
                try Self.parseRegion(block.body)
            case BlockType.tileSet:
                decodedTiles += try decodeTileSet(block.body)
            case BlockType.frameEnd:
                try Self.parseFrameEnd(block.body)
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        return RDPRemoteFXDecodedFrame(frameIndex: frameIndex, tiles: decodedTiles)
    }

    private static func readBlock(from cursor: inout ByteCursor) throws -> Block {
        guard cursor.remaining >= 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let blockType = try cursor.readLittleEndianUInt16()
        let blockLength = try cursor.readLittleEndianUInt32()
        guard blockLength >= 6,
              UInt64(blockLength - 6) <= UInt64(cursor.remaining)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return Block(
            type: blockType,
            body: try cursor.readData(count: Int(blockLength - 6))
        )
    }

    private static func parseCodecChannelHeader(_ cursor: inout ByteCursor, channelID: UInt8) throws {
        guard cursor.remaining >= 2,
              try cursor.readUInt8() == 1,
              try cursor.readUInt8() == channelID
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseSync(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 6,
              try cursor.readLittleEndianUInt32() == 0xCACC_ACCA,
              try cursor.readLittleEndianUInt16() == 0x0100
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseCodecVersions(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let codecCount = try Int(cursor.readUInt8())
        guard cursor.remaining == codecCount * 3 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for _ in 0 ..< codecCount {
            guard try cursor.readUInt8() == 1,
                  try cursor.readLittleEndianUInt16() == 0x0100
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
    }

    private func parseChannels(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let channelCount = try Int(cursor.readUInt8())
        guard channelCount > 0,
              cursor.remaining == channelCount * 5
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for channelIndex in 0 ..< channelCount {
            guard try cursor.readUInt8() == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let width = try Int(cursor.readLittleEndianUInt16())
            let height = try Int(cursor.readLittleEndianUInt16())
            if channelIndex == 0 {
                channelWidth = width
                channelHeight = height
            }
        }
    }

    private static func parseContext(_ data: Data) throws -> EntropyAlgorithm {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0xFF)
        guard cursor.remaining == 5,
              try cursor.readUInt8() == 0,
              try cursor.readLittleEndianUInt16() == 64
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try entropyAlgorithm(from: (cursor.readLittleEndianUInt16() >> 9) & 0x0F)
    }

    private static func parseFrameBegin(_ data: Data) throws -> UInt32 {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let frameIndex = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt16()
        return frameIndex
    }

    private static func parseFrameEnd(_ data: Data) throws {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseRegion(_ data: Data) throws {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 7 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let flags = try cursor.readUInt8()
        guard flags & 0x01 == 0x01 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        guard cursor.remaining >= rectangleCount * 8 + 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for _ in 0 ..< rectangleCount {
            _ = try cursor.readLittleEndianUInt16()
            _ = try cursor.readLittleEndianUInt16()
            _ = try cursor.readLittleEndianUInt16()
            _ = try cursor.readLittleEndianUInt16()
        }
        guard try cursor.readLittleEndianUInt16() == 0xCAC1,
              try cursor.readLittleEndianUInt16() == 1,
              cursor.remaining == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private func decodeTileSet(_ data: Data) throws -> [RDPRemoteFXDecodedTile] {
        var cursor = ByteCursor(data)
        try Self.parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 14,
              try cursor.readLittleEndianUInt16() == 0xCAC2,
              try cursor.readLittleEndianUInt16() == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let properties = try cursor.readLittleEndianUInt16()
        let entropyAlgorithm = try Self.entropyAlgorithm(from: (properties >> 10) & 0x0F)
        let quantCount = try Int(cursor.readUInt8())
        guard try cursor.readUInt8() == 64 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let expectedTileCount = try Int(cursor.readLittleEndianUInt16())
        let tilesDataSize = try Int(cursor.readLittleEndianUInt32())
        guard cursor.remaining == quantCount * 5 + tilesDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var quants: [Quant] = []
        quants.reserveCapacity(quantCount)
        for _ in 0 ..< quantCount {
            quants.append(try Self.parseQuant(from: &cursor))
        }

        var tileCursor = ByteCursor(try cursor.readData(count: tilesDataSize))
        var tiles: [Tile] = []
        tiles.reserveCapacity(expectedTileCount)
        while tileCursor.remaining > 0 {
            tiles.append(try Self.parseTileBlock(from: &tileCursor))
        }
        guard tiles.count == expectedTileCount,
              cursor.remaining == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return try tiles.map { tile in
            guard tile.yQuantIndex < quants.count,
                  tile.cbQuantIndex < quants.count,
                  tile.crQuantIndex < quants.count
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let y = try Self.decodeComponent(
                tile.yData,
                quant: quants[tile.yQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            let cb = try Self.decodeComponent(
                tile.cbData,
                quant: quants[tile.cbQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            let cr = try Self.decodeComponent(
                tile.crData,
                quant: quants[tile.crQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            return RDPRemoteFXDecodedTile(
                x: tile.xIndex * 64,
                y: tile.yIndex * 64,
                bgraData: Self.bgraData(y: y, cb: cb, cr: cr),
                bytesPerRow: 64 * 4
            )
        }
    }

    private static func parseQuant(from cursor: inout ByteCursor) throws -> Quant {
        let ll3lh3 = try cursor.readUInt8()
        let hl3hh3 = try cursor.readUInt8()
        let lh2hl2 = try cursor.readUInt8()
        let hh2lh1 = try cursor.readUInt8()
        let hl1hh1 = try cursor.readUInt8()
        return Quant(
            ll3: ll3lh3 & 0x0F,
            lh3: ll3lh3 >> 4,
            hl3: hl3hh3 & 0x0F,
            hh3: hl3hh3 >> 4,
            lh2: lh2hl2 & 0x0F,
            hl2: lh2hl2 >> 4,
            hh2: hh2lh1 & 0x0F,
            lh1: hh2lh1 >> 4,
            hl1: hl1hh1 & 0x0F,
            hh1: hl1hh1 >> 4
        )
    }

    private static func parseTileBlock(from cursor: inout ByteCursor) throws -> Tile {
        let block = try readBlock(from: &cursor)
        guard block.type == BlockType.tile else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var bodyCursor = ByteCursor(block.body)
        guard bodyCursor.remaining >= 13 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let yQuantIndex = try Int(bodyCursor.readUInt8())
        let cbQuantIndex = try Int(bodyCursor.readUInt8())
        let crQuantIndex = try Int(bodyCursor.readUInt8())
        let xIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let yIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let yByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let cbByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let crByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        guard bodyCursor.remaining == yByteCount + cbByteCount + crByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return Tile(
            yQuantIndex: yQuantIndex,
            cbQuantIndex: cbQuantIndex,
            crQuantIndex: crQuantIndex,
            xIndex: xIndex,
            yIndex: yIndex,
            yData: try bodyCursor.readData(count: yByteCount),
            cbData: try bodyCursor.readData(count: cbByteCount),
            crData: try bodyCursor.readData(count: crByteCount)
        )
    }

    private static func entropyAlgorithm(from bits: UInt16) throws -> EntropyAlgorithm {
        switch bits {
        case 0x01:
            return .rlgr1
        case 0x04:
            return .rlgr3
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func decodeComponent(
        _ data: Data,
        quant: Quant,
        entropyAlgorithm: EntropyAlgorithm
    ) throws -> [Int16] {
        guard !data.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var buffer = [Int16](repeating: 0, count: 64 * 64)
        try decodeRLGR(data, algorithm: entropyAlgorithm, output: &buffer)
        decodeDifferential(&buffer, start: 4032, count: 64)
        try decodeQuantization(&buffer, quant: quant)
        var temp = [Int16](repeating: 0, count: 64 * 64)
        decodeDWT(&buffer, temp: &temp)
        return buffer
    }

    private static func decodeRLGR(_ data: Data, algorithm: EntropyAlgorithm, output: inout [Int16]) throws {
        var k: UInt32 = 1
        var kr: UInt32 = 1
        var kp = k << 3
        var krp = kr << 3
        var outputIndex = 0
        var bits = BitReader(data)

        while !bits.isEmpty, outputIndex < output.count {
            if k != 0 {
                let leadingZeros = bits.consumeLeading(bit: 0)
                guard bits.readBits(count: 1) != nil else {
                    break
                }
                var run = countRun(leadingZeros, k: &k, kp: &kp)
                guard let runRemainder = bits.readBits(count: Int(k)) else {
                    break
                }
                run += runRemainder

                guard let signBit = bits.readBits(count: 1) else {
                    break
                }
                let leadingOnes = bits.consumeLeading(bit: 1)
                guard bits.readBits(count: 1) != nil,
                      let codeRemainderBits = bits.readBits(count: Int(kr))
                else {
                    break
                }
                let codeRemainder = codeRemainderBits + (UInt32(leadingOnes) << kr)
                updateGRParameters(leadingOnes, kr: &kr, krp: &krp)
                kp = kp.saturatingSubtracting(6)
                k = kp >> 3
                let magnitude = try rlMagnitude(signBit: signBit, codeRemainder: codeRemainder)

                let zerosToWrite = min(Int(run), output.count - outputIndex)
                if zerosToWrite > 0 {
                    for index in outputIndex ..< outputIndex + zerosToWrite {
                        output[index] = 0
                    }
                    outputIndex += zerosToWrite
                }
                if outputIndex < output.count {
                    output[outputIndex] = magnitude
                    outputIndex += 1
                }
            } else {
                let leadingOnes = bits.consumeLeading(bit: 1)
                guard bits.readBits(count: 1) != nil,
                      let codeRemainderBits = bits.readBits(count: Int(kr))
                else {
                    break
                }
                let codeRemainder = codeRemainderBits + (UInt32(leadingOnes) << kr)
                updateGRParameters(leadingOnes, kr: &kr, krp: &krp)

                switch algorithm {
                case .rlgr1:
                    let magnitude = try rlgr1Magnitude(codeRemainder: codeRemainder, k: &k, kp: &kp)
                    if outputIndex < output.count {
                        output[outputIndex] = magnitude
                        outputIndex += 1
                    }
                case .rlgr3:
                    let nIndex = nIndex(codeRemainder)
                    guard let val1 = bits.readBits(count: nIndex) else {
                        break
                    }
                    let val2 = codeRemainder - val1
                    if val1 != 0, val2 != 0 {
                        kp = kp.saturatingSubtracting(6)
                        k = kp >> 3
                    } else if val1 == 0, val2 == 0 {
                        kp = min(kp + 6, 80)
                        k = kp >> 3
                    }
                    if outputIndex < output.count {
                        output[outputIndex] = try rlgr3Magnitude(val1)
                        outputIndex += 1
                    }
                    if outputIndex < output.count {
                        output[outputIndex] = try rlgr3Magnitude(val2)
                        outputIndex += 1
                    }
                }
            }
        }

        if outputIndex < output.count {
            for index in outputIndex ..< output.count {
                output[index] = 0
            }
        }
    }

    private static func countRun(_ leadingZeros: Int, k: inout UInt32, kp: inout UInt32) -> UInt32 {
        var run: UInt32 = 0
        for _ in 0 ..< leadingZeros {
            run += 1 << k
            kp = min(kp + 4, 80)
            k = kp >> 3
        }
        return run
    }

    private static func updateGRParameters(_ leadingOnes: Int, kr: inout UInt32, krp: inout UInt32) {
        if leadingOnes == 0 {
            krp = krp.saturatingSubtracting(2)
        } else if leadingOnes > 1 {
            krp = min(krp + UInt32(leadingOnes), 80)
        }
        kr = krp >> 3
    }

    private static func rlMagnitude(signBit: UInt32, codeRemainder: UInt32) throws -> Int16 {
        guard codeRemainder < UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let magnitude = Int16(codeRemainder + 1)
        return signBit == 0 ? magnitude : -magnitude
    }

    private static func rlgr1Magnitude(codeRemainder: UInt32, k: inout UInt32, kp: inout UInt32) throws -> Int16 {
        if codeRemainder == 0 {
            kp = min(kp + 3, 80)
            k = kp >> 3
            return 0
        }

        kp = kp.saturatingSubtracting(3)
        k = kp >> 3
        let magnitude = codeRemainder.isMultiple(of: 2)
            ? codeRemainder >> 1
            : (codeRemainder + 1) >> 1
        guard magnitude <= UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let value = Int16(magnitude)
        return codeRemainder.isMultiple(of: 2) ? value : -value
    }

    private static func rlgr3Magnitude(_ value: UInt32) throws -> Int16 {
        let magnitude = value.isMultiple(of: 2) ? value >> 1 : (value + 1) >> 1
        guard magnitude <= UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let decoded = Int16(magnitude)
        return value.isMultiple(of: 2) ? decoded : -decoded
    }

    private static func nIndex(_ value: UInt32) -> Int {
        value == 0 ? 0 : 32 - value.leadingZeroBitCount
    }

    private static func decodeDifferential(_ buffer: inout [Int16], start: Int, count: Int) {
        guard count > 1 else {
            return
        }
        for index in start + 1 ..< start + count {
            buffer[index] = buffer[index] &+ buffer[index - 1]
        }
    }

    private static func decodeQuantization(_ buffer: inout [Int16], quant: Quant) throws {
        try shift(buffer: &buffer, range: 0 ..< 1024, factor: quant.hl1)
        try shift(buffer: &buffer, range: 1024 ..< 2048, factor: quant.lh1)
        try shift(buffer: &buffer, range: 2048 ..< 3072, factor: quant.hh1)
        try shift(buffer: &buffer, range: 3072 ..< 3328, factor: quant.hl2)
        try shift(buffer: &buffer, range: 3328 ..< 3584, factor: quant.lh2)
        try shift(buffer: &buffer, range: 3584 ..< 3840, factor: quant.hh2)
        try shift(buffer: &buffer, range: 3840 ..< 3904, factor: quant.hl3)
        try shift(buffer: &buffer, range: 3904 ..< 3968, factor: quant.lh3)
        try shift(buffer: &buffer, range: 3968 ..< 4032, factor: quant.hh3)
        try shift(buffer: &buffer, range: 4032 ..< 4096, factor: quant.ll3)
    }

    private static func shift(buffer: inout [Int16], range: Range<Int>, factor quant: UInt8) throws {
        guard quant >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let shift = Int(quant - 1)
        guard shift > 0 else {
            return
        }
        for index in range {
            buffer[index] = Int16(truncatingIfNeeded: Int(buffer[index]) << shift)
        }
    }

    private static func decodeDWT(_ buffer: inout [Int16], temp: inout [Int16]) {
        decodeDWTBlock(buffer: &buffer, start: 3840, temp: &temp, subbandWidth: 8)
        decodeDWTBlock(buffer: &buffer, start: 3072, temp: &temp, subbandWidth: 16)
        decodeDWTBlock(buffer: &buffer, start: 0, temp: &temp, subbandWidth: 32)
    }

    private static func decodeDWTBlock(
        buffer: inout [Int16],
        start: Int,
        temp: inout [Int16],
        subbandWidth: Int
    ) {
        inverseHorizontal(buffer: buffer, start: start, temp: &temp, subbandWidth: subbandWidth)
        inverseVertical(buffer: &buffer, start: start, temp: temp, subbandWidth: subbandWidth)
    }

    private static func inverseHorizontal(
        buffer: [Int16],
        start: Int,
        temp: inout [Int16],
        subbandWidth: Int
    ) {
        let totalWidth = subbandWidth * 2
        let squared = subbandWidth * subbandWidth
        let hlBase = start
        let lhBase = start + squared
        let hhBase = start + squared * 2
        let llBase = start + squared * 3
        let hBase = squared * 2

        for row in 0 ..< subbandWidth {
            let subbandRow = row * subbandWidth
            let dstRow = row * totalWidth

            temp[dstRow] = wrapToInt16(
                Int(buffer[llBase + subbandRow]) - ((Int(buffer[hlBase + subbandRow]) * 2 + 1) >> 1)
            )
            temp[hBase + dstRow] = wrapToInt16(
                Int(buffer[lhBase + subbandRow]) - ((Int(buffer[hhBase + subbandRow]) * 2 + 1) >> 1)
            )

            for n in 1 ..< subbandWidth {
                let x = n * 2
                temp[dstRow + x] = wrapToInt16(
                    Int(buffer[llBase + subbandRow + n])
                        - ((Int(buffer[hlBase + subbandRow + n - 1]) + Int(buffer[hlBase + subbandRow + n]) + 1) >> 1)
                )
                temp[hBase + dstRow + x] = wrapToInt16(
                    Int(buffer[lhBase + subbandRow + n])
                        - ((Int(buffer[hhBase + subbandRow + n - 1]) + Int(buffer[hhBase + subbandRow + n]) + 1) >> 1)
                )
            }

            for n in 0 ..< subbandWidth - 1 {
                let x = n * 2
                temp[dstRow + x + 1] = wrapToInt16(
                    (Int(buffer[hlBase + subbandRow + n]) << 1)
                        + ((Int(temp[dstRow + x]) + Int(temp[dstRow + x + 2])) >> 1)
                )
                temp[hBase + dstRow + x + 1] = wrapToInt16(
                    (Int(buffer[hhBase + subbandRow + n]) << 1)
                        + ((Int(temp[hBase + dstRow + x]) + Int(temp[hBase + dstRow + x + 2])) >> 1)
                )
            }

            let n = subbandWidth - 1
            let x = n * 2
            temp[dstRow + x + 1] = wrapToInt16(
                (Int(buffer[hlBase + subbandRow + n]) << 1) + Int(temp[dstRow + x])
            )
            temp[hBase + dstRow + x + 1] = wrapToInt16(
                (Int(buffer[hhBase + subbandRow + n]) << 1) + Int(temp[hBase + dstRow + x])
            )
        }
    }

    private static func inverseVertical(
        buffer: inout [Int16],
        start: Int,
        temp: [Int16],
        subbandWidth: Int
    ) {
        let totalWidth = subbandWidth * 2
        let hBase = subbandWidth * subbandWidth * 2

        for column in 0 ..< totalWidth {
            buffer[start + column] = wrapToInt16(
                Int(temp[column]) - ((Int(temp[hBase + column]) * 2 + 1) >> 1)
            )

            for n in 1 ..< subbandWidth {
                let lIndex = n * totalWidth + column
                let hPreviousIndex = hBase + (n - 1) * totalWidth + column
                let hIndex = hBase + n * totalWidth + column
                let dstBase = start + (n - 1) * 2 * totalWidth + column
                let evenIndex = dstBase + 2 * totalWidth
                let oddIndex = dstBase + totalWidth

                buffer[evenIndex] = wrapToInt16(
                    Int(temp[lIndex]) - ((Int(temp[hPreviousIndex]) + Int(temp[hIndex]) + 1) >> 1)
                )
                buffer[oddIndex] = wrapToInt16(
                    (Int(temp[hPreviousIndex]) << 1)
                        + ((Int(buffer[dstBase]) + Int(buffer[evenIndex])) >> 1)
                )
            }

            let lastDst = start + (subbandWidth - 1) * 2 * totalWidth + column
            let hLast = hBase + (subbandWidth - 1) * totalWidth + column
            buffer[lastDst + totalWidth] = wrapToInt16(
                (Int(temp[hLast]) << 1) + ((Int(buffer[lastDst]) * 2) >> 1)
            )
        }
    }

    private static func bgraData(y: [Int16], cb: [Int16], cr: [Int16]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for index in 0 ..< 64 * 64 {
            let yValue = (Int(y[index]) + 4096) << 16
            let cbValue = Int(cb[index])
            let crValue = Int(cr[index])
            let red = (crValue * 91_916 + yValue) >> 21
            let green = (yValue - cbValue * 22_527 - crValue * 46_819) >> 21
            let blue = (cbValue * 115_992 + yValue) >> 21
            let offset = index * 4
            bytes[offset] = clip(blue)
            bytes[offset + 1] = clip(green)
            bytes[offset + 2] = clip(red)
            bytes[offset + 3] = 0xFF
        }
        return Data(bytes)
    }

    private static func clip(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }

    private static func wrapToInt16(_ value: Int) -> Int16 {
        Int16(truncatingIfNeeded: value)
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isEmpty: Bool {
        bitOffset >= bytes.count * 8
    }

    mutating func consumeLeading(bit: UInt32) -> Int {
        var count = 0
        while let next = peekBit(), next == bit {
            bitOffset += 1
            count += 1
        }
        return count
    }

    mutating func readBits(count: Int) -> UInt32? {
        guard count >= 0,
              bytes.count * 8 - bitOffset >= count
        else {
            return nil
        }
        var value: UInt32 = 0
        for _ in 0 ..< count {
            value = (value << 1) | (readBit() ?? 0)
        }
        return value
    }

    private func peekBit() -> UInt32? {
        guard !isEmpty else {
            return nil
        }
        let byte = bytes[bitOffset / 8]
        let shift = 7 - bitOffset % 8
        return UInt32((byte >> UInt8(shift)) & 0x01)
    }

    private mutating func readBit() -> UInt32? {
        guard let bit = peekBit() else {
            return nil
        }
        bitOffset += 1
        return bit
    }
}

private extension UInt32 {
    func saturatingSubtracting(_ value: UInt32) -> UInt32 {
        self > value ? self - value : 0
    }
}
