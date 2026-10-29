import Foundation

final class RDPGFXSurfaceCompositor {
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
        /// Areas the decoder lacks: their pixels are changed here and not yet in a snapshot.
        var dirtyRects: [RDPGFXRect16] = []
        /// Areas whose pixels only the decoder holds: video it decoded, or pixels a copy it
        /// made put there. This surface's own pixels there are stale.
        var decodedRects: [RDPGFXRect16] = []
        /// Whether the decoder holds this surface: it gets the updates of a mapped surface,
        /// and of an unmapped one its copies wrote to.
        var isOnDecoder = false
        /// Whether the decoder has this surface's video stream from a keyframe on.
        var decoderHasVideoStream = false

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

        /// What a copy of `rect` carries, relative to `rect`: the parts only the decoder holds,
        /// and, when the decoder holds this surface and so makes the copy itself, the parts
        /// its copy lacks.
        func copiedState(of rect: RDPGFXRect16) -> (decoded: [RDPGFXRect16], decoderLacks: [RDPGFXRect16]?) {
            let decoded = decodedRects.clipped(to: rect).offsetBy(dx: -Int(rect.left), dy: -Int(rect.top))
            guard isOnDecoder, !decoded.isEmpty else {
                return (decoded, nil)
            }
            return (decoded, dirtyRects.clipped(to: rect).offsetBy(dx: -Int(rect.left), dy: -Int(rect.top)))
        }

        /// Records an area this surface's pixels changed in, listing each pixel once: the
        /// rectangles recorded lose what `rect` covers, or `rect` loses what they cover,
        /// whichever leaves fewer rectangles. Past `maximumDirtyRectCount` rectangles a
        /// list collapses into its bounding box, which bounds it for surfaces whose
        /// updates are held back.
        mutating func markDirty(_ rect: RDPGFXRect16) {
            guard let rect = clipped(rect) else {
                return
            }
            let kept = dirtyRects.filter { !rect.contains($0) }
            var marked = kept + [rect]
            if kept.contains(where: { $0.intersects(rect) }) {
                let cutRect = kept + [rect].subtracting(kept)
                marked = kept.subtracting(rect) + [rect]
                marked = cutRect.count < marked.count ? cutRect : marked
            }
            dirtyRects = marked.collapsed(beyond: Self.maximumDirtyRectCount)
            decodedRects = decodedRects.subtracting(rect)
        }

        /// Records an area video wrote last. Only the decoder holds those pixels, so this
        /// surface's must not be painted over them.
        mutating func markWrittenByVideo(_ rect: RDPGFXRect16) {
            dirtyRects = dirtyRects.subtracting(rect).collapsed(beyond: Self.maximumDirtyRectCount)
            decodedRects = (decodedRects.subtracting(rect) + [rect]).collapsed(beyond: Self.maximumDirtyRectCount)
        }

        /// Records a copy into `rect`, whose `decoded` parts came from areas only the decoder
        /// holds. When the decoder makes the copy too, it lacks only `decoderLacks` of `rect`;
        /// otherwise it lacks everything but `decoded`, which neither side holds then.
        mutating func markCopied(into rect: RDPGFXRect16, decoded: [RDPGFXRect16], decoderLacks: [RDPGFXRect16]?) {
            dirtyRects = (dirtyRects.subtracting(rect) + (decoderLacks ?? [rect].subtracting(decoded)))
                .collapsed(beyond: Self.maximumDirtyRectCount)
            decodedRects = (decodedRects.subtracting(rect) + decoded).collapsed(beyond: Self.maximumDirtyRectCount)
            if decoderLacks != nil {
                isOnDecoder = true
            }
        }
    }

    private struct CacheEntry {
        var width: Int
        var height: Int
        var data: Data
        /// Like a surface's, in entry coordinates.
        var decodedRects: [RDPGFXRect16] = []
        /// When the decoder stored this entry too, the parts its copy lacks.
        var decoderLacks: [RDPGFXRect16]?

        var rect: RDPFrameRect {
            RDPFrameRect(left: 0, top: 0, right: UInt16(width), bottom: UInt16(height))
        }
    }

    private var surfaces: [UInt16: Surface] = [:]
    private var cacheSlots: [UInt16: CacheEntry] = [:]
    /// What each ClearCodec glyph holds beside its pixels, which the ClearCodec decoder keeps:
    /// as for a cache entry, in glyph coordinates.
    private var glyphs: [UInt16: (decoded: [RDPGFXRect16], decoderLacks: [RDPGFXRect16]?)] = [:]
    private var cachedByteCount = 0
    private var evictedDecoderCacheSlots: [UInt16] = []
    private var graphicsOutputRect: RDPFrameRect?
    /// The monitors of the last ResetGraphics, in graphics output coordinates.
    private(set) var monitors: [RDPRemoteMonitor] = []
    private let maximumCacheByteCount: Int
    private static let maximumSurfaceByteCount = 1 << 30
    private let maximumCacheSlot: UInt16
    private let remoteFX = RDPRemoteFXDecoder()
    /// The progressive tiles of each surface decoded in the current RDPGFX frame, by tile
    /// position: a region may rely on tiles an earlier WireToSurface2 of the frame sent
    /// (MS-RDPEGFX 2.2.4.2.1.5).
    private var progressiveFrameTiles: [UInt16: [Int: RDPRemoteFXDecodedTile]] = [:]

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

    /// Applies one RDPGFX PDU. Returns the update the decoder must make itself when the PDU
    /// copies pixels only the decoder holds, or sets their alpha; its frame ID is the
    /// caller's to set.
    @discardableResult
    func process(_ message: RDPGFXHeader, clearCodec: RDPClearCodecDecoder) throws -> RDPGraphicsFrameSnapshot? {
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
            return try wireToSurface(RDPGFXWireToSurface1PDU.parse(from: message), clearCodec: clearCodec)
        case RDPGFXCommandID.wireToSurface2:
            try wireToSurface(RDPGFXWireToSurface2PDU.parse(from: message))
        case RDPGFXCommandID.solidFill:
            try solidFill(RDPGFXSolidFillPDU.parse(from: message))
        case RDPGFXCommandID.surfaceToSurface:
            return try surfaceToSurface(RDPGFXSurfaceToSurfacePDU.parse(from: message))
                .map { decoderCopyFrame($0, codecName: message.typeName) }
        case RDPGFXCommandID.surfaceToCache:
            return try surfaceToCache(RDPGFXSurfaceToCachePDU.parse(from: message))
                .map { decoderCopyFrame($0, codecName: message.typeName) }
        case RDPGFXCommandID.cacheToSurface:
            return try cacheToSurface(RDPGFXCacheToSurfacePDU.parse(from: message))
                .map { decoderCopyFrame($0, codecName: message.typeName) }
        case RDPGFXCommandID.evictCacheEntry:
            try evictCacheEntry(RDPGFXEvictCacheEntryPDU.parse(from: message))
        case RDPGFXCommandID.startFrame, RDPGFXCommandID.endFrame:
            progressiveFrameTiles = [:]
        default:
            break
        }
        return nil
    }

    func makeFrame(frameID: UInt32?) -> RDPGraphicsFrameSnapshot? {
        makeFrames(frameID: frameID).first
    }

    /// Notes that `frame`, a video update, wrote its regions last. The compositor does not
    /// decode video, so only the decoder holds those pixels; when the decoder holds the
    /// surface, it has the surface's video stream from then on.
    func noteVideo(_ frame: RDPGraphicsFrameSnapshot) {
        guard let index = surfaces.index(forKey: frame.surfaceID) else {
            return
        }
        if surfaces.values[index].isOnDecoder {
            surfaces.values[index].decoderHasVideoStream = true
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
            monitors: monitors,
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

    /// The snapshot of a copy the decoder makes; `surfaceID` is the surface it copies into,
    /// or else out of, and its regions are where it writes a surface.
    private func decoderCopyFrame(_ copy: RDPGraphicsSurfaceCopy, codecName: String) -> RDPGraphicsFrameSnapshot {
        let surfaceID: UInt16 = switch (copy.destination, copy.source) {
        case let (.surface(surfaceID), _), let (_, .surface(surfaceID)):
            surfaceID
        default:
            0
        }
        let destinations = copy.destination == .surface(surfaceID) ? copy.blocks.map(\.destination) : []
        return RDPGraphicsFrameSnapshot(
            frameID: nil,
            surfaceID: surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: codecName,
            pixelFormat: RDPGFXPixelFormat.xrgb8888,
            destinationRect: destinations.boundingRect ?? RDPFrameRect(left: 0, top: 0, right: 0, bottom: 0),
            regionRects: destinations,
            encodedVideoData: Data(),
            contentKind: .surfaceCopy,
            surfaceCopy: copy
        )
    }

    var surfaceIDs: [UInt16] {
        surfaces.keys.sorted()
    }

    func isOnDecoder(surfaceID: UInt16) -> Bool {
        surfaces[surfaceID]?.isOnDecoder == true
    }

    /// Whether the decoder takes `frame`, a video update, and notes that it did. An unmapped
    /// surface's video goes to it from a keyframe on: before one it has nothing to decode against.
    func decoderTakesVideo(_ frame: RDPGraphicsFrameSnapshot) -> Bool {
        guard let index = surfaces.index(forKey: frame.surfaceID),
              surfaces.values[index].isOnDecoder,
              Self.decoderCanDecode(frame, on: surfaces.values[index])
        else {
            return false
        }
        surfaces.values[index].decoderHasVideoStream = true
        return true
    }

    /// Whether the decoder drops `frame`, a video update, as it arrives: it holds the
    /// unmapped surface without its video stream, and the update is no keyframe to start
    /// one with. Nothing changes then, here or on the decoder.
    func decoderDropsVideo(_ frame: RDPGraphicsFrameSnapshot) -> Bool {
        guard let surface = surfaces[frame.surfaceID], surface.isOnDecoder else {
            return false
        }
        return !Self.decoderCanDecode(frame, on: surface)
    }

    private static func decoderCanDecode(_ frame: RDPGraphicsFrameSnapshot, on surface: Surface) -> Bool {
        surface.outputMapping != nil || surface.decoderHasVideoStream || frame.isVideoResyncFrame
    }

    /// Cache slots the decoder stored into, which it drops when the cache is.
    var decoderCacheSlots: [UInt16] {
        cacheSlots.filter { $0.value.decoderLacks != nil }.keys.sorted()
    }

    /// Returns and forgets the decoder's cache slots the server evicted or refilled
    /// without it since the last call.
    func takeEvictedDecoderCacheSlots() -> [UInt16] {
        defer {
            evictedDecoderCacheSlots = []
        }
        return evictedDecoderCacheSlots
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
        monitors = pdu.outputMonitors
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
        remoteFX.removeProgressiveState(surfaceID: pdu.surfaceID)
        progressiveFrameTiles[pdu.surfaceID] = nil
    }

    // Deleting an unknown context is ignored, as FreeRDP does.
    private func deleteEncodingContext(_ pdu: RDPGFXDeleteEncodingContextPDU) {
        remoteFX.removeProgressiveState(
            surfaceID: pdu.surfaceID,
            codecContextID: pdu.codecContextID
        )
    }

    private func mapSurfaceToOutput(_ pdu: RDPGFXMapSurfaceToOutputPDU) throws {
        try modifySurface(pdu.surfaceID) {
            $0.outputMapping = OutputMapping(x: pdu.outputOriginX, y: pdu.outputOriginY)
            $0.isOnDecoder = true
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
            $0.isOnDecoder = true
        }
    }

    private func wireToSurface(
        _ pdu: RDPGFXWireToSurface1PDU,
        clearCodec: RDPClearCodecDecoder
    ) throws -> RDPGraphicsFrameSnapshot? {
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
            return try drawClearCodec(pdu, clearCodec: clearCodec)
                .map { decoderCopyFrame($0, codecName: RDPGFXCodecID.name(for: pdu.codecID)) }
        case RDPGFXCodecID.alpha:
            let alphaStream = try RDPGFXAlphaBitmapStream.parse(from: pdu.bitmapData, pixelCount: width * height)
            return try modifySurface(pdu.surfaceID) { surface in
                try surface.setAlpha(alphaStream.alphaValues, x: x, y: y, width: width, height: height)
                // Only the decoder has the colour of pixels video wrote last; it takes their alpha.
                let decoded = surface.decodedRects.clipped(to: rect)
                [rect].subtracting(decoded).forEach { surface.markDirty($0) }
                guard surface.isOnDecoder, !decoded.isEmpty else {
                    return nil
                }
                return RDPGraphicsFrameSnapshot(
                    frameID: nil,
                    surfaceID: pdu.surfaceID,
                    codecID: pdu.codecID,
                    codecName: RDPGFXCodecID.name(for: pdu.codecID),
                    pixelFormat: surface.pixelFormat,
                    destinationRect: RDPFrameRect(rect),
                    regionRects: decoded.map(RDPFrameRect.init),
                    encodedVideoData: Data(),
                    contentKind: .alpha,
                    decodedBitmapData: try surface.pixels(in: rect),
                    decodedBitmapBytesPerRow: width * 4
                )
            }
        case RDPGFXCodecID.cavideo:
            try writeRemoteFXTiles(pdu)
            return nil
        default:
            // AVC420 and AVC444 bitmaps are decoded from the PDU by the caller.
            return nil
        }
        surfaces[pdu.surfaceID]?.markDirty(rect)
        return nil
    }

    /// ClearCodec layers draw over the destination's pixels, which stay wherever no layer
    /// covers them, and a glyph keeps them too. Where only the decoder holds those pixels
    /// this surface's are stale: only what the layers drew is marked, and a glyph holding
    /// such pixels is the decoder's to store and draw, as a cache entry would be.
    private func drawClearCodec(_ pdu: RDPGFXWireToSurface1PDU, clearCodec: RDPClearCodecDecoder) throws -> RDPGraphicsSurfaceCopy? {
        let destination = try surfaces[pdu.surfaceID]?.pixels(in: pdu.destinationRect)
        let bitmap = try clearCodec.decode(
            pdu.bitmapData,
            width: Int(pdu.destinationRect.width),
            height: Int(pdu.destinationRect.height),
            destination: destination
        )
        let x = Int(pdu.destinationRect.left)
        let y = Int(pdu.destinationRect.top)
        let glyphRect = RDPFrameRect(left: 0, top: 0, right: UInt16(bitmap.width), bottom: UInt16(bitmap.height))
        let written = RDPGFXRect16(left: UInt16(x), top: UInt16(y), right: UInt16(x + bitmap.width), bottom: UInt16(y + bitmap.height))
        try modifySurface(pdu.surfaceID) { surface in
            try surface.write(bitmap.bgraData, bytesPerRow: bitmap.bytesPerRow, width: bitmap.width, height: bitmap.height, x: x, y: y)
            if case let .hit(index)? = bitmap.glyph {
                let glyph = glyphs[index]
                surface.markCopied(
                    into: written,
                    decoded: glyph?.decoded.offsetBy(dx: x, dy: y) ?? [],
                    decoderLacks: glyph?.decoderLacks?.offsetBy(dx: x, dy: y)
                )
            } else {
                bitmap.coveredRects.offsetBy(dx: x, dy: y).forEach { surface.markDirty($0) }
            }
        }
        switch bitmap.glyph {
        case let .hit(index)?:
            guard glyphs[index]?.decoderLacks != nil else {
                return nil
            }
            return RDPGraphicsSurfaceCopy(
                source: .clearCodecGlyph(index),
                destination: .surface(pdu.surfaceID),
                blocks: [.init(source: glyphRect, destination: RDPFrameRect(written))]
            )
        case let .stored(index)?:
            let glyph = try modifySurface(pdu.surfaceID) { $0.copiedState(of: written) }
            glyphs[index] = glyph
            guard glyph.decoderLacks != nil else {
                return nil
            }
            return RDPGraphicsSurfaceCopy(
                source: .surface(pdu.surfaceID),
                destination: .clearCodecGlyph(index),
                blocks: [.init(source: RDPFrameRect(written), destination: glyphRect)]
            )
        case nil:
            return nil
        }
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

        let frame = try remoteFX.decodeProgressive(
            pdu.bitmapData,
            surfaceID: pdu.surfaceID,
            codecContextID: pdu.codecContextID,
            surfaceSize: surfaces[pdu.surfaceID].map { (width: $0.width, height: $0.height) }
        )
        var tiles = progressiveFrameTiles[pdu.surfaceID, default: [:]]
        for tile in frame.tiles {
            tiles[(tile.y / 64) << 16 | tile.x / 64] = tile
        }
        progressiveFrameTiles[pdu.surfaceID] = tiles
        try modifySurface(pdu.surfaceID) { surface in
            // Tiles may carry pixels outside the region; only the region rects are updated
            // (MS-RDPEGFX 2.2.4.2.1.5). Progressive tiles are in surface coordinates.
            for region in frame.regionRects {
                let regionRight = min(Int(region.right), surface.width)
                let regionBottom = min(Int(region.bottom), surface.height)
                guard regionRight > Int(region.left), regionBottom > Int(region.top) else {
                    continue
                }
                for yIndex in Int(region.top) / 64 ... (regionBottom - 1) / 64 {
                    for xIndex in Int(region.left) / 64 ... (regionRight - 1) / 64 {
                        guard let tile = tiles[yIndex << 16 | xIndex] else {
                            continue
                        }
                        let left = max(tile.x, Int(region.left))
                        let top = max(tile.y, Int(region.top))
                        try surface.write(
                            tile.bgraData,
                            bytesPerRow: tile.bytesPerRow,
                            sourceX: left - tile.x,
                            sourceY: top - tile.y,
                            width: min(tile.x + 64, regionRight) - left,
                            height: min(tile.y + 64, regionBottom) - top,
                            x: left,
                            y: top
                        )
                    }
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

    private func surfaceToSurface(_ pdu: RDPGFXSurfaceToSurfacePDU) throws -> RDPGraphicsSurfaceCopy? {
        guard surfaces[pdu.destinationSurfaceID] != nil,
              let source = surfaces[pdu.sourceSurfaceID]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // `pixels` is a snapshot of the source, so copies within one surface may overlap.
        let pixels = try source.pixels(in: pdu.sourceRect)
        let (decoded, decoderLacks) = source.copiedState(of: pdu.sourceRect)
        let rects = try copy(
            pixels,
            width: Int(pdu.sourceRect.width),
            height: Int(pdu.sourceRect.height),
            to: pdu.destinationPoints,
            surfaceID: pdu.destinationSurfaceID,
            decoded: decoded,
            decoderLacks: decoderLacks
        )
        guard decoderLacks != nil else {
            return nil
        }
        return RDPGraphicsSurfaceCopy(
            source: .surface(pdu.sourceSurfaceID),
            destination: .surface(pdu.destinationSurfaceID),
            blocks: rects.map { .init(source: RDPFrameRect(pdu.sourceRect), destination: RDPFrameRect($0)) }
        )
    }

    private func surfaceToCache(_ pdu: RDPGFXSurfaceToCachePDU) throws -> RDPGraphicsSurfaceCopy? {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let source = surfaces[pdu.surfaceID]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let pixels = try source.pixels(in: pdu.sourceRect)
        let replaced = cacheSlots[pdu.cacheSlot]
        let replacedByteCount = replaced?.data.count ?? 0
        guard pixels.count <= maximumCacheByteCount,
              cachedByteCount - replacedByteCount <= maximumCacheByteCount - pixels.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let (decoded, decoderLacks) = source.copiedState(of: pdu.sourceRect)
        if replaced?.decoderLacks != nil, decoderLacks == nil {
            evictedDecoderCacheSlots.append(pdu.cacheSlot)
        }
        let entry = CacheEntry(
            width: Int(pdu.sourceRect.width),
            height: Int(pdu.sourceRect.height),
            data: pixels,
            decodedRects: decoded,
            decoderLacks: decoderLacks
        )
        cacheSlots[pdu.cacheSlot] = entry
        cachedByteCount += pixels.count - replacedByteCount
        guard decoderLacks != nil else {
            return nil
        }
        return RDPGraphicsSurfaceCopy(
            source: .surface(pdu.surfaceID),
            destination: .cacheSlot(pdu.cacheSlot),
            blocks: [.init(source: RDPFrameRect(pdu.sourceRect), destination: entry.rect)]
        )
    }

    private func cacheToSurface(_ pdu: RDPGFXCacheToSurfacePDU) throws -> RDPGraphicsSurfaceCopy? {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let entry = cacheSlots[pdu.cacheSlot]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let rects = try copy(
            entry.data,
            width: entry.width,
            height: entry.height,
            to: pdu.destinationPoints,
            surfaceID: pdu.surfaceID,
            decoded: entry.decodedRects,
            decoderLacks: entry.decoderLacks
        )
        guard entry.decoderLacks != nil else {
            return nil
        }
        return RDPGraphicsSurfaceCopy(
            source: .cacheSlot(pdu.cacheSlot),
            destination: .surface(pdu.surfaceID),
            blocks: rects.map { .init(source: entry.rect, destination: RDPFrameRect($0)) }
        )
    }

    private func evictCacheEntry(_ pdu: RDPGFXEvictCacheEntryPDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let entry = cacheSlots.removeValue(forKey: pdu.cacheSlot)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        cachedByteCount -= entry.data.count
        if entry.decoderLacks != nil {
            evictedDecoderCacheSlots.append(pdu.cacheSlot)
        }
    }

    /// Copies a packed `width` x `height` BGRA bitmap to each destination point of a surface
    /// and returns the rectangles written. `decoded` and `decoderLacks` are in bitmap
    /// coordinates, as `Surface.markCopied` takes them. A point outside the surface rejects
    /// the whole copy before anything is written, as the decoder never gets it.
    private func copy(
        _ pixels: Data,
        width: Int,
        height: Int,
        to points: [RDPGFXPoint16],
        surfaceID: UInt16,
        decoded: [RDPGFXRect16],
        decoderLacks: [RDPGFXRect16]?
    ) throws -> [RDPGFXRect16] {
        try modifySurface(surfaceID) { surface in
            let rects = try points.map { point in
                let x = Int(point.x)
                let y = Int(point.y)
                guard surface.contains(x: x, y: y, width: width, height: height) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                return RDPGFXRect16(left: UInt16(x), top: UInt16(y), right: UInt16(x + width), bottom: UInt16(y + height))
            }
            for rect in rects {
                let x = Int(rect.left)
                let y = Int(rect.top)
                try surface.write(pixels, bytesPerRow: width * 4, width: width, height: height, x: x, y: y)
                surface.markCopied(
                    into: rect,
                    decoded: decoded.offsetBy(dx: x, dy: y),
                    decoderLacks: decoderLacks?.offsetBy(dx: x, dy: y)
                )
            }
            return rects
        }
    }
}

private extension RDPGFXRect16 {
    func contains(_ rect: RDPGFXRect16) -> Bool {
        left <= rect.left && top <= rect.top && right >= rect.right && bottom >= rect.bottom
    }

    func intersects(_ rect: RDPGFXRect16) -> Bool {
        left < rect.right && rect.left < right && top < rect.bottom && rect.top < bottom
    }
}

private extension [RDPGFXRect16] {
    /// These rectangles less `rect`; each one it cuts leaves up to four pieces.
    func subtracting(_ rect: RDPGFXRect16) -> [RDPGFXRect16] {
        flatMap { piece -> [RDPGFXRect16] in
            guard piece.intersects(rect) else {
                return [piece]
            }
            let top = Swift.max(piece.top, rect.top)
            let bottom = Swift.min(piece.bottom, rect.bottom)
            return [
                RDPGFXRect16(left: piece.left, top: piece.top, right: piece.right, bottom: top),
                RDPGFXRect16(left: piece.left, top: bottom, right: piece.right, bottom: piece.bottom),
                RDPGFXRect16(left: piece.left, top: top, right: Swift.min(rect.left, piece.right), bottom: bottom),
                RDPGFXRect16(left: Swift.max(rect.right, piece.left), top: top, right: piece.right, bottom: bottom),
            ].filter { $0.right > $0.left && $0.bottom > $0.top }
        }
    }

    func subtracting(_ rects: [RDPGFXRect16]) -> [RDPGFXRect16] {
        rects.reduce(self) { $0.subtracting($1) }
    }

    /// The parts of these rectangles inside `rect`.
    func clipped(to rect: RDPGFXRect16) -> [RDPGFXRect16] {
        compactMap { piece in
            let clipped = RDPGFXRect16(
                left: Swift.max(piece.left, rect.left),
                top: Swift.max(piece.top, rect.top),
                right: Swift.min(piece.right, rect.right),
                bottom: Swift.min(piece.bottom, rect.bottom)
            )
            return clipped.right > clipped.left && clipped.bottom > clipped.top ? clipped : nil
        }
    }

    /// These rectangles moved by (`dx`, `dy`), which must keep them in 16-bit coordinates.
    func offsetBy(dx: Int, dy: Int) -> [RDPGFXRect16] {
        map {
            RDPGFXRect16(
                left: UInt16(Int($0.left) + dx),
                top: UInt16(Int($0.top) + dy),
                right: UInt16(Int($0.right) + dx),
                bottom: UInt16(Int($0.bottom) + dy)
            )
        }
    }

    /// These rectangles, or past `limit` of them their bounding box.
    func collapsed(beyond limit: Int) -> [RDPGFXRect16] {
        guard count > limit, let first else {
            return self
        }
        return [dropFirst().reduce(first) { bounds, rect in
            RDPGFXRect16(
                left: Swift.min(bounds.left, rect.left),
                top: Swift.min(bounds.top, rect.top),
                right: Swift.max(bounds.right, rect.right),
                bottom: Swift.max(bounds.bottom, rect.bottom)
            )
        }]
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
