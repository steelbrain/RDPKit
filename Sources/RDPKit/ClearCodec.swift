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
    var subcodecRegions: [RDPClearCodecSubcodecSummary] = []
}

struct RDPClearCodecSubcodecSummary: Equatable, Sendable {
    var rect: RDPFrameRect
    var byteCount: UInt32
    var codecID: UInt8
    var nsCodecYByteCount: UInt32? = nil
    var nsCodecCoByteCount: UInt32? = nil
    var nsCodecCgByteCount: UInt32? = nil
    var nsCodecAlphaByteCount: UInt32? = nil
    var nsCodecColorLossLevel: UInt8? = nil
    var nsCodecChromaSubsamplingLevel: UInt8? = nil
}

final class RDPClearCodecDecoder {
    private struct VBarEntry {
        var bgraData: Data
    }

    private var glyphCache: [UInt16: RDPClearCodecBitmap] = [:]
    private var vBarStorage: [Int: VBarEntry] = [:]
    private var shortVBarStorage: [Int: VBarEntry] = [:]
    private var vBarStorageCursor = 0
    private var shortVBarStorageCursor = 0

    func decode(_ data: Data, width: Int, height: Int) throws -> RDPClearCodecBitmap {
        guard width > 0, height > 0, width <= Int(UInt16.max), height <= Int(UInt16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        let flags = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        let glyphIndex = flags & 0x01 != 0 ? try cursor.readLittleEndianUInt16() : nil

        if flags & 0x04 != 0 {
            vBarStorageCursor = 0
            shortVBarStorageCursor = 0
        }

        if flags & 0x02 != 0 {
            guard let glyphIndex,
                  let cached = glyphCache[glyphIndex]
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return cached
        }

        var bitmap = RDPClearCodecBitmap(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            bgraData: Data(repeating: 0, count: width * height * 4)
        )

        guard cursor.remaining > 0 else {
            if let glyphIndex {
                glyphCache[glyphIndex] = bitmap
            }
            return bitmap
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

        if let glyphIndex {
            glyphCache[glyphIndex] = bitmap
        }
        return bitmap
    }

    static func summarize(_ data: Data) throws -> RDPClearCodecStreamSummary {
        var cursor = ByteCursor(data)
        let flags = try cursor.readUInt8()
        let sequenceNumber = try cursor.readUInt8()
        let glyphIndex = flags & 0x01 != 0 ? try cursor.readLittleEndianUInt16() : nil

        if flags & 0x02 != 0 {
            guard flags & 0x01 != 0,
                  cursor.remaining == 0
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return RDPClearCodecStreamSummary(
                flags: flags,
                sequenceNumber: sequenceNumber,
                glyphIndex: glyphIndex
            )
        }

        guard cursor.remaining >= 12 else {
            return RDPClearCodecStreamSummary(
                flags: flags,
                sequenceNumber: sequenceNumber,
                glyphIndex: glyphIndex
            )
        }

        let residualByteCount = try cursor.readLittleEndianUInt32()
        let bandsByteCount = try cursor.readLittleEndianUInt32()
        let subcodecByteCount = try cursor.readLittleEndianUInt32()
        guard UInt64(residualByteCount) + UInt64(bandsByteCount) + UInt64(subcodecByteCount) == UInt64(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readData(count: Int(residualByteCount))
        _ = try cursor.readData(count: Int(bandsByteCount))
        let subcodecData = try cursor.readData(count: Int(subcodecByteCount))

        return RDPClearCodecStreamSummary(
            flags: flags,
            sequenceNumber: sequenceNumber,
            glyphIndex: glyphIndex,
            residualByteCount: residualByteCount,
            bandsByteCount: bandsByteCount,
            subcodecByteCount: subcodecByteCount,
            subcodecRegions: try summarizeSubcodecs(subcodecData)
        )
    }

    private static func summarizeSubcodecs(_ data: Data) throws -> [RDPClearCodecSubcodecSummary] {
        var cursor = ByteCursor(data)
        var summaries: [RDPClearCodecSubcodecSummary] = []
        while cursor.remaining > 0 {
            guard cursor.remaining >= 13 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let x = try cursor.readLittleEndianUInt16()
            let y = try cursor.readLittleEndianUInt16()
            let width = try cursor.readLittleEndianUInt16()
            let height = try cursor.readLittleEndianUInt16()
            let byteCount = try cursor.readLittleEndianUInt32()
            let codecID = try cursor.readUInt8()
            guard width > 0,
                  height > 0,
                  x <= UInt16.max - width,
                  y <= UInt16.max - height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let bitmapData = try cursor.readData(count: Int(byteCount))
            let nsCodec = codecID == 0x01
                ? try summarizeNSCodecSubcodec(bitmapData)
                : nil
            summaries.append(RDPClearCodecSubcodecSummary(
                rect: RDPFrameRect(
                    left: x,
                    top: y,
                    right: x + width,
                    bottom: y + height
                ),
                byteCount: byteCount,
                codecID: codecID,
                nsCodecYByteCount: nsCodec?.yByteCount,
                nsCodecCoByteCount: nsCodec?.coByteCount,
                nsCodecCgByteCount: nsCodec?.cgByteCount,
                nsCodecAlphaByteCount: nsCodec?.alphaByteCount,
                nsCodecColorLossLevel: nsCodec?.colorLossLevel,
                nsCodecChromaSubsamplingLevel: nsCodec?.chromaSubsamplingLevel
            ))
        }
        return summaries
    }

    private struct NSCodecSummary {
        var yByteCount: UInt32
        var coByteCount: UInt32
        var cgByteCount: UInt32
        var alphaByteCount: UInt32
        var colorLossLevel: UInt8
        var chromaSubsamplingLevel: UInt8
    }

    private static func summarizeNSCodecSubcodec(_ data: Data) throws -> NSCodecSummary {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let yByteCount = try cursor.readLittleEndianUInt32()
        let coByteCount = try cursor.readLittleEndianUInt32()
        let cgByteCount = try cursor.readLittleEndianUInt32()
        let alphaByteCount = try cursor.readLittleEndianUInt32()
        let colorLossLevel = try cursor.readUInt8()
        let chromaSubsamplingLevel = try cursor.readUInt8()
        let reserved0 = try cursor.readUInt8()
        let reserved1 = try cursor.readUInt8()
        guard reserved0 == 0,
              reserved1 == 0,
              UInt64(yByteCount) + UInt64(coByteCount) + UInt64(cgByteCount) + UInt64(alphaByteCount)
              == UInt64(cursor.remaining)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return NSCodecSummary(
            yByteCount: yByteCount,
            coByteCount: coByteCount,
            cgByteCount: cgByteCount,
            alphaByteCount: alphaByteCount,
            colorLossLevel: colorLossLevel,
            chromaSubsamplingLevel: chromaSubsamplingLevel
        )
    }

    private func decodeResidualLayer(_ data: Data, into bitmap: inout RDPClearCodecBitmap) throws {
        var cursor = ByteCursor(data)
        var pixelIndex = 0
        while cursor.remaining > 0 {
            guard cursor.remaining >= 4 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let blue = try cursor.readUInt8()
            let green = try cursor.readUInt8()
            let red = try cursor.readUInt8()
            let runLength = try decodeRunLength(firstFactor: cursor.readUInt8(), cursor: &cursor)
            guard pixelIndex + runLength <= bitmap.width * bitmap.height else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            for index in pixelIndex ..< pixelIndex + runLength {
                setPixel(
                    x: index % bitmap.width,
                    y: index / bitmap.width,
                    blue: blue,
                    green: green,
                    red: red,
                    in: &bitmap
                )
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
            let backgroundBlue = try cursor.readUInt8()
            let backgroundGreen = try cursor.readUInt8()
            let backgroundRed = try cursor.readUInt8()

            guard xEnd >= xStart,
                  yEnd >= yStart,
                  xStart >= 0,
                  yStart >= 0,
                  xEnd < bitmap.width,
                  yEnd < bitmap.height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let vBarHeight = yEnd - yStart + 1
            guard vBarHeight <= 52 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            for column in 0 ... (xEnd - xStart) {
                let vBar = try decodeVBar(
                    backgroundBlue: backgroundBlue,
                    backgroundGreen: backgroundGreen,
                    backgroundRed: backgroundRed,
                    height: vBarHeight,
                    cursor: &cursor
                )
                try blitVBar(vBar, x: xStart + column, y: yStart, into: &bitmap)
            }
        }
    }

    private func decodeVBar(
        backgroundBlue: UInt8,
        backgroundGreen: UInt8,
        backgroundRed: UInt8,
        height: Int,
        cursor: inout ByteCursor
    ) throws -> VBarEntry {
        let header = try cursor.readLittleEndianUInt16()

        if header & 0xC000 == 0x4000 {
            let index = Int(header & 0x3FFF)
            guard let shortVBar = shortVBarStorage[index] else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let yOn = try Int(cursor.readUInt8())
            let vBar = try composeVBar(
                shortVBar: shortVBar,
                yOn: yOn,
                backgroundBlue: backgroundBlue,
                backgroundGreen: backgroundGreen,
                backgroundRed: backgroundRed,
                height: height
            )
            storeVBar(vBar)
            return vBar
        }

        if header & 0xC000 == 0x0000 {
            let yOn = Int(header & 0x00FF)
            let yOff = Int((header >> 8) & 0x003F)
            guard yOff >= yOn,
                  yOn <= height,
                  yOff <= height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let shortPixelCount = yOff - yOn
            guard shortPixelCount <= 52 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            var shortData = Data()
            shortData.reserveCapacity(shortPixelCount * 4)
            for _ in 0 ..< shortPixelCount {
                shortData.append(try cursor.readUInt8())
                shortData.append(try cursor.readUInt8())
                shortData.append(try cursor.readUInt8())
                shortData.append(0xFF)
            }

            let shortVBar = VBarEntry(bgraData: shortData)
            shortVBarStorage[shortVBarStorageCursor] = shortVBar
            shortVBarStorageCursor = (shortVBarStorageCursor + 1) % 16_384

            let vBar = try composeVBar(
                shortVBar: shortVBar,
                yOn: yOn,
                backgroundBlue: backgroundBlue,
                backgroundGreen: backgroundGreen,
                backgroundRed: backgroundRed,
                height: height
            )
            storeVBar(vBar)
            return vBar
        }

        if header & 0x8000 == 0x8000 {
            let index = Int(header & 0x7FFF)
            guard let vBar = vBarStorage[index],
                  vBar.bgraData.count == height * 4
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return vBar
        }

        throw RDPDecodeError.invalidRDPGFXPDU
    }

    private func composeVBar(
        shortVBar: VBarEntry,
        yOn: Int,
        backgroundBlue: UInt8,
        backgroundGreen: UInt8,
        backgroundRed: UInt8,
        height: Int
    ) throws -> VBarEntry {
        guard shortVBar.bgraData.count % 4 == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let shortPixelCount = shortVBar.bgraData.count / 4
        guard yOn >= 0,
              yOn + shortPixelCount <= height
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var data = Data()
        data.reserveCapacity(height * 4)
        for y in 0 ..< height {
            if y >= yOn, y < yOn + shortPixelCount {
                let offset = (y - yOn) * 4
                data.append(shortVBar.bgraData[offset ..< offset + 4])
            } else {
                data.append(backgroundBlue)
                data.append(backgroundGreen)
                data.append(backgroundRed)
                data.append(0xFF)
            }
        }

        return VBarEntry(bgraData: data)
    }

    private func storeVBar(_ vBar: VBarEntry) {
        vBarStorage[vBarStorageCursor] = vBar
        vBarStorageCursor = (vBarStorageCursor + 1) % 32_768
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
                  x >= 0,
                  y >= 0,
                  x + width <= bitmap.width,
                  y + height <= bitmap.height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            switch codecID {
            case 0x00:
                try decodeRawSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            case 0x01:
                try decodeNSCodecSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            case 0x02:
                try decodeRLEXSubcodec(bitmapData, x: x, y: y, width: width, height: height, into: &bitmap)
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
    }

    private func blitVBar(_ vBar: VBarEntry, x: Int, y: Int, into bitmap: inout RDPClearCodecBitmap) throws {
        let height = vBar.bgraData.count / 4
        guard x >= 0,
              y >= 0,
              x < bitmap.width,
              y + height <= bitmap.height,
              vBar.bgraData.count == height * 4
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        for row in 0 ..< height {
            let sourceOffset = row * 4
            let destinationOffset = (y + row) * bitmap.bytesPerRow + x * 4
            bitmap.bgraData[destinationOffset ..< destinationOffset + 4] =
                vBar.bgraData[sourceOffset ..< sourceOffset + 4]
        }
    }

    private func decodeRawSubcodec(
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
                setPixel(x: x + column, y: y + row, blue: blue, green: green, red: red, in: &bitmap)
            }
        }
    }

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
            palette.append((
                blue: try cursor.readUInt8(),
                green: try cursor.readUInt8(),
                red: try cursor.readUInt8()
            ))
        }

        let stopIndexBits = bitLength(paletteCount - 1)
        let suiteDepthBits = 8 - stopIndexBits
        var pixelIndex = 0
        let pixelCount = width * height

        while cursor.remaining > 0 {
            guard cursor.remaining >= 2 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let packed = try cursor.readUInt8()
            let firstRunLengthFactor = try cursor.readUInt8()
            let suiteDepth = Int((packed >> UInt8(stopIndexBits)) & UInt8((1 << suiteDepthBits) - 1))
            let stopIndex = Int(packed & UInt8((1 << stopIndexBits) - 1))
            guard stopIndex >= suiteDepth, stopIndex < paletteCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let startIndex = stopIndex - suiteDepth
            let runLength = try decodeRunLength(firstFactor: firstRunLengthFactor, cursor: &cursor)
            guard pixelIndex + runLength + suiteDepth + 1 <= pixelCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            try writeRLEXPixels(
                count: runLength,
                paletteIndex: startIndex,
                palette: palette,
                x: x,
                y: y,
                width: width,
                pixelIndex: &pixelIndex,
                into: &bitmap
            )
            for paletteIndex in startIndex ... stopIndex {
                try writeRLEXPixels(
                    count: 1,
                    paletteIndex: paletteIndex,
                    palette: palette,
                    x: x,
                    y: y,
                    width: width,
                    pixelIndex: &pixelIndex,
                    into: &bitmap
                )
            }
        }

        guard pixelIndex == pixelCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
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
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let yByteCount = try Int(cursor.readLittleEndianUInt32())
        let coByteCount = try Int(cursor.readLittleEndianUInt32())
        let cgByteCount = try Int(cursor.readLittleEndianUInt32())
        let alphaByteCount = try Int(cursor.readLittleEndianUInt32())
        let colorLossLevel = try cursor.readUInt8()
        let chromaSubsamplingLevel = try cursor.readUInt8()
        let reserved0 = try cursor.readUInt8()
        let reserved1 = try cursor.readUInt8()
        guard chromaSubsamplingLevel == 0,
              reserved0 == 0,
              reserved1 == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let yData = try cursor.readData(count: yByteCount)
        let coData = try cursor.readData(count: coByteCount)
        let cgData = try cursor.readData(count: cgByteCount)
        let alphaData = try cursor.readData(count: alphaByteCount)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let pixelCount = width * height
        let yPlane = try decodeNSCodecRLEPlane(yData, expectedByteCount: pixelCount)
        let coPlane = try decodeNSCodecRLEPlane(coData, expectedByteCount: pixelCount)
        let cgPlane = try decodeNSCodecRLEPlane(cgData, expectedByteCount: pixelCount)
        if !alphaData.isEmpty {
            _ = try decodeNSCodecRLEPlane(alphaData, expectedByteCount: pixelCount)
        }
        let chromaShift = max(Int(colorLossLevel) - 1, 0)
        guard chromaShift < UInt8.bitWidth else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        for pixelIndex in 0 ..< pixelCount {
            let luminance = Int(yPlane[pixelIndex])
            let orangeChroma = Self.decodeNSCodecChroma(coPlane[pixelIndex], shift: chromaShift)
            let greenChroma = Self.decodeNSCodecChroma(cgPlane[pixelIndex], shift: chromaShift)
            let temporary = luminance - greenChroma
            let red = clamp8(temporary + orangeChroma)
            let green = clamp8(luminance + greenChroma)
            let blue = clamp8(temporary - orangeChroma)
            setPixel(
                x: x + pixelIndex % width,
                y: y + pixelIndex / width,
                blue: blue,
                green: green,
                red: red,
                in: &bitmap
            )
        }
    }

    private static func decodeNSCodecChroma(_ value: UInt8, shift: Int) -> Int {
        let shifted = UInt16(value) << shift
        let truncated = UInt8(truncatingIfNeeded: shifted)
        return Int(Int8(bitPattern: truncated))
    }

    private func decodeNSCodecRLEPlane(_ data: Data, expectedByteCount: Int) throws -> [UInt8] {
        guard expectedByteCount >= 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if data.isEmpty {
            return Array(repeating: 0xFF, count: expectedByteCount)
        }
        if data.count >= expectedByteCount {
            return Array(data.prefix(expectedByteCount))
        }
        guard expectedByteCount > 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let encoded = Array(data)
        let encodedBodyEnd = encoded.count - 4
        let decodedBodyByteCount = expectedByteCount - 4
        var decoded: [UInt8] = []
        decoded.reserveCapacity(expectedByteCount)
        var index = 0
        while index < encodedBodyEnd {
            let value = encoded[index]
            index += 1
            if index < encodedBodyEnd, encoded[index] == value {
                index += 1
                guard index < encodedBodyEnd else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let runLengthFactor = encoded[index]
                index += 1
                let runLength: Int
                if runLengthFactor == 0xFF {
                    guard index + 4 <= encodedBodyEnd else {
                        throw RDPDecodeError.invalidRDPGFXPDU
                    }
                    runLength = Int(UInt32(encoded[index])
                        | UInt32(encoded[index + 1]) << 8
                        | UInt32(encoded[index + 2]) << 16
                        | UInt32(encoded[index + 3]) << 24)
                    index += 4
                } else {
                    runLength = Int(runLengthFactor) + 2
                }
                guard decoded.count + runLength <= decodedBodyByteCount else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                decoded.append(contentsOf: repeatElement(value, count: runLength))
            } else {
                guard decoded.count + 1 <= decodedBodyByteCount else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                decoded.append(value)
            }
        }
        guard decoded.count == decodedBodyByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        decoded.append(contentsOf: encoded[encodedBodyEnd ..< encoded.count])
        return decoded
    }

    private func writeRLEXPixels(
        count: Int,
        paletteIndex: Int,
        palette: [(blue: UInt8, green: UInt8, red: UInt8)],
        x: Int,
        y: Int,
        width: Int,
        pixelIndex: inout Int,
        into bitmap: inout RDPClearCodecBitmap
    ) throws {
        guard palette.indices.contains(paletteIndex) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let color = palette[paletteIndex]
        for _ in 0 ..< count {
            setPixel(
                x: x + pixelIndex % width,
                y: y + pixelIndex / width,
                blue: color.blue,
                green: color.green,
                red: color.red,
                in: &bitmap
            )
            pixelIndex += 1
        }
    }

    private func decodeRunLength(firstFactor: UInt8, cursor: inout ByteCursor) throws -> Int {
        guard firstFactor == 0xFF else {
            return Int(firstFactor)
        }

        let factor2 = try cursor.readLittleEndianUInt16()
        guard factor2 == 0xFFFF else {
            return Int(factor2)
        }
        return try Int(cursor.readLittleEndianUInt32())
    }

    private func setPixel(
        x: Int,
        y: Int,
        blue: UInt8,
        green: UInt8,
        red: UInt8,
        in bitmap: inout RDPClearCodecBitmap
    ) {
        let offset = y * bitmap.bytesPerRow + x * 4
        bitmap.bgraData[offset] = blue
        bitmap.bgraData[offset + 1] = green
        bitmap.bgraData[offset + 2] = red
        bitmap.bgraData[offset + 3] = 0xFF
    }

    private func clamp8(_ value: Int) -> UInt8 {
        UInt8(min(max(value, 0), 255))
    }

    private func bitLength(_ value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return Int.bitWidth - value.leadingZeroBitCount
    }
}
