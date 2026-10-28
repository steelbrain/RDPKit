import Foundation

final class RDPPrimarySurfaceCompositor {
    private static let maximumCompletedFrameIDCount = 256
    private static let maximumDirtyRectCount = 256

    private let width: Int
    private let height: Int
    private var data: Data
    private var palette: [UInt32]?
    private var dirtyRects: [RDPFrameRect] = []
    private var activeFrameID: UInt32?
    private var completedFrameIDs: [UInt32] = []
    private let remoteFX = RDPRemoteFXDecoder()

    private var bytesPerRow: Int {
        width * 4
    }

    init(width: UInt16, height: UInt16) {
        self.width = Int(width)
        self.height = Int(height)
        data = Data(count: Int(width) * Int(height) * 4)
    }

    /// Applies the commands in order. A surface bits command that fails to
    /// decode is skipped so later frame markers still end their frames (each
    /// needs its acknowledgement); the first error is thrown afterwards, and
    /// the changes it would have delivered go into the next snapshot.
    func process(_ commands: [RDPSurfaceCommand]) throws -> [RDPGraphicsFrameSnapshot] {
        var frames: [RDPGraphicsFrameSnapshot] = []
        var firstError: Error?
        for command in commands {
            switch command {
            case .setSurfaceBits(let bits),
                 .streamSurfaceBits(let bits):
                do {
                    try blit(bits)
                } catch {
                    firstError = firstError ?? error
                }
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
                    if completedFrameIDs.count == Self.maximumCompletedFrameIDCount {
                        completedFrameIDs.removeFirst()
                    }
                    completedFrameIDs.append(marker.frameID)
                }
            }
        }
        if let firstError {
            dirtyRects = frames.flatMap(\.regionRects) + dirtyRects
            if dirtyRects.count > Self.maximumDirtyRectCount {
                dirtyRects = [RDPFrameRect(left: 0, top: 0, right: UInt16(width), bottom: UInt16(height))]
            }
            throw firstError
        }
        if activeFrameID == nil,
           let frame = makeFrame(frameID: nil)
        {
            frames.append(frame)
        }
        return frames
    }

    /// Returns and forgets the IDs of frames whose end marker (TS_FRAME_MARKER, MS-RDPBCGR
    /// 2.2.9.2.3) has been processed, including frames that changed no pixels and so produced no
    /// snapshot. Each needs a TS_FRAME_ACKNOWLEDGE_PDU (MS-RDPRFX 2.2.3.3); only the most recent
    /// `maximumCompletedFrameIDCount` are kept between calls.
    func takeCompletedFrameIDs() -> [UInt32] {
        defer { completedFrameIDs.removeAll() }
        return completedFrameIDs
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

    /// Keeps the TS_PALETTE_ENTRY (red, green, blue) colors as BGRA pixels for 8 bpp bitmaps.
    func updatePalette(_ update: RDPPaletteUpdate) {
        let entries = [UInt8](update.entries)
        palette = stride(from: 0, to: entries.count - 2, by: 3).map {
            UInt32(entries[$0 + 2]) | UInt32(entries[$0 + 1]) << 8 | UInt32(entries[$0]) << 16 | 0xFF00_0000
        }
    }

    private func blit(_ command: RDPSurfaceBitsCommand) throws {
        let bitmap = command.bitmapData
        let x = Int(command.destinationLeft)
        let y = Int(command.destinationTop)
        let width = Int(bitmap.width)
        let height = Int(bitmap.height)
        // RemoteFX tiles are clipped to the desktop; the other codecs fill the bitmap rectangle,
        // which is validated before decoding sizes a buffer from it.
        guard bitmap.codecID == 3 || (x + width <= self.width && y + height <= self.height) else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        switch bitmap.codecID {
        case 0:
            let bitsPerPixel = Int(bitmap.bitsPerPixel)
            let sourceBytesPerRow = try alignedBytesPerRow(width: width, bitsPerPixel: bitsPerPixel)
            guard bitmap.bitmapData.count == sourceBytesPerRow * height else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            try paint(bitmap.bitmapData, bitsPerPixel: bitsPerPixel, x: x, y: y, width: width, height: height) {
                $0 * sourceBytesPerRow
            }
        case 1:
            let decoded = try RDPNSCodecDecoder.decode(bitmap.bitmapData, width: width, height: height)
            try paint(decoded, bitsPerPixel: 32, x: x, y: y, width: width, height: height) {
                $0 * width * 4
            }
        case 3:
            try paintRemoteFXTiles(bitmap.bitmapData, command: command)
        default:
            return
        }
    }

    private func paintRemoteFXTiles(_ encoded: Data, command: RDPSurfaceBitsCommand) throws {
        let frame: RDPRemoteFXDecodedFrame
        do {
            frame = try remoteFX.decode(encoded)
        } catch {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        let originX = Int(command.destinationLeft)
        let originY = Int(command.destinationTop)
        for tile in frame.tiles {
            for region in frame.regionRects {
                let left = max(tile.x, Int(region.left))
                let top = max(tile.y, Int(region.top))
                let right = min(tile.x + 64, Int(region.right), Int(command.bitmapData.width), width - originX)
                let bottom = min(tile.y + 64, Int(region.bottom), Int(command.bitmapData.height), height - originY)
                guard right > left, bottom > top else {
                    continue
                }
                try paint(
                    tile.bgraData,
                    bitsPerPixel: 32,
                    x: originX + left,
                    y: originY + top,
                    width: right - left,
                    height: bottom - top
                ) {
                    (top - tile.y + $0) * tile.bytesPerRow + (left - tile.x) * 4
                }
            }
        }
    }

    private func blit(_ rectangle: RDPBitmapUpdateRectangle) throws {
        let sourceWidth = Int(rectangle.width)
        let sourceHeight = Int(rectangle.height)
        let bitsPerPixel = Int(rectangle.bitsPerPixel)
        let x = Int(rectangle.destinationLeft)
        let y = Int(rectangle.destinationTop)
        // destRight and destBottom are inclusive, and the bitmap may be larger than the destination:
        // Windows and xrdp pad its width to a multiple of four pixels (the TS_CD_HEADER cbScanWidth
        // rule). As in rdesktop and FreeRDP, only the top-left destination area is painted. The
        // bitmap itself must still fit the desktop (its width rounded up to four pixels).
        let width = Int(rectangle.destinationRight) - x + 1
        let height = Int(rectangle.destinationBottom) - y + 1
        guard sourceWidth >= width,
              sourceHeight >= height,
              sourceWidth <= (self.width + 3) & ~3,
              sourceHeight <= self.height,
              x + width <= self.width,
              y + height <= self.height
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let sourceData: Data
        let sourceBytesPerRow: Int
        if rectangle.isCompressed {
            if bitsPerPixel == 32 {
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
                    bitsPerPixel: bitsPerPixel
                )
            }
            sourceBytesPerRow = try sourceWidth * bytesPerPixel(for: bitsPerPixel)
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
            sourceBytesPerRow = try alignedBytesPerRow(width: sourceWidth, bitsPerPixel: bitsPerPixel)
        }
        guard sourceData.count == sourceBytesPerRow * sourceHeight else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        // Bitmap update rows are stored bottom-up (MS-RDPBCGR 2.2.9.1.1.3.1.2.2).
        try paint(sourceData, bitsPerPixel: bitsPerPixel, x: x, y: y, width: width, height: height) {
            (sourceHeight - 1 - $0) * sourceBytesPerRow
        }
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

    private func alignedBytesPerRow(width: Int, bitsPerPixel: Int) throws -> Int {
        let bytesPerRow = try width * bytesPerPixel(for: bitsPerPixel)
        return (bytesPerRow + 3) & ~3
    }

    /// Converts `width` x `height` source pixels to BGRA at (`x`, `y`) and marks the area dirty.
    /// Source row `row` starts at byte offset `sourceRowOffset(row)` of `source`.
    private func paint(
        _ source: Data,
        bitsPerPixel: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        sourceRowOffset: (Int) -> Int
    ) throws {
        let sourceRowByteCount = try width * bytesPerPixel(for: bitsPerPixel)
        let sourceRowOffsets = (0 ..< max(0, height)).map(sourceRowOffset)
        guard x >= 0,
              y >= 0,
              width >= 0,
              height >= 0,
              x + width <= self.width,
              y + height <= self.height,
              sourceRowOffsets.allSatisfy({ $0 >= 0 && $0 + sourceRowByteCount <= source.count })
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let palette = palette
        let bytesPerRow = bytesPerRow
        try source.withUnsafeBytes { sourceBuffer in
            try data.withUnsafeMutableBytes { destinationBuffer in
                for (row, sourceOffset) in sourceRowOffsets.enumerated() {
                    let destinationOffset = (y + row) * bytesPerRow + x * 4
                    try Self.convertRow(
                        UnsafeRawBufferPointer(
                            rebasing: sourceBuffer[sourceOffset ..< sourceOffset + sourceRowByteCount]
                        ),
                        to: UnsafeMutableRawBufferPointer(
                            rebasing: destinationBuffer[destinationOffset ..< destinationOffset + width * 4]
                        ),
                        width: width,
                        bitsPerPixel: bitsPerPixel,
                        palette: palette
                    )
                }
            }
        }
        dirtyRects.append(RDPFrameRect(
            left: UInt16(x),
            top: UInt16(y),
            right: UInt16(x + width),
            bottom: UInt16(y + height)
        ))
    }

    private static func convertRow(
        _ source: UnsafeRawBufferPointer,
        to destination: UnsafeMutableRawBufferPointer,
        width: Int,
        bitsPerPixel: Int,
        palette: [UInt32]?
    ) throws {
        switch bitsPerPixel {
        case 32:
            destination.copyMemory(from: source)
        case 24:
            for column in 0 ..< width {
                destination[column * 4] = source[column * 3]
                destination[column * 4 + 1] = source[column * 3 + 1]
                destination[column * 4 + 2] = source[column * 3 + 2]
                destination[column * 4 + 3] = 0xFF
            }
        case 15, 16:
            let greenBitCount = bitsPerPixel == 15 ? 5 : 6
            let greenMaximum = (1 << greenBitCount) - 1
            for column in 0 ..< width {
                let pixel = Int(source[column * 2]) | Int(source[column * 2 + 1]) << 8
                let blue = pixel & 0x1F
                let green = (pixel >> 5) & greenMaximum
                let red = (pixel >> (5 + greenBitCount)) & 0x1F
                destination[column * 4] = UInt8((blue * 255 + 15) / 31)
                destination[column * 4 + 1] = UInt8((green * 255 + greenMaximum / 2) / greenMaximum)
                destination[column * 4 + 2] = UInt8((red * 255 + 15) / 31)
                destination[column * 4 + 3] = 0xFF
            }
        case 8:
            guard let palette, palette.count == 256 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            for column in 0 ..< width {
                destination.storeBytes(
                    of: palette[Int(source[column])].littleEndian,
                    toByteOffset: column * 4,
                    as: UInt32.self
                )
            }
        default:
            throw RDPDecodeError.invalidGraphicsUpdatePDU
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
