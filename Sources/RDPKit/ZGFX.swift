import Foundation

/// RDP 8.0 bulk decompressor (MS-RDPEGFX 2.2.5 and 3.1.9.1). The RDP 8.0 Lite
/// profile is the dynamic virtual channel variant (MS-RDPEDYC 2.2.3.3): single
/// segments only, compression type 0x06, and an 8,192-byte history and segment limit.
final class RDPZGFXDecompressor {
    private enum SegmentDescriptor {
        static let single: UInt8 = 0xE0
        static let multipart: UInt8 = 0xE1
    }

    private enum BulkHeader {
        static let compressionTypeMask: UInt8 = 0x0F
        static let packetCompressed: UInt8 = 0x20
        static let rdp8CompressionType: UInt8 = 0x04
        static let rdp8LiteCompressionType: UInt8 = 0x06
    }

    private let compressionType: UInt8
    private let maximumSegmentByteCount: Int
    private var history: [UInt8]
    private var historyPosition = 0

    convenience init() {
        self.init(
            compressionType: BulkHeader.rdp8CompressionType,
            historyByteCount: 2_500_000,
            maximumSegmentByteCount: 65_535
        )
    }

    static func rdp8Lite() -> RDPZGFXDecompressor {
        RDPZGFXDecompressor(
            compressionType: BulkHeader.rdp8LiteCompressionType,
            historyByteCount: 8_192,
            maximumSegmentByteCount: 8_192
        )
    }

    private init(compressionType: UInt8, historyByteCount: Int, maximumSegmentByteCount: Int) {
        self.compressionType = compressionType
        self.maximumSegmentByteCount = maximumSegmentByteCount
        history = Array(repeating: 0, count: historyByteCount)
    }

    func decompress(_ data: Data) throws -> Data {
        var cursor = ByteCursor(data)
        switch try cursor.readUInt8() {
        case SegmentDescriptor.single:
            return try Data(decodeSegment(cursor.readRemainingData()))
        case SegmentDescriptor.multipart where compressionType == BulkHeader.rdp8CompressionType:
            return try decodeMultipartSegments(&cursor)
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private func decodeMultipartSegments(_ cursor: inout ByteCursor) throws -> Data {
        guard cursor.remaining >= 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let segmentCount = try Int(cursor.readLittleEndianUInt16())
        let uncompressedSize = try Int(cursor.readLittleEndianUInt32())
        // Each RDP_DATA_SEGMENT needs a size field and a bulk header byte.
        guard segmentCount <= cursor.remaining / 5 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var decoded = Data()
        for _ in 0 ..< segmentCount {
            let segmentSize = try Int(cursor.readLittleEndianUInt32())
            guard segmentSize > 0, segmentSize <= cursor.remaining else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let segment = try decodeSegment(cursor.readData(count: segmentSize))
            // uncompressedSize MUST equal the sum of the segments (MS-RDPEGFX 3.1.9.1.2.1);
            // stopping as soon as it is exceeded bounds memory for hostile input.
            guard segment.count <= uncompressedSize - decoded.count else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            decoded.append(contentsOf: segment)
        }

        guard decoded.count == uncompressedSize, cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return decoded
    }

    private func decodeSegment(_ segment: Data) throws -> [UInt8] {
        guard let header = segment.first else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // Only PACKET_COMPRESSED is defined; the other flag bits are reserved.
        guard header & BulkHeader.compressionTypeMask == compressionType,
              header & ~BulkHeader.compressionTypeMask & ~BulkHeader.packetCompressed == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let encodedData = [UInt8](segment.dropFirst())
        guard header & BulkHeader.packetCompressed != 0 else {
            guard encodedData.count <= maximumSegmentByteCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            for byte in encodedData {
                appendToHistory(byte)
            }
            return encodedData
        }
        return try decompressSegment(encodedData)
    }

    private func decompressSegment(_ encodedData: [UInt8]) throws -> [UInt8] {
        var reader = try RDPZGFXBitReader(encodedData)
        var output: [UInt8] = []
        output.reserveCapacity(min(maximumSegmentByteCount, encodedData.count * 8))

        while !reader.isEmpty {
            let token = try Self.readToken(from: &reader)
            switch token.kind {
            case .literal:
                try emit(UInt8(token.value), into: &output)
            case .encodedLiteral:
                let literal = try UInt8(reader.readBits(8))
                guard !Self.hasShortLiteralCode(literal) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try emit(literal, into: &output)
            case .match:
                let distance = try Int(token.value + reader.readBits(token.valueBitCount))
                if distance == 0 {
                    try copyUnencodedBytes(from: &reader, into: &output)
                } else {
                    try copyMatch(distance: distance, length: Self.readMatchLength(from: &reader), into: &output)
                }
            }
        }
        return output
    }

    private func emit(_ byte: UInt8, into output: inout [UInt8]) throws {
        guard output.count < maximumSegmentByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        output.append(byte)
        appendToHistory(byte)
    }

    private func copyMatch(distance: Int, length: Int, into output: inout [UInt8]) throws {
        guard distance <= history.count,
              length <= maximumSegmentByteCount - output.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // Copying one byte at a time replicates the pattern when the match overlaps
        // the bytes it produces (distance < length).
        var readPosition = (historyPosition + history.count - distance) % history.count
        for _ in 0 ..< length {
            let byte = history[readPosition]
            readPosition += 1
            if readPosition == history.count {
                readPosition = 0
            }
            output.append(byte)
            appendToHistory(byte)
        }
    }

    private func copyUnencodedBytes(from reader: inout RDPZGFXBitReader, into output: inout [UInt8]) throws {
        let length = try Int(reader.readBits(15))
        guard length <= maximumSegmentByteCount - output.count else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bytes = try reader.readAlignedBytes(count: length)
        output.append(contentsOf: bytes)
        for byte in bytes {
            appendToHistory(byte)
        }
    }

    private func appendToHistory(_ byte: UInt8) {
        history[historyPosition] = byte
        historyPosition += 1
        if historyPosition == history.count {
            historyPosition = 0
        }
    }

    /// Match lengths are a unary prefix of k ones and a zero, then k + 1 value bits
    /// (length 3 when k is zero). The longest defined prefix has 14 ones.
    private static func readMatchLength(from reader: inout RDPZGFXBitReader) throws -> Int {
        var prefixOneCount = 0
        while try reader.readBits(1) == 1 {
            prefixOneCount += 1
            guard prefixOneCount <= 14 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
        guard prefixOneCount > 0 else {
            return 3
        }
        return try (1 << (prefixOneCount + 1)) + Int(reader.readBits(prefixOneCount + 1))
    }

    private static func readToken(from reader: inout RDPZGFXBitReader) throws -> RDPZGFXToken {
        // Every token prefix fits in 8 bits; near the end of the stream the
        // missing low bits read as zero and the prefix length is checked below.
        let availableBitCount = min(8, reader.remainingBitCount)
        let lookupIndex = try Int(reader.peekBits(availableBitCount)) << (8 - availableBitCount)
        guard let token = tokenLookup[lookupIndex],
              token.prefixLength <= availableBitCount
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        try reader.skipBits(token.prefixLength)
        return token
    }

    private static func hasShortLiteralCode(_ value: UInt8) -> Bool {
        switch value {
        case 0x00 ... 0x0C, 0x38 ... 0x40, 0x66, 0x80, 0xFF:
            true
        default:
            false
        }
    }

    /// Token table from MS-RDPEGFX 3.1.9.1.2.4; bit sequences it does not define are reserved.
    private static let tokenTable: [RDPZGFXToken] = [
        RDPZGFXToken(prefixLength: 1, prefixCode: 0b0, kind: .encodedLiteral),
        RDPZGFXToken(prefixLength: 5, prefixCode: 17, kind: .match, valueBitCount: 5, value: 0),
        RDPZGFXToken(prefixLength: 5, prefixCode: 18, kind: .match, valueBitCount: 7, value: 32),
        RDPZGFXToken(prefixLength: 5, prefixCode: 19, kind: .match, valueBitCount: 9, value: 160),
        RDPZGFXToken(prefixLength: 5, prefixCode: 20, kind: .match, valueBitCount: 10, value: 672),
        RDPZGFXToken(prefixLength: 5, prefixCode: 21, kind: .match, valueBitCount: 12, value: 1_696),
        RDPZGFXToken(prefixLength: 5, prefixCode: 24, kind: .literal, value: 0x00),
        RDPZGFXToken(prefixLength: 5, prefixCode: 25, kind: .literal, value: 0x01),
        RDPZGFXToken(prefixLength: 6, prefixCode: 44, kind: .match, valueBitCount: 14, value: 5_792),
        RDPZGFXToken(prefixLength: 6, prefixCode: 45, kind: .match, valueBitCount: 15, value: 22_176),
        RDPZGFXToken(prefixLength: 6, prefixCode: 52, kind: .literal, value: 0x02),
        RDPZGFXToken(prefixLength: 6, prefixCode: 53, kind: .literal, value: 0x03),
        RDPZGFXToken(prefixLength: 6, prefixCode: 54, kind: .literal, value: 0xFF),
        RDPZGFXToken(prefixLength: 7, prefixCode: 92, kind: .match, valueBitCount: 18, value: 54_944),
        RDPZGFXToken(prefixLength: 7, prefixCode: 93, kind: .match, valueBitCount: 20, value: 317_088),
        RDPZGFXToken(prefixLength: 7, prefixCode: 110, kind: .literal, value: 0x04),
        RDPZGFXToken(prefixLength: 7, prefixCode: 111, kind: .literal, value: 0x05),
        RDPZGFXToken(prefixLength: 7, prefixCode: 112, kind: .literal, value: 0x06),
        RDPZGFXToken(prefixLength: 7, prefixCode: 113, kind: .literal, value: 0x07),
        RDPZGFXToken(prefixLength: 7, prefixCode: 114, kind: .literal, value: 0x08),
        RDPZGFXToken(prefixLength: 7, prefixCode: 115, kind: .literal, value: 0x09),
        RDPZGFXToken(prefixLength: 7, prefixCode: 116, kind: .literal, value: 0x0A),
        RDPZGFXToken(prefixLength: 7, prefixCode: 117, kind: .literal, value: 0x0B),
        RDPZGFXToken(prefixLength: 7, prefixCode: 118, kind: .literal, value: 0x3A),
        RDPZGFXToken(prefixLength: 7, prefixCode: 119, kind: .literal, value: 0x3B),
        RDPZGFXToken(prefixLength: 7, prefixCode: 120, kind: .literal, value: 0x3C),
        RDPZGFXToken(prefixLength: 7, prefixCode: 121, kind: .literal, value: 0x3D),
        RDPZGFXToken(prefixLength: 7, prefixCode: 122, kind: .literal, value: 0x3E),
        RDPZGFXToken(prefixLength: 7, prefixCode: 123, kind: .literal, value: 0x3F),
        RDPZGFXToken(prefixLength: 7, prefixCode: 124, kind: .literal, value: 0x40),
        RDPZGFXToken(prefixLength: 7, prefixCode: 125, kind: .literal, value: 0x80),
        RDPZGFXToken(prefixLength: 8, prefixCode: 188, kind: .match, valueBitCount: 20, value: 1_365_664),
        RDPZGFXToken(prefixLength: 8, prefixCode: 189, kind: .match, valueBitCount: 21, value: 2_414_240),
        RDPZGFXToken(prefixLength: 8, prefixCode: 252, kind: .literal, value: 0x0C),
        RDPZGFXToken(prefixLength: 8, prefixCode: 253, kind: .literal, value: 0x38),
        RDPZGFXToken(prefixLength: 8, prefixCode: 254, kind: .literal, value: 0x39),
        RDPZGFXToken(prefixLength: 8, prefixCode: 255, kind: .literal, value: 0x66),
    ]

    /// The token whose prefix starts each 8-bit value, or nil for reserved prefixes.
    private static let tokenLookup: [RDPZGFXToken?] = {
        var lookup = [RDPZGFXToken?](repeating: nil, count: 256)
        for token in tokenTable {
            let shift = 8 - token.prefixLength
            let first = Int(token.prefixCode) << shift
            for index in first ..< first + (1 << shift) {
                lookup[index] = token
            }
        }
        return lookup
    }()
}

private struct RDPZGFXToken {
    enum Kind {
        /// A literal byte fully determined by the prefix.
        case literal
        /// A "0" prefix followed by the 8-bit literal value.
        case encodedLiteral
        /// A match whose distance is `value` plus `valueBitCount` extra bits.
        case match
    }

    var prefixLength: Int
    var prefixCode: UInt32
    var kind: Kind
    var valueBitCount = 0
    /// The literal byte, or the base match distance.
    var value: UInt32 = 0
}

/// Reads the segment bit stream most-significant bit first, excluding the final
/// byte that holds the unused bit count of the byte before it (MS-RDPEGFX 3.1.9.1.2.4).
private struct RDPZGFXBitReader {
    private let bytes: [UInt8]
    private let bitCount: Int
    private var bitOffset = 0

    init(_ encodedData: [UInt8]) throws {
        guard let unusedBitCount = encodedData.last,
              unusedBitCount <= 7,
              (encodedData.count - 1) * 8 >= Int(unusedBitCount)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        bytes = encodedData
        bitCount = (encodedData.count - 1) * 8 - Int(unusedBitCount)
    }

    var isEmpty: Bool {
        bitOffset >= bitCount
    }

    var remainingBitCount: Int {
        bitCount - bitOffset
    }

    func peekBits(_ count: Int) throws -> UInt32 {
        var copy = self
        return try copy.readBits(count)
    }

    mutating func skipBits(_ count: Int) throws {
        guard count <= remainingBitCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        bitOffset += count
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count <= 32, count <= remainingBitCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var value: UInt32 = 0
        var pendingBitCount = count
        while pendingBitCount > 0 {
            let bitInByte = bitOffset & 7
            let takenBitCount = min(8 - bitInByte, pendingBitCount)
            let bits = UInt32(bytes[bitOffset >> 3]) >> UInt32(8 - bitInByte - takenBitCount)
            value = (value << UInt32(takenBitCount)) | (bits & ((1 << UInt32(takenBitCount)) - 1))
            pendingBitCount -= takenBitCount
            bitOffset += takenBitCount
        }
        return value
    }

    /// Skips to the next byte boundary and reads whole bytes, as unencoded runs require.
    mutating func readAlignedBytes(count: Int) throws -> ArraySlice<UInt8> {
        let start = (bitOffset + 7) / 8
        guard (start + count) * 8 <= bitCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        bitOffset = (start + count) * 8
        return bytes[start ..< start + count]
    }
}
