import Foundation

private struct RDPZGFXToken {
    var prefixLength: Int
    var prefixCode: UInt32
    var valueBits: Int
    var isMatch: Bool
    var valueBase: UInt32
}

private struct RDPZGFXBitReader {
    private let bytes: [UInt8]
    private let bitCount: Int
    private var bitOffset: Int = 0

    init(_ encodedData: Data) throws {
        guard let unusedFinalBits = encodedData.last, unusedFinalBits <= 7 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let payloadByteCount = encodedData.count - 1
        let availableBits = payloadByteCount * 8 - Int(unusedFinalBits)
        guard availableBits >= 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        bytes = Array(encodedData.prefix(payloadByteCount))
        bitCount = availableBits
    }

    var isEmpty: Bool {
        bitOffset >= bitCount
    }

    var byteBitOffset: Int {
        bitOffset % 8
    }

    func peekBits(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32, bitOffset + count <= bitCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var value: UInt32 = 0
        for index in 0 ..< count {
            value <<= 1
            value |= UInt32(bit(at: bitOffset + index))
        }
        return value
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
        let value = try peekBits(count)
        bitOffset += count
        return value
    }

    mutating func skipBits(_ count: Int) throws {
        _ = try readBits(count)
    }

    func leadingOneCount() -> Int {
        var count = 0
        while bitOffset + count < bitCount, bit(at: bitOffset + count) == 1 {
            count += 1
        }
        return count
    }

    private func bit(at offset: Int) -> UInt8 {
        let byte = bytes[offset / 8]
        let bitInByte = 7 - (offset % 8)
        return (byte >> UInt8(bitInByte)) & 1
    }
}

private final class RDPZGFXHistory {
    private var bytes: [UInt8]
    private var position: Int = 0

    init(size: Int = 2_500_000) {
        bytes = Array(repeating: 0, count: size)
    }

    func write(_ newBytes: [UInt8]) {
        for byte in newBytes {
            bytes[position] = byte
            position += 1
            if position == bytes.count {
                position = 0
            }
        }
    }

    func read(offset: Int, count: Int) throws -> [UInt8] {
        guard offset > 0, offset <= bytes.count, count >= 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var pattern: [UInt8] = []
        pattern.reserveCapacity(min(offset, count))
        var readPosition = (bytes.count + position - offset) % bytes.count
        for _ in 0 ..< min(offset, count) {
            pattern.append(bytes[readPosition])
            readPosition += 1
            if readPosition == bytes.count {
                readPosition = 0
            }
        }

        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            result.append(contentsOf: pattern.prefix(remaining))
        }
        return result
    }
}

final class RDPZGFXDecompressor {
    private let history = RDPZGFXHistory()

    func decompress(_ data: Data) throws -> Data {
        var cursor = ByteCursor(data)
        let descriptor = try cursor.readUInt8()
        switch descriptor {
        case 0xE0:
            return try decodeSegment(cursor.readRemainingData())
        case 0xE1:
            return try decodeMultipartSegments(&cursor)
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private func decodeMultipartSegments(_ cursor: inout ByteCursor) throws -> Data {
        let segmentCount = try Int(cursor.readLittleEndianUInt16())
        let uncompressedSize = try Int(cursor.readLittleEndianUInt32())
        var decoded = Data()

        for _ in 0 ..< segmentCount {
            let segmentSize = try Int(cursor.readLittleEndianUInt32())
            guard segmentSize > 0, segmentSize <= cursor.remaining else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            try decoded.append(decodeSegment(cursor.readData(count: segmentSize)))
        }

        guard decoded.count == uncompressedSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return decoded
    }

    private func decodeSegment(_ segment: Data) throws -> Data {
        guard !segment.isEmpty else {
            return Data()
        }

        var cursor = ByteCursor(segment)
        let typeAndFlags = try cursor.readUInt8()
        let compressionType = typeAndFlags & 0x0F
        let compressionFlags = typeAndFlags >> 4
        guard compressionType == 0x04 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let encodedData = cursor.readRemainingData()
        guard compressionFlags & 0x02 != 0 else {
            history.write(Array(encodedData))
            return encodedData
        }

        return try decompressSegment(encodedData)
    }

    private func decompressSegment(_ encodedData: Data) throws -> Data {
        guard !encodedData.isEmpty else {
            return Data()
        }

        var reader = try RDPZGFXBitReader(encodedData)
        var output: [UInt8] = []

        while !reader.isEmpty {
            let token = try readToken(from: &reader)
            if token.isMatch {
                try readMatch(token, from: &reader, into: &output)
            } else if token.valueBits == 8 {
                let literal = try UInt8(reader.readBits(8))
                output.append(literal)
                history.write([literal])
            } else {
                let literal = UInt8(token.valueBase)
                output.append(literal)
                history.write([literal])
            }
        }

        return Data(output)
    }

    private func readToken(from reader: inout RDPZGFXBitReader) throws -> RDPZGFXToken {
        for token in Self.tokenTable {
            guard try reader.peekBits(token.prefixLength) == token.prefixCode else {
                continue
            }
            try reader.skipBits(token.prefixLength)
            return token
        }
        throw RDPDecodeError.invalidRDPGFXPDU
    }

    private func readMatch(
        _ token: RDPZGFXToken,
        from reader: inout RDPZGFXBitReader,
        into output: inout [UInt8]
    ) throws {
        let distance = try Int(token.valueBase + reader.readBits(token.valueBits))
        if distance == 0 {
            try readUnencodedBytes(from: &reader, into: &output)
            return
        }

        let lengthTokenSize = reader.leadingOneCount()
        try reader.skipBits(lengthTokenSize + 1)

        let length: Int
        if lengthTokenSize == 0 {
            length = 3
        } else {
            guard lengthTokenSize < 30 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let value = try Int(reader.readBits(lengthTokenSize + 1))
            length = (1 << (lengthTokenSize + 1)) + value
        }

        let bytes = try history.read(offset: distance, count: length)
        output.append(contentsOf: bytes)
        history.write(bytes)
    }

    private func readUnencodedBytes(
        from reader: inout RDPZGFXBitReader,
        into output: inout [UInt8]
    ) throws {
        let length = try Int(reader.readBits(15))
        if reader.byteBitOffset > 0 {
            try reader.skipBits(8 - reader.byteBitOffset)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for _ in 0 ..< length {
            try bytes.append(UInt8(reader.readBits(8)))
        }
        output.append(contentsOf: bytes)
        history.write(bytes)
    }

    private static let tokenTable: [RDPZGFXToken] = [
        RDPZGFXToken(prefixLength: 1, prefixCode: 0, valueBits: 8, isMatch: false, valueBase: 0),
        RDPZGFXToken(prefixLength: 5, prefixCode: 17, valueBits: 5, isMatch: true, valueBase: 0),
        RDPZGFXToken(prefixLength: 5, prefixCode: 18, valueBits: 7, isMatch: true, valueBase: 32),
        RDPZGFXToken(prefixLength: 5, prefixCode: 19, valueBits: 9, isMatch: true, valueBase: 160),
        RDPZGFXToken(prefixLength: 5, prefixCode: 20, valueBits: 10, isMatch: true, valueBase: 672),
        RDPZGFXToken(prefixLength: 5, prefixCode: 21, valueBits: 12, isMatch: true, valueBase: 1_696),
        RDPZGFXToken(prefixLength: 5, prefixCode: 24, valueBits: 0, isMatch: false, valueBase: 0x00),
        RDPZGFXToken(prefixLength: 5, prefixCode: 25, valueBits: 0, isMatch: false, valueBase: 0x01),
        RDPZGFXToken(prefixLength: 6, prefixCode: 44, valueBits: 14, isMatch: true, valueBase: 5_792),
        RDPZGFXToken(prefixLength: 6, prefixCode: 45, valueBits: 15, isMatch: true, valueBase: 22_176),
        RDPZGFXToken(prefixLength: 6, prefixCode: 52, valueBits: 0, isMatch: false, valueBase: 0x02),
        RDPZGFXToken(prefixLength: 6, prefixCode: 53, valueBits: 0, isMatch: false, valueBase: 0x03),
        RDPZGFXToken(prefixLength: 6, prefixCode: 54, valueBits: 0, isMatch: false, valueBase: 0xFF),
        RDPZGFXToken(prefixLength: 7, prefixCode: 92, valueBits: 18, isMatch: true, valueBase: 54_944),
        RDPZGFXToken(prefixLength: 7, prefixCode: 93, valueBits: 20, isMatch: true, valueBase: 317_088),
        RDPZGFXToken(prefixLength: 7, prefixCode: 110, valueBits: 0, isMatch: false, valueBase: 0x04),
        RDPZGFXToken(prefixLength: 7, prefixCode: 111, valueBits: 0, isMatch: false, valueBase: 0x05),
        RDPZGFXToken(prefixLength: 7, prefixCode: 112, valueBits: 0, isMatch: false, valueBase: 0x06),
        RDPZGFXToken(prefixLength: 7, prefixCode: 113, valueBits: 0, isMatch: false, valueBase: 0x07),
        RDPZGFXToken(prefixLength: 7, prefixCode: 114, valueBits: 0, isMatch: false, valueBase: 0x08),
        RDPZGFXToken(prefixLength: 7, prefixCode: 115, valueBits: 0, isMatch: false, valueBase: 0x09),
        RDPZGFXToken(prefixLength: 7, prefixCode: 116, valueBits: 0, isMatch: false, valueBase: 0x0A),
        RDPZGFXToken(prefixLength: 7, prefixCode: 117, valueBits: 0, isMatch: false, valueBase: 0x0B),
        RDPZGFXToken(prefixLength: 7, prefixCode: 118, valueBits: 0, isMatch: false, valueBase: 0x3A),
        RDPZGFXToken(prefixLength: 7, prefixCode: 119, valueBits: 0, isMatch: false, valueBase: 0x3B),
        RDPZGFXToken(prefixLength: 7, prefixCode: 120, valueBits: 0, isMatch: false, valueBase: 0x3C),
        RDPZGFXToken(prefixLength: 7, prefixCode: 121, valueBits: 0, isMatch: false, valueBase: 0x3D),
        RDPZGFXToken(prefixLength: 7, prefixCode: 122, valueBits: 0, isMatch: false, valueBase: 0x3E),
        RDPZGFXToken(prefixLength: 7, prefixCode: 123, valueBits: 0, isMatch: false, valueBase: 0x3F),
        RDPZGFXToken(prefixLength: 7, prefixCode: 124, valueBits: 0, isMatch: false, valueBase: 0x40),
        RDPZGFXToken(prefixLength: 7, prefixCode: 125, valueBits: 0, isMatch: false, valueBase: 0x80),
        RDPZGFXToken(prefixLength: 8, prefixCode: 188, valueBits: 20, isMatch: true, valueBase: 1_365_664),
        RDPZGFXToken(prefixLength: 8, prefixCode: 189, valueBits: 21, isMatch: true, valueBase: 2_414_240),
        RDPZGFXToken(prefixLength: 8, prefixCode: 252, valueBits: 0, isMatch: false, valueBase: 0x0C),
        RDPZGFXToken(prefixLength: 8, prefixCode: 253, valueBits: 0, isMatch: false, valueBase: 0x38),
        RDPZGFXToken(prefixLength: 8, prefixCode: 254, valueBits: 0, isMatch: false, valueBase: 0x39),
        RDPZGFXToken(prefixLength: 8, prefixCode: 255, valueBits: 0, isMatch: false, valueBase: 0x66),
        RDPZGFXToken(prefixLength: 9, prefixCode: 380, valueBits: 22, isMatch: true, valueBase: 4_511_392),
        RDPZGFXToken(prefixLength: 9, prefixCode: 381, valueBits: 23, isMatch: true, valueBase: 8_705_696),
        RDPZGFXToken(prefixLength: 9, prefixCode: 382, valueBits: 24, isMatch: true, valueBase: 17_094_304),
    ]
}
