import Foundation

final class RDPPrimarySurfaceCompositor {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var data: Data
    private var paletteEntries: Data?
    private var dirtyRects: [RDPFrameRect] = []
    private var activeFrameID: UInt32?
    private let remoteFX = RDPRemoteFXDecoder()

    init(width: UInt16, height: UInt16) {
        self.width = Int(width)
        self.height = Int(height)
        bytesPerRow = Int(width) * 4
        data = Data(repeating: 0, count: Int(width) * Int(height) * 4)
    }

    func process(_ commands: [RDPSurfaceCommand]) throws -> [RDPGraphicsFrameSnapshot] {
        var frames: [RDPGraphicsFrameSnapshot] = []
        for command in commands {
            switch command {
            case .setSurfaceBits(let bits),
                 .streamSurfaceBits(let bits):
                try blit(bits)
            case .frameMarker(let marker):
                if marker.frameAction == 0 {
                    if activeFrameID == nil,
                       let frame = makeFrame(frameID: nil)
                    {
                        frames.append(frame)
                    }
                    activeFrameID = marker.frameID
                } else {
                    if let frame = makeFrame(frameID: marker.frameID) {
                        frames.append(frame)
                    }
                    activeFrameID = nil
                }
            }
        }
        if activeFrameID == nil,
           let frame = makeFrame(frameID: nil)
        {
            frames.append(frame)
        }
        return frames
    }

    func process(_ update: RDPBitmapUpdate) throws -> [RDPGraphicsFrameSnapshot] {
        for rectangle in update.rectangles {
            try blit(rectangle)
        }
        if let frame = makeFrame(frameID: nil) {
            return [frame]
        }
        return []
    }

    func updatePalette(_ update: RDPPaletteUpdate) {
        paletteEntries = update.entries
    }

    private func blit(_ command: RDPSurfaceBitsCommand) throws {
        let bitmap = command.bitmapData
        if bitmap.codecID == 1 {
            let decoded = try RDPNSCodecDecoder.decode(
                bitmap.bitmapData,
                width: Int(bitmap.width),
                height: Int(bitmap.height)
            )
            try blitDecodedSurfaceBitmap(decoded, command: command)
            return
        }
        if bitmap.codecID == 3 {
            try blitRemoteFXSurfaceBitmap(bitmap.bitmapData, command: command)
            return
        }
        guard bitmap.codecID == 0 else {
            return
        }

        let sourceWidth = Int(bitmap.width)
        let sourceHeight = Int(bitmap.height)
        let sourceBytesPerPixel = try bytesPerPixel(for: bitmap.bitsPerPixel)
        let sourceBytesPerRow = alignedBytesPerRow(width: sourceWidth, bytesPerPixel: sourceBytesPerPixel)
        guard bitmap.bitmapData.count == sourceBytesPerRow * sourceHeight else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let destinationX = Int(command.destinationLeft)
        let destinationY = Int(command.destinationTop)
        guard destinationX >= 0,
              destinationY >= 0,
              destinationX + sourceWidth <= width,
              destinationY + sourceHeight <= height
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        try copySourceBitmap(
            bitmap.bitmapData,
            sourceBytesPerRow: sourceBytesPerRow,
            sourceBytesPerPixel: sourceBytesPerPixel,
            sourceBitsPerPixel: Int(bitmap.bitsPerPixel),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationX: destinationX,
            destinationY: destinationY,
            sourceIsBottomUp: false
        )
        dirtyRects.append(RDPFrameRect(
            left: UInt16(destinationX),
            top: UInt16(destinationY),
            right: UInt16(destinationX + sourceWidth),
            bottom: UInt16(destinationY + sourceHeight)
        ))
    }

    private func blitDecodedSurfaceBitmap(_ decoded: Data, command: RDPSurfaceBitsCommand) throws {
        let width = Int(command.bitmapData.width)
        let height = Int(command.bitmapData.height)
        guard decoded.count == width * height * 4 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        try blitSurfaceBitmap(
            decoded,
            bytesPerRow: width * 4,
            width: width,
            height: height,
            x: Int(command.destinationLeft),
            y: Int(command.destinationTop)
        )
    }

    private func blitRemoteFXSurfaceBitmap(_ encoded: Data, command: RDPSurfaceBitsCommand) throws {
        let frame: RDPRemoteFXDecodedFrame
        do {
            frame = try remoteFX.decode(encoded)
        } catch {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        for tile in frame.tiles {
            for region in frame.regionRects {
                let left = max(tile.x, Int(region.left))
                let top = max(tile.y, Int(region.top))
                let right = min(
                    tile.x + 64,
                    Int(region.right),
                    Int(command.bitmapData.width),
                    width - Int(command.destinationLeft)
                )
                let bottom = min(
                    tile.y + 64,
                    Int(region.bottom),
                    Int(command.bitmapData.height),
                    height - Int(command.destinationTop)
                )
                guard right > left, bottom > top else {
                    continue
                }
                try blitSurfaceBitmap(
                    tile.bgraData,
                    bytesPerRow: tile.bytesPerRow,
                    sourceX: left - tile.x,
                    sourceY: top - tile.y,
                    width: right - left,
                    height: bottom - top,
                    x: Int(command.destinationLeft) + left,
                    y: Int(command.destinationTop) + top
                )
            }
        }
    }

    private func blitSurfaceBitmap(
        _ bitmap: Data,
        bytesPerRow: Int,
        sourceX: Int = 0,
        sourceY: Int = 0,
        width sourceWidth: Int,
        height sourceHeight: Int,
        x: Int,
        y: Int
    ) throws {
        guard x >= 0,
              y >= 0,
              sourceX >= 0,
              sourceY >= 0,
              x + sourceWidth <= width,
              y + sourceHeight <= height,
              bytesPerRow >= (sourceX + sourceWidth) * 4,
              bitmap.count >= bytesPerRow * (sourceY + sourceHeight)
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        try copySourceBitmap(
            bitmap,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerPixel: 4,
            sourceBitsPerPixel: 32,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationX: x,
            destinationY: y,
            sourceIsBottomUp: false,
            sourceX: sourceX,
            sourceY: sourceY
        )
        dirtyRects.append(RDPFrameRect(
            left: UInt16(x),
            top: UInt16(y),
            right: UInt16(x + sourceWidth),
            bottom: UInt16(y + sourceHeight)
        ))
    }

    private func blit(_ rectangle: RDPBitmapUpdateRectangle) throws {
        let sourceWidth = Int(rectangle.width)
        let sourceHeight = Int(rectangle.height)
        let sourceBitsPerPixel = Int(rectangle.bitsPerPixel)
        let sourceBytesPerPixel = try bytesPerPixel(for: sourceBitsPerPixel)
        let destinationX = Int(rectangle.destinationLeft)
        let destinationY = Int(rectangle.destinationTop)
        let destinationRight = Int(rectangle.destinationRight)
        let destinationBottom = Int(rectangle.destinationBottom)
        guard destinationRight - destinationX + 1 == sourceWidth,
              destinationBottom - destinationY + 1 == sourceHeight,
              destinationX >= 0,
              destinationY >= 0,
              destinationX + sourceWidth <= width,
              destinationY + sourceHeight <= height
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let sourceData: Data
        let sourceBytesPerRow: Int
        if rectangle.isCompressed {
            if sourceBitsPerPixel == 32 {
                sourceData = try RDP6BitmapDecoder.decode(
                    rectangle.bitmapDataStream,
                    width: sourceWidth,
                    height: sourceHeight
                )
            } else {
                sourceData = try RDPInterleavedBitmapDecoder.decode(
                    rectangle.bitmapDataStream,
                    width: sourceWidth,
                    height: sourceHeight,
                    bitsPerPixel: sourceBitsPerPixel
                )
            }
            sourceBytesPerRow = sourceWidth * sourceBytesPerPixel
            if let compressedHeader = rectangle.compressedHeader {
                let declaredUncompressedSize = Int(compressedHeader[6])
                    | Int(compressedHeader[7]) << 8
                guard declaredUncompressedSize == sourceData.count else {
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
            }
        } else {
            guard rectangle.compressedHeader == nil else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            sourceData = rectangle.bitmapDataStream
            sourceBytesPerRow = alignedBytesPerRow(width: sourceWidth, bytesPerPixel: sourceBytesPerPixel)
        }
        guard sourceData.count == sourceBytesPerRow * sourceHeight else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        try copySourceBitmap(
            sourceData,
            sourceBytesPerRow: sourceBytesPerRow,
            sourceBytesPerPixel: sourceBytesPerPixel,
            sourceBitsPerPixel: sourceBitsPerPixel,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationX: destinationX,
            destinationY: destinationY,
            sourceIsBottomUp: true
        )
        dirtyRects.append(RDPFrameRect(
            left: rectangle.destinationLeft,
            top: rectangle.destinationTop,
            right: UInt16(destinationX + sourceWidth),
            bottom: UInt16(destinationY + sourceHeight)
        ))
    }

    private func bytesPerPixel(for bitsPerPixel: UInt8) throws -> Int {
        try bytesPerPixel(for: Int(bitsPerPixel))
    }

    private func bytesPerPixel(for bitsPerPixel: Int) throws -> Int {
        switch bitsPerPixel {
        case 8:
            1
        case 15, 16:
            2
        case 24:
            3
        case 32:
            4
        default:
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
    }

    private func alignedBytesPerRow(width: Int, bytesPerPixel: Int) -> Int {
        let bytesPerRow = width * bytesPerPixel
        return (bytesPerRow + 3) & ~3
    }

    private func copySourceBitmap(
        _ sourceData: Data,
        sourceBytesPerRow: Int,
        sourceBytesPerPixel: Int,
        sourceBitsPerPixel: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        destinationX: Int,
        destinationY: Int,
        sourceIsBottomUp: Bool,
        sourceX: Int = 0,
        sourceY: Int = 0
    ) throws {
        let paletteEntries = paletteEntries
        try sourceData.withUnsafeBytes { sourceBuffer in
            try data.withUnsafeMutableBytes { destinationBuffer in
                guard let sourceBase = sourceBuffer.baseAddress,
                      let destinationBase = destinationBuffer.baseAddress
                else {
                    return
                }
                for row in 0 ..< sourceHeight {
                    let sourceRowIndex = sourceIsBottomUp ? sourceHeight - 1 - row : sourceY + row
                    let sourceRow = sourceBase.advanced(
                        by: sourceRowIndex * sourceBytesPerRow + sourceX * sourceBytesPerPixel
                    )
                    let destinationRow = destinationBase.advanced(
                        by: (destinationY + row) * bytesPerRow + destinationX * 4
                    )
                    try copySourceRow(
                        sourceRow,
                        destinationRow: destinationRow,
                        sourceBytesPerPixel: sourceBytesPerPixel,
                        sourceBitsPerPixel: sourceBitsPerPixel,
                        paletteEntries: paletteEntries,
                        sourceWidth: sourceWidth
                    )
                }
            }
        }
    }

    private func copySourceRow(
        _ sourceRow: UnsafeRawPointer,
        destinationRow: UnsafeMutableRawPointer,
        sourceBytesPerPixel: Int,
        sourceBitsPerPixel: Int,
        paletteEntries: Data?,
        sourceWidth: Int
    ) throws {
        if sourceBytesPerPixel == 4 {
            memcpy(destinationRow, sourceRow, sourceWidth * 4)
            return
        }

        let source = sourceRow.assumingMemoryBound(to: UInt8.self)
        let destination = destinationRow.assumingMemoryBound(to: UInt8.self)
        for column in 0 ..< sourceWidth {
            let destinationOffset = column * 4
            switch sourceBitsPerPixel {
            case 8:
                guard let paletteEntries else {
                    throw RDPDecodeError.invalidGraphicsUpdatePDU
                }
                let paletteOffset = Int(source[column]) * 3
                destination[destinationOffset] = paletteEntries[paletteOffset + 2]
                destination[destinationOffset + 1] = paletteEntries[paletteOffset + 1]
                destination[destinationOffset + 2] = paletteEntries[paletteOffset]
            case 15, 16:
                let sourceOffset = column * 2
                let pixel = UInt16(source[sourceOffset]) | UInt16(source[sourceOffset + 1]) << 8
                let greenBits = sourceBitsPerPixel == 15 ? 5 : 6
                let blue = Int(pixel & 0x001F)
                let green = Int((pixel >> 5) & UInt16((1 << greenBits) - 1))
                let red = Int((pixel >> (5 + greenBits)) & 0x001F)
                destination[destinationOffset] = UInt8((blue * 255 + 15) / 31)
                destination[destinationOffset + 1] = UInt8((green * 255 + ((1 << greenBits) - 1) / 2)
                    / ((1 << greenBits) - 1))
                destination[destinationOffset + 2] = UInt8((red * 255 + 15) / 31)
            case 24:
                let sourceOffset = column * 3
                destination[destinationOffset] = source[sourceOffset]
                destination[destinationOffset + 1] = source[sourceOffset + 1]
                destination[destinationOffset + 2] = source[sourceOffset + 2]
            default:
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            destination[destinationOffset + 3] = 0xFF
        }
    }

    private func makeFrame(frameID: UInt32?) -> RDPGraphicsFrameSnapshot? {
        guard !dirtyRects.isEmpty else {
            return nil
        }

        let destinationRect = RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(width),
            bottom: UInt16(height)
        )
        let frame = RDPGraphicsFrameSnapshot(
            frameID: activeFrameID ?? frameID,
            surfaceID: 0,
            codecID: 0,
            codecName: "surface-bgra",
            pixelFormat: 0x20,
            destinationRect: destinationRect,
            regionRects: dirtyRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: data,
            decodedBitmapBytesPerRow: bytesPerRow
        )
        dirtyRects.removeAll()
        return frame
    }
}
