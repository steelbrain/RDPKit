import Foundation

/// Decoder for the bitmap stream defined by MS-RDPNSC 3.1.8.
enum RDPNSCodecDecoder {
    static func decode(_ data: Data, width: Int, height: Int) throws -> Data {
        guard width > 0,
              height > 0,
              width <= Int.max - 7,
              height <= Int.max - 1,
              width <= Int.max / height,
              width * height <= Int.max / 4
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        let yByteCount = try readPlaneByteCount(from: &cursor)
        let coByteCount = try readPlaneByteCount(from: &cursor)
        let cgByteCount = try readPlaneByteCount(from: &cursor)
        let alphaByteCount = try Int(cursor.readLittleEndianUInt32())
        let colorLossLevel = try Int(cursor.readUInt8())
        let chromaSubsamplingLevel = try cursor.readUInt8()
        let reserved = try cursor.readLittleEndianUInt16()
        guard (1 ... 7).contains(colorLossLevel),
              chromaSubsamplingLevel <= 1,
              reserved == 0
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let yData = try cursor.readData(count: yByteCount)
        let coData = try cursor.readData(count: coByteCount)
        let cgData = try cursor.readData(count: cgByteCount)
        let alphaData = try cursor.readData(count: alphaByteCount)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let usesSubsampling = chromaSubsamplingLevel == 1
        let yWidth = usesSubsampling ? roundedUp(width, toMultipleOf: 8) : width
        let chromaWidth = usesSubsampling ? yWidth / 2 : width
        let chromaHeight = usesSubsampling ? roundedUp(height, toMultipleOf: 2) / 2 : height
        let pixelCount = width * height
        let yPlane = try decodePlane(yData, expectedByteCount: yWidth * height, permitsEmpty: false)
        let coPlane = try decodePlane(
            coData,
            expectedByteCount: chromaWidth * chromaHeight,
            permitsEmpty: false
        )
        let cgPlane = try decodePlane(
            cgData,
            expectedByteCount: chromaWidth * chromaHeight,
            permitsEmpty: false
        )
        let alphaPlane = try decodePlane(alphaData, expectedByteCount: pixelCount, permitsEmpty: true)
        let chromaShift = colorLossLevel - 1

        var result = Data(capacity: pixelCount * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let pixelIndex = row * width + column
                let yIndex = row * yWidth + column
                let chromaIndex = usesSubsampling
                    ? (row / 2) * chromaWidth + column / 2
                    : pixelIndex
                let luminance = Int(yPlane[yIndex])
                let orangeChroma = decodeChroma(coPlane[chromaIndex], shift: chromaShift)
                let greenChroma = decodeChroma(cgPlane[chromaIndex], shift: chromaShift)
                let temporary = luminance - greenChroma
                result.append(clamp(temporary - orangeChroma))
                result.append(clamp(luminance + greenChroma))
                result.append(clamp(temporary + orangeChroma))
                result.append(alphaPlane[pixelIndex])
            }
        }
        return result
    }

    private static func readPlaneByteCount(from cursor: inout ByteCursor) throws -> Int {
        let count = try Int(cursor.readLittleEndianUInt32())
        guard count > 0 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        return count
    }

    private static func decodePlane(
        _ data: Data,
        expectedByteCount: Int,
        permitsEmpty: Bool
    ) throws -> [UInt8] {
        guard expectedByteCount > 0,
              data.count <= expectedByteCount,
              permitsEmpty || !data.isEmpty
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        if data.isEmpty {
            return Array(repeating: 0xFF, count: expectedByteCount)
        }
        if data.count == expectedByteCount {
            return Array(data)
        }
        guard expectedByteCount > 4, data.count >= 4 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
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
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
                let factor = encoded[index]
                index += 1
                let runLength: Int
                if factor == 0xFF {
                    guard index + 4 <= encodedBodyEnd else {
                        throw RDPDecodeError.invalidGraphicsUpdatePDU
                    }
                    let length = UInt32(encoded[index])
                        | UInt32(encoded[index + 1]) << 8
                        | UInt32(encoded[index + 2]) << 16
                        | UInt32(encoded[index + 3]) << 24
                    guard length >= 2 else {
                        throw RDPDecodeError.invalidGraphicsUpdatePDU
                    }
                    runLength = Int(length)
                    index += 4
                } else {
                    runLength = Int(factor) + 2
                }
                guard runLength <= decodedBodyByteCount - decoded.count else {
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
                decoded.append(contentsOf: repeatElement(value, count: runLength))
            } else {
                guard decoded.count < decodedBodyByteCount else {
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
                decoded.append(value)
            }
        }
        guard decoded.count == decodedBodyByteCount else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        decoded.append(contentsOf: encoded[encodedBodyEnd...])
        return decoded
    }

    private static func roundedUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
        (value + multiple - 1) / multiple * multiple
    }

    private static func decodeChroma(_ value: UInt8, shift: Int) -> Int {
        Int(Int8(bitPattern: UInt8(truncatingIfNeeded: UInt16(value) << shift)))
    }

    private static func clamp(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }
}
