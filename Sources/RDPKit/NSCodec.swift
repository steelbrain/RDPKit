import Foundation

/// Decoder for the NSCodec bitmap stream (MS-RDPNSC 2.2.2, 3.1.8.4). Returns
/// BGRA pixels, `width * 4` bytes per row.
enum RDPNSCodecDecoder {
    static func decode(_ data: Data, width: Int, height: Int) throws -> Data {
        guard (1 ... Int(UInt16.max)).contains(width),
              (1 ... Int(UInt16.max)).contains(height)
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        let yByteCount = try Int(cursor.readLittleEndianUInt32())
        let coByteCount = try Int(cursor.readLittleEndianUInt32())
        let cgByteCount = try Int(cursor.readLittleEndianUInt32())
        let alphaByteCount = try Int(cursor.readLittleEndianUInt32())
        let colorLossLevel = try Int(cursor.readUInt8())
        let chromaSubsamplingLevel = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
        guard yByteCount > 0,
              coByteCount > 0,
              cgByteCount > 0,
              (1 ... 7).contains(colorLossLevel),
              chromaSubsamplingLevel <= 1,
              cursor.remaining == yByteCount + coByteCount + cgByteCount + alphaByteCount
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let usesSubsampling = chromaSubsamplingLevel == 1
        let yWidth = usesSubsampling ? roundedUp(width, toMultipleOf: 8) : width
        let chromaWidth = usesSubsampling ? yWidth / 2 : width
        let chromaHeight = usesSubsampling ? roundedUp(height, toMultipleOf: 2) / 2 : height
        let yPlane = try decodePlane(cursor.readData(count: yByteCount), byteCount: yWidth * height)
        let coPlane = try decodePlane(cursor.readData(count: coByteCount), byteCount: chromaWidth * chromaHeight)
        let cgPlane = try decodePlane(cursor.readData(count: cgByteCount), byteCount: chromaWidth * chromaHeight)
        let alphaPlane = alphaByteCount == 0
            ? nil
            : try decodePlane(cursor.readData(count: alphaByteCount), byteCount: width * height)
        let chromaShift = colorLossLevel - 1

        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            var pixelIndex = 0
            for row in 0 ..< height {
                let yRowStart = row * yWidth
                let chromaRowStart = (usesSubsampling ? row / 2 : row) * chromaWidth
                for column in 0 ..< width {
                    let chromaIndex = chromaRowStart + (usesSubsampling ? column / 2 : column)
                    let luma = Int(yPlane[yRowStart + column])
                    let orange = decodeChroma(coPlane[chromaIndex], shift: chromaShift)
                    let green = decodeChroma(cgPlane[chromaIndex], shift: chromaShift)
                    let lumaMinusGreen = luma - green
                    let offset = pixelIndex * 4
                    output[offset] = clamp(lumaMinusGreen - orange)
                    output[offset + 1] = clamp(luma + green)
                    output[offset + 2] = clamp(lumaMinusGreen + orange)
                    output[offset + 3] = alphaPlane?[pixelIndex] ?? 0xFF
                    pixelIndex += 1
                }
            }
        }
        return result
    }

    /// A plane is raw when its byte count equals the plane size; otherwise it is
    /// NSCODEC_RLE_SEGMENTS followed by the plane's last four raw bytes
    /// (MS-RDPNSC 2.2.2, 2.2.2.1).
    private static func decodePlane(_ data: Data, byteCount: Int) throws -> [UInt8] {
        guard data.count <= byteCount else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        if data.count == byteCount {
            return Array(data)
        }
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let encoded = Array(data)
        let encodedBodyEnd = encoded.count - 4
        let decodedBodyByteCount = byteCount - 4
        var decoded: [UInt8] = []
        decoded.reserveCapacity(byteCount)
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
                    runLength = Int(encoded[index])
                        | Int(encoded[index + 1]) << 8
                        | Int(encoded[index + 2]) << 16
                        | Int(encoded[index + 3]) << 24
                    index += 4
                } else {
                    runLength = Int(factor) + 2
                }
                guard runLength >= 2,
                      runLength <= decodedBodyByteCount - decoded.count
                else {
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

    /// Undoes color loss reduction and the YCoCg chroma halving (MS-RDPEGDI 3.1.9.1.2, 3.1.9.1.4).
    private static func decodeChroma(_ value: UInt8, shift: Int) -> Int {
        Int(Int8(bitPattern: value << shift))
    }

    private static func clamp(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }
}
