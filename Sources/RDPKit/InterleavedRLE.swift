import Foundation

/// Decoder for the Interleaved RLE bitmap stream defined by MS-RDPBCGR 3.1.9.
enum RDPInterleavedBitmapDecoder {
    static func decode(
        _ data: Data,
        width: Int,
        height: Int,
        bitsPerPixel: Int
    ) throws -> Data {
        guard width > 0,
              height > 0,
              let pixelByteCount = pixelByteCount(bitsPerPixel: bitsPerPixel),
              width <= Int.max / height
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let expectedPixelCount = width * height
        var decoder = Decoder(
            source: Array(data),
            width: width,
            expectedPixelCount: expectedPixelCount,
            pixelByteCount: pixelByteCount,
            whitePixel: whitePixel(bitsPerPixel: bitsPerPixel)
        )
        let pixels = try decoder.decode()

        guard expectedPixelCount <= Int.max / pixelByteCount else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        var result = Data(capacity: expectedPixelCount * pixelByteCount)
        for pixel in pixels {
            for byteIndex in 0 ..< pixelByteCount {
                result.append(UInt8(truncatingIfNeeded: pixel >> UInt32(byteIndex * 8)))
            }
        }
        return result
    }

    private static func pixelByteCount(bitsPerPixel: Int) -> Int? {
        switch bitsPerPixel {
        case 8:
            1
        case 15, 16:
            2
        case 24:
            3
        default:
            nil
        }
    }

    private static func whitePixel(bitsPerPixel: Int) -> UInt32 {
        switch bitsPerPixel {
        case 8:
            0xFF
        case 15:
            0x7FFF
        case 16:
            0xFFFF
        case 24:
            0xFF_FFFF
        default:
            0
        }
    }

    private struct Decoder {
        var source: [UInt8]
        var sourceIndex = 0
        var width: Int
        var expectedPixelCount: Int
        var pixelByteCount: Int
        var whitePixel: UInt32
        var foregroundPixel: UInt32
        var pixels: [UInt32] = []
        var insertForegroundPixel = false
        var isFirstLine = true

        init(
            source: [UInt8],
            width: Int,
            expectedPixelCount: Int,
            pixelByteCount: Int,
            whitePixel: UInt32
        ) {
            self.source = source
            self.width = width
            self.expectedPixelCount = expectedPixelCount
            self.pixelByteCount = pixelByteCount
            self.whitePixel = whitePixel
            foregroundPixel = whitePixel
            pixels.reserveCapacity(expectedPixelCount)
        }

        mutating func decode() throws -> [UInt32] {
            while sourceIndex < source.count {
                if isFirstLine, pixels.count >= width {
                    isFirstLine = false
                    insertForegroundPixel = false
                }

                let header = try readByte()
                let code = codeIdentifier(header)

                if code == Code.regularBackgroundRun || code == Code.megaMegaBackgroundRun {
                    try decodeBackgroundRun(length: runLength(code: code, header: header))
                    insertForegroundPixel = true
                    continue
                }

                insertForegroundPixel = false
                switch code {
                case Code.regularForegroundRun, Code.megaMegaForegroundRun,
                     Code.liteSetForegroundRun, Code.megaMegaSetForegroundRun:
                    try decodeForegroundRun(
                        length: runLength(code: code, header: header),
                        setsForeground: code == Code.liteSetForegroundRun
                            || code == Code.megaMegaSetForegroundRun
                    )

                case Code.liteDitheredRun, Code.megaMegaDitheredRun:
                    try decodeDitheredRun(length: runLength(code: code, header: header))

                case Code.regularColorRun, Code.megaMegaColorRun:
                    try decodeColorRun(length: runLength(code: code, header: header))

                case Code.regularForegroundBackgroundImage, Code.megaMegaForegroundBackgroundImage,
                     Code.liteSetForegroundBackgroundImage, Code.megaMegaSetForegroundBackgroundImage:
                    try decodeForegroundBackgroundImage(
                        length: runLength(code: code, header: header),
                        setsForeground: code == Code.liteSetForegroundBackgroundImage
                            || code == Code.megaMegaSetForegroundBackgroundImage
                    )

                case Code.regularColorImage, Code.megaMegaColorImage:
                    try decodeColorImage(length: runLength(code: code, header: header))

                case Code.specialForegroundBackground1:
                    try writeForegroundBackgroundBits(mask: 0x03, count: 8)

                case Code.specialForegroundBackground2:
                    try writeForegroundBackgroundBits(mask: 0x05, count: 8)

                case Code.white:
                    try append(whitePixel)

                case Code.black:
                    try append(0)

                default:
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
            }

            guard pixels.count == expectedPixelCount else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            return pixels
        }

        private func codeIdentifier(_ header: UInt8) -> UInt8 {
            if header & 0xC0 != 0xC0 {
                return header >> 5
            }
            if header & 0xF0 != 0xF0 {
                return header >> 4
            }
            return header
        }

        private mutating func runLength(code: UInt8, header: UInt8) throws -> Int {
            let length: Int
            if code == Code.regularForegroundBackgroundImage {
                let encoded = Int(header & 0x1F)
                length = encoded == 0 ? Int(try readByte()) + 1 : encoded * 8
            } else if code == Code.liteSetForegroundBackgroundImage {
                let encoded = Int(header & 0x0F)
                length = encoded == 0 ? Int(try readByte()) + 1 : encoded * 8
            } else if code <= Code.regularColorImage {
                let encoded = Int(header & 0x1F)
                length = encoded == 0 ? Int(try readByte()) + 32 : encoded
            } else if code >= Code.liteSetForegroundRun, code <= Code.liteDitheredRun {
                let encoded = Int(header & 0x0F)
                length = encoded == 0 ? Int(try readByte()) + 16 : encoded
            } else if code >= Code.megaMegaBackgroundRun, code <= Code.megaMegaDitheredRun {
                length = Int(try readLittleEndianUInt16())
            } else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }

            guard length > 0 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            return length
        }

        private mutating func decodeBackgroundRun(length: Int) throws {
            var remaining = length
            if insertForegroundPixel {
                guard remaining > 0 else {
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
                try append(isFirstLine ? foregroundPixel : previousLinePixel() ^ foregroundPixel)
                remaining -= 1
            }
            for _ in 0 ..< remaining {
                try append(isFirstLine ? 0 : previousLinePixel())
            }
        }

        private mutating func decodeForegroundRun(length: Int, setsForeground: Bool) throws {
            if setsForeground {
                foregroundPixel = try readPixel()
            }
            for _ in 0 ..< length {
                try append(isFirstLine ? foregroundPixel : previousLinePixel() ^ foregroundPixel)
            }
        }

        private mutating func decodeDitheredRun(length: Int) throws {
            let pixelA = try readPixel()
            let pixelB = try readPixel()
            guard length <= (expectedPixelCount - pixels.count) / 2 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            for _ in 0 ..< length {
                try append(pixelA)
                try append(pixelB)
            }
        }

        private mutating func decodeColorRun(length: Int) throws {
            let pixel = try readPixel()
            for _ in 0 ..< length {
                try append(pixel)
            }
        }

        private mutating func decodeForegroundBackgroundImage(length: Int, setsForeground: Bool) throws {
            if setsForeground {
                foregroundPixel = try readPixel()
            }
            var remaining = length
            while remaining > 0 {
                let count = min(8, remaining)
                try writeForegroundBackgroundBits(mask: try readByte(), count: count)
                remaining -= count
            }
        }

        private mutating func writeForegroundBackgroundBits(mask: UInt8, count: Int) throws {
            for bitIndex in 0 ..< count {
                let usesForeground = mask & (1 << UInt8(bitIndex)) != 0
                let background: UInt32
                if isFirstLine {
                    background = 0
                } else {
                    background = try previousLinePixel()
                }
                try append(usesForeground ? background ^ foregroundPixel : background)
            }
        }

        private mutating func decodeColorImage(length: Int) throws {
            for _ in 0 ..< length {
                try append(readPixel())
            }
        }

        private func previousLinePixel() throws -> UInt32 {
            let index = pixels.count - width
            guard index >= 0, index < pixels.count else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            return pixels[index]
        }

        private mutating func append(_ pixel: UInt32) throws {
            guard pixels.count < expectedPixelCount else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            pixels.append(pixel)
        }

        private mutating func readPixel() throws -> UInt32 {
            var pixel: UInt32 = 0
            for byteIndex in 0 ..< pixelByteCount {
                pixel |= UInt32(try readByte()) << UInt32(byteIndex * 8)
            }
            return pixel
        }

        private mutating func readLittleEndianUInt16() throws -> UInt16 {
            let low = UInt16(try readByte())
            let high = UInt16(try readByte())
            return low | high << 8
        }

        private mutating func readByte() throws -> UInt8 {
            guard sourceIndex < source.count else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            defer { sourceIndex += 1 }
            return source[sourceIndex]
        }
    }

    private enum Code {
        static let regularBackgroundRun: UInt8 = 0x00
        static let regularForegroundRun: UInt8 = 0x01
        static let regularForegroundBackgroundImage: UInt8 = 0x02
        static let regularColorRun: UInt8 = 0x03
        static let regularColorImage: UInt8 = 0x04
        static let liteSetForegroundRun: UInt8 = 0x0C
        static let liteSetForegroundBackgroundImage: UInt8 = 0x0D
        static let liteDitheredRun: UInt8 = 0x0E
        static let megaMegaBackgroundRun: UInt8 = 0xF0
        static let megaMegaForegroundRun: UInt8 = 0xF1
        static let megaMegaForegroundBackgroundImage: UInt8 = 0xF2
        static let megaMegaColorRun: UInt8 = 0xF3
        static let megaMegaColorImage: UInt8 = 0xF4
        static let megaMegaSetForegroundRun: UInt8 = 0xF6
        static let megaMegaSetForegroundBackgroundImage: UInt8 = 0xF7
        static let megaMegaDitheredRun: UInt8 = 0xF8
        static let specialForegroundBackground1: UInt8 = 0xF9
        static let specialForegroundBackground2: UInt8 = 0xFA
        static let white: UInt8 = 0xFD
        static let black: UInt8 = 0xFE
    }
}
