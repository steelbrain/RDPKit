import Foundation

final class RDPGFXSurfaceCompositor {
    private struct CodecContextKey: Hashable {
        var surfaceID: UInt16
        var codecContextID: UInt32
    }

    private struct OutputMapping {
        var x: UInt32
        var y: UInt32
        var targetWidth: UInt32? = nil
        var targetHeight: UInt32? = nil

        /// The target rectangle of a scaled mapping, or nil for an unscaled one.
        func scaledRect() throws -> RDPFrameRect? {
            guard let targetWidth, let targetHeight else {
                return nil
            }
            guard targetWidth > 0,
                  targetHeight > 0,
                  let right = UInt16(exactly: UInt64(x) + UInt64(targetWidth)),
                  let bottom = UInt16(exactly: UInt64(y) + UInt64(targetHeight))
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return RDPFrameRect(left: UInt16(x), top: UInt16(y), right: right, bottom: bottom)
        }
    }

    /// An offscreen surface (MS-RDPEGFX 3.3.1.6) holding packed BGRA pixels.
    private struct Surface {
        static let maximumDirtyRectCount = 1_024

        var surfaceID: UInt16
        var width: Int
        var height: Int
        var pixelFormat: UInt8
        var data: Data
        var outputMapping: OutputMapping?
        var dirtyRects: [RDPGFXRect16] = []

        var bytesPerRow: Int {
            width * 4
        }

        /// The unscaled output rectangle; nil when unmapped or outside the 16-bit output space.
        var outputRect: RDPFrameRect? {
            guard let outputMapping,
                  let right = UInt16(exactly: UInt64(outputMapping.x) + UInt64(width)),
                  let bottom = UInt16(exactly: UInt64(outputMapping.y) + UInt64(height))
            else {
                return nil
            }
            return RDPFrameRect(left: UInt16(outputMapping.x), top: UInt16(outputMapping.y), right: right, bottom: bottom)
        }

        func contains(x: Int, y: Int, width: Int, height: Int) -> Bool {
            x >= 0 && y >= 0 && width >= 0 && height >= 0 && x + width <= self.width && y + height <= self.height
        }

        /// `rect` clipped to the surface; nil when nothing remains. RDPGFX_RECT16 right and bottom are exclusive.
        func clipped(_ rect: RDPGFXRect16) -> RDPGFXRect16? {
            let right = min(Int(rect.right), width)
            let bottom = min(Int(rect.bottom), height)
            guard right > Int(rect.left), bottom > Int(rect.top) else {
                return nil
            }
            return RDPGFXRect16(left: rect.left, top: rect.top, right: UInt16(right), bottom: UInt16(bottom))
        }

        /// A packed copy of the pixels in `rect`, which must be non-empty and inside the surface.
        func pixels(in rect: RDPGFXRect16) throws -> Data {
            guard clipped(rect) == rect else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let width = Int(rect.width)
            let height = Int(rect.height)
            var pixels = Data(count: width * height * 4)
            copyPixels(
                from: data,
                sourceBytesPerRow: bytesPerRow,
                sourceX: Int(rect.left),
                sourceY: Int(rect.top),
                to: &pixels,
                destinationBytesPerRow: width * 4,
                destinationX: 0,
                destinationY: 0,
                width: width,
                height: height
            )
            return pixels
        }

        /// Copies a `width` x `height` BGRA block at (`sourceX`, `sourceY`) of `source` to (`x`, `y`).
        mutating func write(
            _ source: Data,
            bytesPerRow sourceBytesPerRow: Int,
            sourceX: Int = 0,
            sourceY: Int = 0,
            width: Int,
            height: Int,
            x: Int,
            y: Int
        ) throws {
            guard contains(x: x, y: y, width: width, height: height),
                  sourceX >= 0,
                  sourceY >= 0,
                  sourceBytesPerRow >= (sourceX + width) * 4,
                  source.count >= sourceBytesPerRow * (sourceY + height)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let bytesPerRow = bytesPerRow
            copyPixels(
                from: source,
                sourceBytesPerRow: sourceBytesPerRow,
                sourceX: sourceX,
                sourceY: sourceY,
                to: &data,
                destinationBytesPerRow: bytesPerRow,
                destinationX: x,
                destinationY: y,
                width: width,
                height: height
            )
        }

        /// Fills `rect`, clipped to the surface; the fill alpha applies only to ARGB surfaces.
        mutating func fill(_ rect: RDPGFXRect16, color: RDPGFXColor32) {
            guard let rect = clipped(rect) else {
                return
            }
            let alpha = pixelFormat == RDPGFXPixelFormat.argb8888 ? color.alpha : 0xFF
            let pixel = UInt32(color.blue) | UInt32(color.green) << 8 | UInt32(color.red) << 16 | UInt32(alpha) << 24
            let bytesPerRow = bytesPerRow
            data.withUnsafeMutableBytes { buffer in
                for row in Int(rect.top) ..< Int(rect.bottom) {
                    for column in Int(rect.left) ..< Int(rect.right) {
                        buffer.storeBytes(of: pixel.littleEndian, toByteOffset: row * bytesPerRow + column * 4, as: UInt32.self)
                    }
                }
            }
        }

        /// Replaces the alpha channel of a `width` x `height` block at (`x`, `y`).
        mutating func setAlpha(_ alphaValues: Data, x: Int, y: Int, width: Int, height: Int) throws {
            guard contains(x: x, y: y, width: width, height: height),
                  alphaValues.count == width * height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let bytesPerRow = bytesPerRow
            alphaValues.withUnsafeBytes { alphaBuffer in
                data.withUnsafeMutableBytes { buffer in
                    for row in 0 ..< height {
                        for column in 0 ..< width {
                            buffer[(y + row) * bytesPerRow + (x + column) * 4 + 3] = alphaBuffer[row * width + column]
                        }
                    }
                }
            }
        }

        /// Records a changed area. Past `maximumDirtyRectCount` rectangles the list collapses into its
        /// bounding box, which bounds it for surfaces whose updates are held back.
        mutating func markDirty(_ rect: RDPGFXRect16) {
            guard let rect = clipped(rect) else {
                return
            }
            dirtyRects.append(rect)
            collapseDirtyRectsIfNeeded()
        }

        /// Removes `rect` from the changed area: video wrote it last, and this surface does
        /// not hold decoded video, so its pixels there must not be painted over the video.
        mutating func markWrittenByVideo(_ rect: RDPGFXRect16) {
            var remaining: [RDPGFXRect16] = []
            for dirty in dirtyRects {
                guard dirty.left < rect.right, rect.left < dirty.right, dirty.top < rect.bottom, rect.top < dirty.bottom
                else {
                    remaining.append(dirty)
                    continue
                }
                let top = max(dirty.top, rect.top)
                let bottom = min(dirty.bottom, rect.bottom)
                let pieces = [
                    RDPGFXRect16(left: dirty.left, top: dirty.top, right: dirty.right, bottom: top),
                    RDPGFXRect16(left: dirty.left, top: bottom, right: dirty.right, bottom: dirty.bottom),
                    RDPGFXRect16(left: dirty.left, top: top, right: min(rect.left, dirty.right), bottom: bottom),
                    RDPGFXRect16(left: max(rect.right, dirty.left), top: top, right: dirty.right, bottom: bottom),
                ]
                remaining += pieces.filter { $0.right > $0.left && $0.bottom > $0.top }
            }
            dirtyRects = remaining
            collapseDirtyRectsIfNeeded()
        }

        private mutating func collapseDirtyRectsIfNeeded() {
            guard dirtyRects.count > Self.maximumDirtyRectCount, let first = dirtyRects.first else {
                return
            }
            dirtyRects = [dirtyRects.reduce(first) { bounds, dirtyRect in
                RDPGFXRect16(
                    left: min(bounds.left, dirtyRect.left),
                    top: min(bounds.top, dirtyRect.top),
                    right: max(bounds.right, dirtyRect.right),
                    bottom: max(bounds.bottom, dirtyRect.bottom)
                )
            }]
        }
    }

    private struct CacheEntry {
        var width: Int
        var height: Int
        var data: Data
    }

    private var surfaces: [UInt16: Surface] = [:]
    private var cacheSlots: [UInt16: CacheEntry] = [:]
    private var codecContexts: Set<CodecContextKey> = []
    private var cachedByteCount = 0
    private var graphicsOutputRect: RDPFrameRect?
    private let maximumCacheByteCount: Int
    private static let maximumSurfaceByteCount = 1 << 30
    private let maximumCacheSlot: UInt16
    private let remoteFX = RDPRemoteFXDecoder()

    convenience init(
        capabilitySet: RDPGFXCapabilitySet? = nil,
        outputWidth: UInt16? = nil,
        outputHeight: UInt16? = nil
    ) {
        let usesSmallCache = capabilitySet?.version == RDPGFXCapabilityVersion.version103
            || (capabilitySet?.flags.map {
                $0 & (RDPGFXCapabilityFlags.thinClient | RDPGFXCapabilityFlags.smallCache) != 0
            } ?? false)
        self.init(
            maximumCacheByteCount: usesSmallCache
                ? RDPGFXBitmapCache.smallCacheMaximumByteCount
                : RDPGFXBitmapCache.maximumByteCount,
            maximumCacheSlot: usesSmallCache
                ? RDPGFXCacheSlot.smallCacheMaximumSlot
                : RDPGFXCacheSlot.maximumSlot
        )
        if let outputWidth, let outputHeight {
            graphicsOutputRect = RDPFrameRect(left: 0, top: 0, right: outputWidth, bottom: outputHeight)
        }
    }

    init(maximumCacheByteCount: Int, maximumCacheSlot: UInt16) {
        precondition(maximumCacheByteCount > 0)
        precondition(maximumCacheSlot > 0)
        self.maximumCacheByteCount = maximumCacheByteCount
        self.maximumCacheSlot = maximumCacheSlot
    }

    func process(_ message: RDPGFXHeader, clearCodec: RDPClearCodecDecoder) throws {
        switch message.commandID {
        case RDPGFXCommandID.resetGraphics:
            resetGraphics(try RDPGFXResetGraphicsPDU.parse(from: message))
        case RDPGFXCommandID.createSurface:
            try createSurface(RDPGFXCreateSurfacePDU.parse(from: message))
        case RDPGFXCommandID.deleteSurface:
            try deleteSurface(RDPGFXDeleteSurfacePDU.parse(from: message))
        case RDPGFXCommandID.deleteEncodingContext:
            try deleteEncodingContext(RDPGFXDeleteEncodingContextPDU.parse(from: message))
        case RDPGFXCommandID.mapSurfaceToOutput:
            try mapSurfaceToOutput(RDPGFXMapSurfaceToOutputPDU.parse(from: message))
        case RDPGFXCommandID.mapSurfaceToScaledOutput:
            try mapSurfaceToScaledOutput(RDPGFXMapSurfaceToScaledOutputPDU.parse(from: message))
        case RDPGFXCommandID.wireToSurface1:
            try wireToSurface(RDPGFXWireToSurface1PDU.parse(from: message), clearCodec: clearCodec)
        case RDPGFXCommandID.wireToSurface2:
            try wireToSurface(RDPGFXWireToSurface2PDU.parse(from: message))
        case RDPGFXCommandID.solidFill:
            try solidFill(RDPGFXSolidFillPDU.parse(from: message))
        case RDPGFXCommandID.surfaceToSurface:
            try surfaceToSurface(RDPGFXSurfaceToSurfacePDU.parse(from: message))
        case RDPGFXCommandID.surfaceToCache:
            try surfaceToCache(RDPGFXSurfaceToCachePDU.parse(from: message))
        case RDPGFXCommandID.cacheToSurface:
            try cacheToSurface(RDPGFXCacheToSurfacePDU.parse(from: message))
        case RDPGFXCommandID.evictCacheEntry:
            try evictCacheEntry(RDPGFXEvictCacheEntryPDU.parse(from: message))
        default:
            break
        }
    }

    func makeFrame(frameID: UInt32?) -> RDPGraphicsFrameSnapshot? {
        makeFrames(frameID: frameID).first
    }

    /// Notes that `frame`, a video update or a copy of one, wrote its regions last. The
    /// compositor does not decode video, so those areas leave its dirty rectangles.
    func noteVideo(_ frame: RDPGraphicsFrameSnapshot) {
        guard let index = surfaces.index(forKey: frame.surfaceID) else {
            return
        }
        for region in frame.videoSurfaceRegions {
            surfaces.values[index].markWrittenByVideo(RDPGFXRect16(
                left: region.left,
                top: region.top,
                right: region.right,
                bottom: region.bottom
            ))
        }
    }

    /// Snapshots every mapped surface with dirty rectangles. Unmapped surfaces, and surfaces
    /// outside the output space, keep their dirty rectangles for a later frame. On a surface
    /// that also carries video the snapshot holds only what other codecs drew; its region
    /// rectangles say where, and the decoded video stays everywhere else.
    func makeFrames(frameID: UInt32?) -> [RDPGraphicsFrameSnapshot] {
        var frames: [RDPGraphicsFrameSnapshot] = []
        for surfaceID in surfaces.keys.sorted() {
            guard let surface = surfaces[surfaceID],
                  !surface.dirtyRects.isEmpty,
                  let frame = makeFrame(frameID: frameID, surface: surface)
            else {
                continue
            }
            frames.append(frame)
            surfaces[surfaceID]?.dirtyRects.removeAll()
        }
        return frames
    }

    private func makeFrame(frameID: UInt32?, surface: Surface) -> RDPGraphicsFrameSnapshot? {
        guard let mapping = surface.outputMapping,
              let surfaceRect = surface.outputRect
        else {
            return nil
        }
        let mappedOutputRect: RDPFrameRect?
        do {
            mappedOutputRect = try mapping.scaledRect()
        } catch {
            return nil
        }

        // Unscaled, like video: the decoder scales the surface it composes.
        return RDPGraphicsFrameSnapshot(
            frameID: frameID,
            surfaceID: surface.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            pixelFormat: surface.pixelFormat,
            graphicsOutputRect: graphicsOutputRect,
            surfaceRect: surfaceRect,
            mappedOutputRect: mappedOutputRect,
            destinationRect: surfaceRect,
            regionRects: surface.dirtyRects.map {
                RDPFrameRect(
                    left: surfaceRect.left + $0.left,
                    top: surfaceRect.top + $0.top,
                    right: surfaceRect.left + $0.right,
                    bottom: surfaceRect.top + $0.bottom
                )
            },
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: surface.data,
            decodedBitmapBytesPerRow: surface.bytesPerRow
        )
    }

    var surfaceIDs: [UInt16] {
        surfaces.keys.sorted()
    }

    func surfaceRect(surfaceID: UInt16) -> RDPFrameRect? {
        surfaces[surfaceID]?.outputRect
    }

    func mappedOutputRect(surfaceID: UInt16) -> RDPFrameRect? {
        guard let mapping = surfaces[surfaceID]?.outputMapping else {
            return nil
        }
        return try? mapping.scaledRect()
    }

    func outputRect() -> RDPFrameRect? {
        graphicsOutputRect
    }

    /// Mutates a surface in place; copying it out and back would duplicate its pixels on every write.
    private func modifySurface<Result>(
        _ surfaceID: UInt16,
        _ body: (inout Surface) throws -> Result
    ) throws -> Result {
        guard let index = surfaces.index(forKey: surfaceID) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try body(&surfaces.values[index])
    }

    private func resetGraphics(_ pdu: RDPGFXResetGraphicsPDU) {
        graphicsOutputRect = RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(pdu.width),
            bottom: UInt16(pdu.height)
        )
    }

    private func createSurface(_ pdu: RDPGFXCreateSurfacePDU) throws {
        let byteCount = Int(pdu.width) * Int(pdu.height) * 4
        let allocatedByteCount = surfaces.values.reduce(0) { $0 + $1.data.count }
        // Surface sizes come from the server; bound the memory a server can make us allocate.
        guard surfaces[pdu.surfaceID] == nil,
              allocatedByteCount + byteCount <= Self.maximumSurfaceByteCount
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        surfaces[pdu.surfaceID] = Surface(
            surfaceID: pdu.surfaceID,
            width: Int(pdu.width),
            height: Int(pdu.height),
            pixelFormat: pdu.pixelFormat,
            data: Data(count: byteCount)
        )
    }

    private func deleteSurface(_ pdu: RDPGFXDeleteSurfacePDU) throws {
        guard surfaces.removeValue(forKey: pdu.surfaceID) != nil else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        codecContexts = codecContexts.filter { $0.surfaceID != pdu.surfaceID }
        remoteFX.removeProgressiveState(surfaceID: pdu.surfaceID)
    }

    // Deleting an unknown context is ignored, as FreeRDP does.
    private func deleteEncodingContext(_ pdu: RDPGFXDeleteEncodingContextPDU) {
        codecContexts.remove(CodecContextKey(surfaceID: pdu.surfaceID, codecContextID: pdu.codecContextID))
        remoteFX.removeProgressiveState(
            surfaceID: pdu.surfaceID,
            codecContextID: pdu.codecContextID
        )
    }

    private func mapSurfaceToOutput(_ pdu: RDPGFXMapSurfaceToOutputPDU) throws {
        try modifySurface(pdu.surfaceID) {
            $0.outputMapping = OutputMapping(x: pdu.outputOriginX, y: pdu.outputOriginY)
        }
    }

    private func mapSurfaceToScaledOutput(_ pdu: RDPGFXMapSurfaceToScaledOutputPDU) throws {
        // The decoder allocates the scaled target for every frame; bound it like a surface.
        guard pdu.targetWidth <= RDPGFXResetGraphicsPDU.maximumDimension,
              pdu.targetHeight <= RDPGFXResetGraphicsPDU.maximumDimension,
              Int(pdu.targetWidth) * Int(pdu.targetHeight) * 4 <= Self.maximumSurfaceByteCount
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        try modifySurface(pdu.surfaceID) {
            $0.outputMapping = OutputMapping(
                x: pdu.outputOriginX,
                y: pdu.outputOriginY,
                targetWidth: pdu.targetWidth,
                targetHeight: pdu.targetHeight
            )
        }
    }

    private func wireToSurface(_ pdu: RDPGFXWireToSurface1PDU, clearCodec: RDPClearCodecDecoder) throws {
        let rect = pdu.destinationRect
        let x = Int(rect.left)
        let y = Int(rect.top)
        let width = Int(rect.width)
        let height = Int(rect.height)
        // CAVIDEO tiles are clipped to the surface; every other codec fills destRect exactly, so
        // destRect is validated before decoding sizes any buffer from it.
        guard let containsRect = surfaces[pdu.surfaceID]?.contains(x: x, y: y, width: width, height: height),
              rect.right >= rect.left,
              rect.bottom >= rect.top,
              containsRect || pdu.codecID == RDPGFXCodecID.cavideo
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        switch pdu.codecID {
        case RDPGFXCodecID.uncompressed:
            guard pdu.bitmapData.count == width * height * 4 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            var pixels = pdu.bitmapData
            pixels.withUnsafeMutableBytes { buffer in
                for alphaOffset in stride(from: 3, to: buffer.count, by: 4) {
                    buffer[alphaOffset] = 0xFF
                }
            }
            try modifySurface(pdu.surfaceID) {
                try $0.write(pixels, bytesPerRow: width * 4, width: width, height: height, x: x, y: y)
            }
        case RDPGFXCodecID.planar:
            let pixels = try RDP6BitmapDecoder.decode(pdu.bitmapData, width: width, height: height)
            try modifySurface(pdu.surfaceID) {
                try $0.write(pixels, bytesPerRow: width * 4, width: width, height: height, x: x, y: y)
            }
        case RDPGFXCodecID.clearCodec:
            let destination = try surfaces[pdu.surfaceID]?.pixels(in: rect)
            let bitmap = try clearCodec.decode(pdu.bitmapData, width: width, height: height, destination: destination)
            try modifySurface(pdu.surfaceID) {
                try $0.write(
                    bitmap.bgraData,
                    bytesPerRow: bitmap.bytesPerRow,
                    width: bitmap.width,
                    height: bitmap.height,
                    x: x,
                    y: y
                )
            }
        case RDPGFXCodecID.alpha:
            let alphaStream = try RDPGFXAlphaBitmapStream.parse(from: pdu.bitmapData, pixelCount: width * height)
            try modifySurface(pdu.surfaceID) {
                try $0.setAlpha(alphaStream.alphaValues, x: x, y: y, width: width, height: height)
            }
        case RDPGFXCodecID.cavideo:
            try writeRemoteFXTiles(pdu)
            return
        default:
            // AVC420 and AVC444 bitmaps are decoded from the PDU by the caller.
            return
        }
        surfaces[pdu.surfaceID]?.markDirty(rect)
    }

    private func writeRemoteFXTiles(_ pdu: RDPGFXWireToSurface1PDU) throws {
        let frame = try remoteFX.decode(pdu.bitmapData)
        let originX = Int(pdu.destinationRect.left)
        let originY = Int(pdu.destinationRect.top)
        let clipWidth = Int(pdu.destinationRect.width)
        let clipHeight = Int(pdu.destinationRect.height)
        try modifySurface(pdu.surfaceID) { surface in
            for tile in frame.tiles {
                for region in frame.regionRects {
                    let left = max(tile.x, Int(region.left))
                    let top = max(tile.y, Int(region.top))
                    let right = min(tile.x + 64, Int(region.right), clipWidth, surface.width - originX)
                    let bottom = min(tile.y + 64, Int(region.bottom), clipHeight, surface.height - originY)
                    guard right > left, bottom > top else {
                        continue
                    }
                    let x = originX + left
                    let y = originY + top
                    try surface.write(
                        tile.bgraData,
                        bytesPerRow: tile.bytesPerRow,
                        sourceX: left - tile.x,
                        sourceY: top - tile.y,
                        width: right - left,
                        height: bottom - top,
                        x: x,
                        y: y
                    )
                    surface.markDirty(RDPGFXRect16(
                        left: UInt16(x),
                        top: UInt16(y),
                        right: UInt16(x + right - left),
                        bottom: UInt16(y + bottom - top)
                    ))
                }
            }
        }
    }

    private func wireToSurface(_ pdu: RDPGFXWireToSurface2PDU) throws {
        guard pdu.codecID == RDPGFXCodecID.caProgressive,
              surfaces[pdu.surfaceID] != nil
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let contextKey = CodecContextKey(surfaceID: pdu.surfaceID, codecContextID: pdu.codecContextID)
        let frame = try remoteFX.decodeProgressive(
            pdu.bitmapData,
            surfaceID: pdu.surfaceID,
            codecContextID: pdu.codecContextID,
            permitsUpgrade: codecContexts.contains(contextKey),
            surfaceSize: surfaces[pdu.surfaceID].map { (width: $0.width, height: $0.height) }
        )
        codecContexts.insert(contextKey)
        try modifySurface(pdu.surfaceID) { surface in
            // Tiles may carry pixels outside the region; only the region rects are updated
            // (MS-RDPEGFX 2.2.4.2.1.5). Progressive tiles are in surface coordinates.
            for tile in frame.tiles {
                for region in frame.regionRects {
                    let left = max(tile.x, Int(region.left))
                    let top = max(tile.y, Int(region.top))
                    let right = min(tile.x + 64, Int(region.right), surface.width)
                    let bottom = min(tile.y + 64, Int(region.bottom), surface.height)
                    guard right > left, bottom > top else {
                        continue
                    }
                    try surface.write(
                        tile.bgraData,
                        bytesPerRow: tile.bytesPerRow,
                        sourceX: left - tile.x,
                        sourceY: top - tile.y,
                        width: right - left,
                        height: bottom - top,
                        x: left,
                        y: top
                    )
                }
            }
            for region in frame.regionRects {
                surface.markDirty(RDPGFXRect16(
                    left: region.left,
                    top: region.top,
                    right: region.right,
                    bottom: region.bottom
                ))
            }
        }
    }

    private func solidFill(_ pdu: RDPGFXSolidFillPDU) throws {
        try modifySurface(pdu.surfaceID) { surface in
            for rect in pdu.fillRects {
                surface.fill(rect, color: pdu.fillPixel)
                surface.markDirty(rect)
            }
        }
    }

    private func surfaceToSurface(_ pdu: RDPGFXSurfaceToSurfacePDU) throws {
        guard surfaces[pdu.destinationSurfaceID] != nil,
              let pixels = try surfaces[pdu.sourceSurfaceID]?.pixels(in: pdu.sourceRect)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // `pixels` is a snapshot of the source, so copies within one surface may overlap.
        try copy(
            pixels,
            width: Int(pdu.sourceRect.width),
            height: Int(pdu.sourceRect.height),
            to: pdu.destinationPoints,
            surfaceID: pdu.destinationSurfaceID
        )
    }

    private func surfaceToCache(_ pdu: RDPGFXSurfaceToCachePDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let pixels = try surfaces[pdu.surfaceID]?.pixels(in: pdu.sourceRect)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let replacedByteCount = cacheSlots[pdu.cacheSlot]?.data.count ?? 0
        guard pixels.count <= maximumCacheByteCount,
              cachedByteCount - replacedByteCount <= maximumCacheByteCount - pixels.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        cacheSlots[pdu.cacheSlot] = CacheEntry(
            width: Int(pdu.sourceRect.width),
            height: Int(pdu.sourceRect.height),
            data: pixels
        )
        cachedByteCount += pixels.count - replacedByteCount
    }

    private func cacheToSurface(_ pdu: RDPGFXCacheToSurfacePDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let cacheEntry = cacheSlots[pdu.cacheSlot]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        try copy(
            cacheEntry.data,
            width: cacheEntry.width,
            height: cacheEntry.height,
            to: pdu.destinationPoints,
            surfaceID: pdu.surfaceID
        )
    }

    private func evictCacheEntry(_ pdu: RDPGFXEvictCacheEntryPDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let entry = cacheSlots.removeValue(forKey: pdu.cacheSlot)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        cachedByteCount -= entry.data.count
    }

    /// Copies a packed `width` x `height` BGRA bitmap to each destination point of a surface.
    private func copy(
        _ pixels: Data,
        width: Int,
        height: Int,
        to points: [RDPGFXPoint16],
        surfaceID: UInt16
    ) throws {
        try modifySurface(surfaceID) { surface in
            for point in points {
                let x = Int(point.x)
                let y = Int(point.y)
                try surface.write(pixels, bytesPerRow: width * 4, width: width, height: height, x: x, y: y)
                surface.markDirty(RDPGFXRect16(
                    left: UInt16(x),
                    top: UInt16(y),
                    right: UInt16(x + width),
                    bottom: UInt16(y + height)
                ))
            }
        }
    }
}

/// Copies a `width` x `height` block of 4-byte pixels between row-major buffers.
private func copyPixels(
    from source: Data,
    sourceBytesPerRow: Int,
    sourceX: Int,
    sourceY: Int,
    to destination: inout Data,
    destinationBytesPerRow: Int,
    destinationX: Int,
    destinationY: Int,
    width: Int,
    height: Int
) {
    source.withUnsafeBytes { sourceBuffer in
        destination.withUnsafeMutableBytes { destinationBuffer in
            guard let sourceBase = sourceBuffer.baseAddress,
                  let destinationBase = destinationBuffer.baseAddress
            else {
                return
            }
            for row in 0 ..< height {
                memcpy(
                    destinationBase + (destinationY + row) * destinationBytesPerRow + destinationX * 4,
                    sourceBase + (sourceY + row) * sourceBytesPerRow + sourceX * 4,
                    width * 4
                )
            }
        }
    }
}
