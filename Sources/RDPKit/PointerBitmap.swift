import CoreGraphics
import Foundation

/// A remote pointer shape as premultiplied RGBA pixels and a hot spot, ready for a cursor:
/// `NSCursor(image:hotSpot:)` on macOS, or a pointer style on iOS and visionOS.
///
/// It combines the masks of an ``RDPRemotePointerImage`` as Windows draws a cursor
/// ([MS-RDPBCGR] 2.2.9.1.1.4.4-2.2.9.1.1.4.6). Both masks run bottom-up, with each scan-line
/// padded to 2 bytes, and the AND mask has 1 bit a pixel:
/// - AND 0 shows the XOR color, opaque.
/// - AND 1 with an XOR of 0 is transparent.
/// - AND 1 with any other XOR inverts the screen under it, which a cursor image cannot
///   express. Such a pixel is drawn opaque black, and each transparent pixel next to it
///   (diagonals too) opaque white. An inverting shape, such as the Windows I-beam, is then
///   black with a white outline, which shows on any background.
///
/// The XOR mask's depth sets its colors:
/// - 1 bpp: 0 is black and 1 is white.
/// - 16 bpp: RGB565, RDP's 16-bit color ([MS-RDPBCGR] 2.2.1.3.2).
/// - 24 bpp: blue, green and red bytes.
/// - 32 bpp: blue, green, red and alpha bytes, the colors not premultiplied. A mask with any
///   non-zero alpha, or with no AND mask (KRdp sends none), is an alpha cursor: alpha alone
///   gives the shape, and an AND mask is ignored, as Windows draws one. With an AND mask and
///   only zero alpha, the colors are opaque and combine with the AND mask like 24 bpp.
/// - 4 and 8 bpp index the session palette, which only sessions of 8 bpp or fewer have.
///   RDPKit asks for 15 bpp or more, so these depths are not decoded.
public struct RDPRemotePointerBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// The rows from the top, 4 bytes a pixel: red, green, blue and alpha, with the colors
    /// premultiplied by alpha.
    public let pixels: Data
    /// The pixel the pointer points at, from the image's top-left corner. It is clamped
    /// into the image.
    public let hotSpot: RDPRemotePoint

    /// Nil for an empty image, an XOR depth other than 1, 16, 24 or 32 bpp, a mask of the
    /// wrong length, or a missing AND mask below 32 bpp.
    public init?(_ pointer: RDPRemotePointerImage) {
        let width = Int(pointer.width)
        let height = Int(pointer.height)
        let bitsPerPixel = Int(pointer.xorBitsPerPixel)
        let xorRowBytes = pointerMaskRowByteCount(width: pointer.width, bitsPerPixel: pointer.xorBitsPerPixel)
        let andRowBytes = pointerMaskRowByteCount(width: pointer.width, bitsPerPixel: 1)
        let xorMask = [UInt8](pointer.xorMaskData)
        let andMask = [UInt8](pointer.andMaskData)
        guard width > 0, height > 0,
              [1, 16, 24, 32].contains(bitsPerPixel),
              xorMask.count == xorRowBytes * height,
              andMask.isEmpty ? bitsPerPixel == 32 : andMask.count == andRowBytes * height
        else {
            return nil
        }

        let usesAlpha = bitsPerPixel == 32
            && (andMask.isEmpty || stride(from: 3, to: xorMask.count, by: 4).contains { xorMask[$0] != 0 })
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var invertedPixels: [Int] = []
        for row in 0 ..< height {
            // The masks' first scan-line is the bottom one.
            let xorRow = (height - 1 - row) * xorRowBytes
            let andRow = (height - 1 - row) * andRowBytes
            for column in 0 ..< width {
                let pixel = (row * width + column) * 4
                let xor = Self.xorColor(in: xorMask, at: xorRow, column: column, bitsPerPixel: bitsPerPixel)
                if usesAlpha {
                    pixels[pixel] = Self.premultiplied(xor.red, by: xor.alpha)
                    pixels[pixel + 1] = Self.premultiplied(xor.green, by: xor.alpha)
                    pixels[pixel + 2] = Self.premultiplied(xor.blue, by: xor.alpha)
                    pixels[pixel + 3] = xor.alpha
                } else if andMask[andRow + column / 8] & (0x80 >> (column % 8)) == 0 {
                    pixels[pixel] = xor.red
                    pixels[pixel + 1] = xor.green
                    pixels[pixel + 2] = xor.blue
                    pixels[pixel + 3] = 0xFF
                } else if xor.isNonZero {
                    pixels[pixel + 3] = 0xFF
                    invertedPixels.append(row * width + column)
                }
            }
        }
        for inverted in invertedPixels {
            let row = inverted / width
            let column = inverted % width
            for neighborRow in max(row - 1, 0) ... min(row + 1, height - 1) {
                for neighborColumn in max(column - 1, 0) ... min(column + 1, width - 1) {
                    let pixel = (neighborRow * width + neighborColumn) * 4
                    if pixels[pixel + 3] == 0 {
                        for component in pixel ..< pixel + 4 {
                            pixels[component] = 0xFF
                        }
                    }
                }
            }
        }

        self.width = width
        self.height = height
        bytesPerRow = width * 4
        self.pixels = Data(pixels)
        hotSpot = RDPRemotePoint(
            x: min(pointer.hotSpot.x, pointer.width - 1),
            y: min(pointer.hotSpot.y, pointer.height - 1)
        )
    }

    /// The pixels as an sRGB `CGImage`, for `NSImage(cgImage:size:)` or `UIImage(cgImage:)`.
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private struct XORColor {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
        /// Whether any color bit is set; alpha does not count.
        var isNonZero: Bool
    }

    private static func premultiplied(_ component: UInt8, by alpha: UInt8) -> UInt8 {
        UInt8((Int(component) * Int(alpha) + 127) / 255)
    }

    private static func xorColor(in mask: [UInt8], at row: Int, column: Int, bitsPerPixel: Int) -> XORColor {
        switch bitsPerPixel {
        case 1:
            let level: UInt8 = mask[row + column / 8] & (0x80 >> (column % 8)) == 0 ? 0 : 0xFF
            return XORColor(red: level, green: level, blue: level, alpha: 0xFF, isNonZero: level != 0)
        case 16:
            let value = Int(mask[row + column * 2]) | Int(mask[row + column * 2 + 1]) << 8
            return XORColor(
                red: UInt8(((value >> 11) * 255 + 15) / 31),
                green: UInt8((((value >> 5) & 0x3F) * 255 + 31) / 63),
                blue: UInt8(((value & 0x1F) * 255 + 15) / 31),
                alpha: 0xFF,
                isNonZero: value != 0
            )
        default:
            let offset = row + column * bitsPerPixel / 8
            let blue = mask[offset]
            let green = mask[offset + 1]
            let red = mask[offset + 2]
            return XORColor(
                red: red,
                green: green,
                blue: blue,
                alpha: bitsPerPixel == 32 ? mask[offset + 3] : 0xFF,
                isNonZero: red | green | blue != 0
            )
        }
    }
}
