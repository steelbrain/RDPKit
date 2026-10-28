import Foundation

struct RDPClearCodecBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var bgraData: Data
}

struct RDPClearCodecStreamSummary: Equatable, Sendable {
    var flags: UInt8
    var sequenceNumber: UInt8
    var glyphIndex: UInt16?
    var residualByteCount: UInt32?
    var bandsByteCount: UInt32?
    var subcodecByteCount: UInt32?
}

/// Decoder for the ClearCodec bitmap stream defined by MS-RDPEGFX 2.2.4.1.
final class RDPClearCodecDecoder {
    private enum Flag {
        static let glyphIndex: UInt8 = 0x01
        static let glyphHit: UInt8 = 0x02
        static let cacheReset: UInt8 = 0x04
        static let validMask: UInt8 = glyphIndex | glyphHit | cacheReset
    }

    private struct Header {
        var flags: UInt8
        var sequenceNumber: UInt8
        var glyphIndex: UInt16?
    }

    private static let maximumGlyphIndex: UInt16 = 3_999
    /// MS-RDPEGFX 2.2.4.1 and 3.3.1.9: glyph storage slots hold bitmaps of at most 1,024 square
    /// pixels. Larger glyphs are decoded but not stored, which bounds the storage at 16 MB.
    private static let maximumGlyphPixelCount = 1_024
    private static let maximumBandHeight = 52
    private static let vBarStorageSize = 32_768
    private static let shortVBarStorageSize = 16_384

    private var glyphCache: [UInt16: RDPClearCodecBitmap] = [:]
    private var vBarStorage: [Int: Data] = [:]
    private var shortVBarStorage: [Int: Data] = [:]
    private var vBarStorageCursor = 0
    private var shortVBarStorageCursor = 0
    private var expectedSequenceNumber: UInt8 = 0

    /// Decodes `data` for a `width` x `height` destination whose current BGRA pixels are
    /// `destination` (zero-filled when nil). Every ClearCodec layer is optional, so pixels that no
    /// layer covers keep their destination value.
    func decode(
        _ data: Data,
        width: Int,
        height: Int,
        destination: Data? = nil
    ) throws -> RDPClearCodecBitmap {
        guard width > 0,
              height > 0,
              width <= Int(UInt16.max),
              height <= Int(UInt16.max),
              destination.map({ $0.count == width * height * 4 }) ?? true
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        let header = try Self.readHeader(&cursor)
        guard header.sequenceNumber == expectedSequenceNumber else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        if header.flags & Flag.cacheReset != 0 {
            vBarStorageCursor = 0
            shortVBarStorageCursor = 0
        }

        let bitmap: RDPClearCodecBitmap
        if header.flags & Flag.glyphHit != 0 {
            guard let glyphIndex = header.glyphIndex,
                  let cached = glyphCache[glyphIndex],
                  cursor.remaining == 0
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            bitmap = cached
        } else {
            var decoded = RDPClearCodecBitmap(
                width: width,
                height: height,
                bytesPerRow: width * 4,
                bgraData: destination ?? Data(count: width * height * 4)
            )
            try decodeCompositePayload(&cursor, into: &decoded)
            if let glyphIndex = header.glyphIndex {
                glyphCache[glyphIndex] = width * height <= Self.maximumGlyphPixelCount ? decoded : nil
            }
            bitmap = decoded
        }
        expectedSequenceNumber &+= 1
        return bitmap
    }

    static func summarize(_ data: Data) throws -> RDPClearCodecStreamSummary {
        var cursor = ByteCursor(data)
        let header = try readHeader(&cursor)
        var summary = RDPClearCodecStreamSummary(
            flags: header.flags,
            sequenceNumber: header.sequenceNumber,
            glyphIndex: header.glyphIndex
        )
        if header.flags & Flag.glyphHit != 0 {
            guard cursor.remaining == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return summary
        }
        guard cursor.remaining >= 12 else {
            return summary
        }

        let residualByteCount = try cursor.readLittleEndianUInt32()
        let bandsByteCount = try cursor.readLittleEndianUInt32()
        let subcodecByteCount = try cursor.readLittleEndianUInt32()
        guard UInt64(residualByteCount) + UInt64(bandsByteCount) + UInt64(subcodecByteCount) == UInt64(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        summary.residualByteCount = residualByteCount
        summary.bandsByteCount = bandsByteCount
        summary.subcodecByteCount = subcodecByteCount
        return summary
    }

    private static func readHeader(_ cursor: inout ByteCursor) throws -> Header {
        let flags = try cursor.readUInt8()
        let sequenceNumber = try cursor.readUInt8()
        let glyphIndex = flags & Flag.glyphIndex != 0 ? try cursor.readLittleEndianUInt16() : nil
        guard flags & ~Flag.validMask == 0,
              flags & Flag.glyphHit == 0 || glyphIndex != nil,
              glyphIndex.map({ $0 <= maximumGlyphIndex }) ?? true
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return Header(flags: flags, sequenceNumber: sequenceNumber, glyphIndex: glyphIndex)
    }

    private func decodeCompositePayload(_ cursor: inout ByteCursor, into bitmap: inout RDPClearCodecBitmap) throws {
        guard cursor.remaining > 0 else {
            return
        }

        let residualByteCount = try Int(cursor.readLittleEndianUInt32())
        let bandsByteCount = try Int(cursor.readLittleEndianUInt32())
        let subcodecByteCount = try Int(cursor.readLittleEndianUInt32())
        let residualData = try cursor.readData(count: residualByteCount)
        let bandsData = try cursor.readData(count: bandsByteCount)
        let subcodecData = try cursor.readData(count: subcodecByteCount)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        try decodeResidualLayer(residualData, into: &bitmap)
        try decodeBandsLayer(bandsData, into: &bitmap)
        try decodeSubcodecLayer(subcodecData, into: &bitmap)
    }

    private func decodeResidualLayer(_ data: Data, into bitmap: inout RDPClearCodecBitmap) throws {
        var cursor = ByteCursor(data)
        let pixelCount = bitmap.width * bitmap.height
        var pixelIndex = 0
        while cursor.remaining > 0 {
            guard cursor.remaining >= 4 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let blue = try cursor.readUInt8()
            let green = try cursor.readUInt8()
            let red = try cursor.readUInt8()
            let runLength = try Self.readRunLength(&cursor, requiresNonzero: true)
            guard runLength <= pixelCount - pixelIndex else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            for index in pixelIndex ..< pixelIndex + runLength {
                bitmap.setPixel(x: index % bitmap.width, y: index / bitmap.width, blue: blue, green: green, red: red)
            }
            pixelIndex += runLength
        }
    }

    private func decodeBandsLayer(_ data: Data, into bitmap: inout RDPClearCodecBitmap) throws {
        var cursor = ByteCursor(data)
        while cursor.remaining > 0 {
            guard cursor.remaining >= 11 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let xStart = try Int(cursor.readLittleEndianUInt16())
            let xEnd = try Int(cursor.readLittleEndianUInt16())
            let yStart = try Int(cursor.readLittleEndianUInt16())
            let yEnd = try Int(cursor.readLittleEndianUInt16())
            let background = try Data([cursor.readUInt8(), cursor.readUInt8(), cursor.readUInt8(), 0xFF])
            let height = yEnd - yStart + 1
            guard xStart <= xEnd,
                  yStart <= yEnd,
                  xEnd < bitmap.width,
                  yEnd < bitmap.height,
                  height <= Self.maximumBandHeight
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            for x in xStart ... xEnd {
                let vBar = try decodeVBar(&cursor, background: background, height: height)
                for row in 0 ..< height {
                    let destinationOffset = (yStart + row) * bitmap.bytesPerRow + x * 4
                    bitmap.bgraData[destinationOffset ..< destinationOffset + 4] = vBar[row * 4 ..< row * 4 + 4]
                }
            }
        }
    }

    /// Decodes one CLEARCODEC_VBAR (MS-RDPEGFX 2.2.4.1.1.2.1.1) into a `height`-pixel BGRA column.
    private func decodeVBar(_ cursor: inout ByteCursor, background: Data, height: Int) throws -> Data {
        let header = try cursor.readLittleEndianUInt16()

        if header & 0x8000 != 0 {
            guard let vBar = vBarStorage[Int(header & 0x7FFF)],
                  vBar.count == height * 4
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return vBar
        }

        let shortVBar: Data
        let yOn: Int
        if header & 0x4000 != 0 {
            guard let cached = shortVBarStorage[Int(header & 0x3FFF)] else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            shortVBar = cached
            yOn = try Int(cursor.readUInt8())
        } else {
            yOn = Int(header & 0x00FF)
            let yOff = Int((header >> 8) & 0x003F)
            guard yOn <= yOff, yOff <= height else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            var pixels = Data(capacity: (yOff - yOn) * 4)
            for _ in yOn ..< yOff {
                try pixels.append(contentsOf: [cursor.readUInt8(), cursor.readUInt8(), cursor.readUInt8(), 0xFF])
            }
            shortVBar = pixels
            shortVBarStorage[shortVBarStorageCursor] = shortVBar
            shortVBarStorageCursor = (shortVBarStorageCursor + 1) % Self.shortVBarStorageSize
        }

        let yOff = yOn + shortVBar.count / 4
        guard yOff <= height else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var vBar = Data(capacity: height * 4)
        for _ in 0 ..< yOn {
            vBar.append(background)
        }
        vBar.append(shortVBar)
        for _ in yOff ..< height {
            vBar.append(background)
        }
        vBarStorage[vBarStorageCursor] = vBar
        vBarStorageCursor = (vBarStorageCursor + 1) % Self.vBarStorageSize
        return vBar
    }

    private func decodeSubcodecLayer(_ data: Data, into bitmap: inout RDPClearCodecBitmap) throws {
        var cursor = ByteCursor(data)
        while cursor.remaining > 0 {
            guard cursor.remaining >= 13 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let x = try Int(cursor.readLittleEndianUInt16())
            let y = try Int(cursor.readLittleEndianUInt16())
            let width = try Int(cursor.readLittleEndianUInt16())
            let height = try Int(cursor.readLittleEndianUInt16())
            let byteCount = try Int(cursor.readLittleEndianUInt32())
            let codecID = try cursor.readUInt8()
            let bitmapData = try cursor.readData(count: byteCount)

            guard width > 0,
                  height > 0,
                  x + width <= bitmap.width,
                  y + height <= bitmap.height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            switch codecID {
            case 0x00:
                try decodeUncompressedSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            case 0x01:
                try decodeNSCodecSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            case 0x02:
                try decodeRLEXSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
    }

    private func decodeUncompressedSubcodec(
        _ data: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        into bitmap: inout RDPClearCodecBitmap
    ) throws {
        guard data.count == width * height * 3 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let blue = try cursor.readUInt8()
                let green = try cursor.readUInt8()
                let red = try cursor.readUInt8()
                bitmap.setPixel(x: x + column, y: y + row, blue: blue, green: green, red: red)
            }
        }
    }

    private func decodeNSCodecSubcodec(
        _ data: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        into bitmap: inout RDPClearCodecBitmap
    ) throws {
        let decoded: Data
        do {
            decoded = try RDPNSCodecDecoder.decode(data, width: width, height: height)
        } catch {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        for row in 0 ..< height {
            for column in 0 ..< width {
                let offset = (row * width + column) * 4
                bitmap.setPixel(
                    x: x + column,
                    y: y + row,
                    blue: decoded[offset],
                    green: decoded[offset + 1],
                    red: decoded[offset + 2]
                )
            }
        }
    }

    /// Decodes CLEARCODEC_SUBCODEC_RLEX (MS-RDPEGFX 2.2.4.1.1.3.1.1): each segment is a run of
    /// `palette[stopIndex - suiteDepth]` followed by the suite `palette[stopIndex - suiteDepth ... stopIndex]`.
    private func decodeRLEXSubcodec(
        _ data: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        into bitmap: inout RDPClearCodecBitmap
    ) throws {
        var cursor = ByteCursor(data)
        let paletteCount = try Int(cursor.readUInt8())
        guard (1 ... 127).contains(paletteCount), cursor.remaining >= paletteCount * 3 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var palette: [(blue: UInt8, green: UInt8, red: UInt8)] = []
        palette.reserveCapacity(paletteCount)
        for _ in 0 ..< paletteCount {
            try palette.append((blue: cursor.readUInt8(), green: cursor.readUInt8(), red: cursor.readUInt8()))
        }

        let stopIndexBitCount = Int.bitWidth - (paletteCount - 1).leadingZeroBitCount
        let pixelCount = width * height
        var pixelIndex = 0
        func writePixel(paletteIndex: Int) {
            let color = palette[paletteIndex]
            bitmap.setPixel(
                x: x + pixelIndex % width,
                y: y + pixelIndex / width,
                blue: color.blue,
                green: color.green,
                red: color.red
            )
            pixelIndex += 1
        }

        while cursor.remaining > 0 {
            guard cursor.remaining >= 2 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let packed = try Int(cursor.readUInt8())
            let stopIndex = packed & ((1 << stopIndexBitCount) - 1)
            let suiteDepth = packed >> stopIndexBitCount
            guard suiteDepth <= stopIndex, stopIndex < paletteCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let runLength = try Self.readRunLength(&cursor, requiresNonzero: false)
            guard runLength + suiteDepth + 1 <= pixelCount - pixelIndex else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let startIndex = stopIndex - suiteDepth
            for _ in 0 ..< runLength {
                writePixel(paletteIndex: startIndex)
            }
            for paletteIndex in startIndex ... stopIndex {
                writePixel(paletteIndex: paletteIndex)
            }
        }

        guard pixelIndex == pixelCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    /// Reads a run length stored as a 1-byte factor that escalates to a 2-byte and then a 4-byte
    /// factor when saturated (MS-RDPEGFX 2.2.4.1.1.1.1 and 2.2.4.1.1.3.1.1.1).
    private static func readRunLength(_ cursor: inout ByteCursor, requiresNonzero: Bool) throws -> Int {
        var runLength = try Int(cursor.readUInt8())
        if runLength == 0xFF {
            runLength = try Int(cursor.readLittleEndianUInt16())
            if runLength == 0xFFFF {
                runLength = try Int(cursor.readLittleEndianUInt32())
            }
        }
        guard !requiresNonzero || runLength > 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return runLength
    }
}

private extension RDPClearCodecBitmap {
    mutating func setPixel(x: Int, y: Int, blue: UInt8, green: UInt8, red: UInt8) {
        let offset = y * bytesPerRow + x * 4
        bgraData[offset] = blue
        bgraData[offset + 1] = green
        bgraData[offset + 2] = red
        bgraData[offset + 3] = 0xFF
    }
}
