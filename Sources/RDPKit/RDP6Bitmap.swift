import Foundation

/// Decoder for the planar bitmap stream defined by MS-RDPEGDI 3.1.9.
enum RDP6BitmapDecoder {
    static func decode(_ data: Data, width: Int, height: Int) throws -> Data {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        var decoder = Decoder(source: Array(data), width: width, height: height)
        return try decoder.decode()
    }

    private struct Decoder {
        let source: [UInt8]
        let width: Int
        let height: Int
        var sourceIndex = 0

        mutating func decode() throws -> Data {
            let format = try readByte()
            let colorLossLevel = Int(format & 0x07)
            let usesChromaSubsampling = format & 0x08 != 0
            let usesRLE = format & 0x10 != 0
            let hasAlpha = format & 0x20 == 0
            guard format & 0xC0 == 0,
                  !usesChromaSubsampling || colorLossLevel > 0
            else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }

            let fullPlaneSize = width * height
            let chromaWidth = usesChromaSubsampling ? (width + 1) / 2 : width
            let chromaHeight = usesChromaSubsampling ? (height + 1) / 2 : height
            let chromaPlaneSize = chromaWidth * chromaHeight

            let alpha = try hasAlpha ? decodePlane(width: width, height: height, usesRLE: usesRLE) : nil
            let lumaOrRed = try decodePlane(width: width, height: height, usesRLE: usesRLE)
            let orangeOrGreen = try decodePlane(
                width: chromaWidth,
                height: chromaHeight,
                usesRLE: usesRLE
            )
            let greenOrBlue = try decodePlane(
                width: chromaWidth,
                height: chromaHeight,
                usesRLE: usesRLE
            )

            let remaining = source.count - sourceIndex
            guard usesRLE ? remaining == 0 : remaining == 0 || remaining == 1 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            sourceIndex = source.count

            guard lumaOrRed.count == fullPlaneSize,
                  orangeOrGreen.count == chromaPlaneSize,
                  greenOrBlue.count == chromaPlaneSize
            else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }

            var result = Data(capacity: fullPlaneSize * 4)
            for row in 0 ..< height {
                for column in 0 ..< width {
                    let pixelIndex = row * width + column
                    let chromaIndex = usesChromaSubsampling
                        ? (row / 2) * chromaWidth + column / 2
                        : pixelIndex
                    let alphaValue = alpha?[pixelIndex] ?? 0xFF

                    if colorLossLevel == 0 {
                        result.append(greenOrBlue[chromaIndex])
                        result.append(orangeOrGreen[chromaIndex])
                        result.append(lumaOrRed[pixelIndex])
                        result.append(alphaValue)
                    } else {
                        let y = Int(lumaOrRed[pixelIndex])
                        let co = Int(Int8(bitPattern: orangeOrGreen[chromaIndex])) << colorLossLevel
                        let cg = Int(Int8(bitPattern: greenOrBlue[chromaIndex])) << colorLossLevel
                        var red = clamp(y + (co >> 1) - (cg >> 1))
                        let green = clamp(y + (cg >> 1))
                        var blue = clamp(y - (co >> 1) - (cg >> 1))
                        if !hasAlpha {
                            swap(&red, &blue)
                        }
                        result.append(UInt8(blue))
                        result.append(UInt8(green))
                        result.append(UInt8(red))
                        result.append(alphaValue)
                    }
                }
            }
            return result
        }

        private func clamp(_ value: Int) -> Int {
            min(255, max(0, value))
        }

        private mutating func decodePlane(width: Int, height: Int, usesRLE: Bool) throws -> [UInt8] {
            guard width > 0, height > 0, width <= Int.max / height else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            if !usesRLE {
                return try readBytes(count: width * height)
            }

            var plane = [UInt8](repeating: 0, count: width * height)
            for row in 0 ..< height {
                var column = 0
                var lastEncodedValue: UInt8 = 0
                repeat {
                    let control = try readByte()
                    guard control != 0 else {
                        throw RDPDecodeError.invalidGraphicsUpdatePDU
                    }

                    var rawCount = Int(control >> 4)
                    let encodedRunLength = Int(control & 0x0F)
                    let runLength: Int
                    if encodedRunLength == 1 {
                        runLength = 16 + rawCount
                        rawCount = 0
                    } else if encodedRunLength == 2 {
                        runLength = 32 + rawCount
                        rawCount = 0
                    } else {
                        runLength = encodedRunLength
                    }
                    guard rawCount + runLength <= width - column else {
                        throw RDPDecodeError.invalidGraphicsUpdatePDU
                    }

                    for _ in 0 ..< rawCount {
                        lastEncodedValue = try readByte()
                        plane[row * width + column] = decodedValue(
                            lastEncodedValue,
                            row: row,
                            column: column,
                            width: width,
                            plane: plane
                        )
                        column += 1
                    }
                    for _ in 0 ..< runLength {
                        plane[row * width + column] = decodedValue(
                            lastEncodedValue,
                            row: row,
                            column: column,
                            width: width,
                            plane: plane
                        )
                        column += 1
                    }
                } while column < width
            }
            return plane
        }

        private func decodedValue(
            _ encoded: UInt8,
            row: Int,
            column: Int,
            width: Int,
            plane: [UInt8]
        ) -> UInt8 {
            guard row > 0 else {
                return encoded
            }
            let delta = encoded & 1 == 0
                ? encoded >> 1
                : 255 &- ((encoded &- 1) >> 1)
            return plane[(row - 1) * width + column] &+ delta
        }

        private mutating func readByte() throws -> UInt8 {
            guard sourceIndex < source.count else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            defer { sourceIndex += 1 }
            return source[sourceIndex]
        }

        private mutating func readBytes(count: Int) throws -> [UInt8] {
            guard count >= 0, count <= source.count - sourceIndex else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            defer { sourceIndex += count }
            return Array(source[sourceIndex ..< sourceIndex + count])
        }
    }
}
