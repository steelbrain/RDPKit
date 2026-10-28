import Foundation

struct RDPGFXAVC420BitmapStream: Equatable, Sendable {
    var regionRects: [RDPGFXRect16]
    var encodedBitstream: Data

    static func parse(from data: Data) throws -> RDPGFXAVC420BitmapStream {
        var cursor = ByteCursor(data)
        let regionCount = try cursor.readLittleEndianUInt32()
        // Each region has an RDPGFX_RECT16 and an RDPGFX_AVC420_QUANT_QUALITY.
        guard regionCount <= UInt32(cursor.remaining / 10) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var regionRects: [RDPGFXRect16] = []
        regionRects.reserveCapacity(Int(regionCount))
        for _ in 0 ..< regionCount {
            try regionRects.append(RDPGFXRect16.parse(&cursor))
        }
        // The quantization values are informational (MS-RDPEGFX 2.2.4.4.1); only
        // their ranges are checked (2.2.4.4.2).
        for _ in 0 ..< regionCount {
            let qpVal = try cursor.readUInt8()
            let qualityVal = try cursor.readUInt8()
            guard qpVal & 0x3F <= 51, qualityVal <= 100 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        let encodedBitstream = cursor.readRemainingData()
        guard !encodedBitstream.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXAVC420BitmapStream(regionRects: regionRects, encodedBitstream: encodedBitstream)
    }
}

/// The LC field of avc420EncodedBitstreamInfo (MS-RDPEGFX 2.2.4.5); 0x3 is invalid.
enum RDPGFXAVC444LayoutCode: UInt8, Equatable, Sendable {
    case yuv420AndChroma420 = 0
    case yuv420Only = 1
    case chroma420Only = 2

    var description: String {
        switch self {
        case .yuv420AndChroma420:
            "yuv420+chroma420"
        case .yuv420Only:
            "yuv420"
        case .chroma420Only:
            "chroma420"
        }
    }
}

/// RFX_AVC444_BITMAP_STREAM and RFX_AVC444V2_BITMAP_STREAM, which share a layout
/// (MS-RDPEGFX 2.2.4.5 and 2.2.4.6).
struct RDPGFXAVC444BitmapStream: Equatable, Sendable {
    var layoutCode: RDPGFXAVC444LayoutCode
    var firstStream: RDPGFXAVC420BitmapStream
    var secondStream: RDPGFXAVC420BitmapStream?

    var yuv420Stream: RDPGFXAVC420BitmapStream? {
        layoutCode == .chroma420Only ? nil : firstStream
    }

    var chroma420Stream: RDPGFXAVC420BitmapStream? {
        switch layoutCode {
        case .yuv420AndChroma420:
            secondStream
        case .chroma420Only:
            firstStream
        case .yuv420Only:
            nil
        }
    }

    static func parse(from data: Data) throws -> RDPGFXAVC444BitmapStream {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bitstreamInfo = try cursor.readLittleEndianUInt32()
        let firstStreamByteCount = Int(bitstreamInfo & 0x3FFF_FFFF)
        guard let layoutCode = RDPGFXAVC444LayoutCode(rawValue: UInt8(bitstreamInfo >> 30)) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let streamData = cursor.readRemainingData()
        switch layoutCode {
        case .yuv420AndChroma420:
            guard firstStreamByteCount > 0, firstStreamByteCount <= streamData.count else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData.prefix(firstStreamByteCount)),
                secondStream: RDPGFXAVC420BitmapStream.parse(from: streamData.dropFirst(firstStreamByteCount))
            )
        case .yuv420Only, .chroma420Only:
            // cbAvc420EncodedBitstream1 is zero when no YUV420 frame is present.
            let expectedByteCount = layoutCode == .yuv420Only ? streamData.count : 0
            guard firstStreamByteCount == expectedByteCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData),
                secondStream: nil
            )
        }
    }
}

/// ALPHACODEC_BITMAP_STREAM (MS-RDPEGFX 2.2.4.3).
struct RDPGFXAlphaBitmapStream: Equatable, Sendable {
    private static let alphaSignature: UInt16 = 0x414C

    var alphaValues: Data

    static func parse(from data: Data, pixelCount: Int) throws -> RDPGFXAlphaBitmapStream {
        var cursor = ByteCursor(data)
        guard pixelCount >= 0,
              cursor.remaining >= 4,
              try cursor.readLittleEndianUInt16() == alphaSignature
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        guard try cursor.readLittleEndianUInt16() != 0 else {
            let alphaValues = cursor.readRemainingData()
            guard alphaValues.count == pixelCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return RDPGFXAlphaBitmapStream(alphaValues: alphaValues)
        }

        var alphaValues = Data()
        while cursor.remaining > 0 {
            let runValue = try cursor.readUInt8()
            let runLength = try readRunLength(&cursor)
            guard runLength <= pixelCount - alphaValues.count else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            alphaValues.append(contentsOf: repeatElement(runValue, count: runLength))
        }
        guard alphaValues.count == pixelCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXAlphaBitmapStream(alphaValues: alphaValues)
    }

    /// CLEARCODEC_ALPHA_RLE_SEGMENT run length (MS-RDPEGFX 2.2.4.3.1).
    private static func readRunLength(_ cursor: inout ByteCursor) throws -> Int {
        let firstFactor = try cursor.readUInt8()
        guard firstFactor == 0xFF else {
            return Int(firstFactor)
        }
        let secondFactor = try cursor.readLittleEndianUInt16()
        guard secondFactor == 0xFFFF else {
            return Int(secondFactor)
        }
        return try Int(cursor.readLittleEndianUInt32())
    }
}
