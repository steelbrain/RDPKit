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
    }

    private struct Surface {
        var surfaceID: UInt16
        var width: Int
        var height: Int
        var pixelFormat: UInt8
        var bytesPerRow: Int
        var data: Data
        var outputMapping: OutputMapping?
        var dirtyRects: [RDPGFXRect16] = []
    }

    private struct CacheEntry {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var data: Data
    }

    private var surfaces: [UInt16: Surface] = [:]
    private var cacheSlots: [UInt16: CacheEntry] = [:]
    private var codecContexts: Set<CodecContextKey> = []
    private var cachedByteCount = 0
    private var graphicsOutputRect: RDPFrameRect?
    private let maximumCacheByteCount: Int
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

    func makeFrames(
        frameID: UInt32?,
        excludingSurfaceIDs: Set<UInt16> = []
    ) -> [RDPGraphicsFrameSnapshot] {
        let dirtySurfaceIDs = surfaces.keys.sorted().filter { surfaceID in
            excludingSurfaceIDs.contains(surfaceID) == false
                && surfaces[surfaceID]?.outputMapping != nil
                && surfaces[surfaceID]?.dirtyRects.isEmpty == false
        }
        let frames = dirtySurfaceIDs.compactMap { surfaceID in
            surfaces[surfaceID].flatMap { makeFrame(frameID: frameID, surface: $0) }
        }
        clearDirtyRects()
        return frames
    }

    private func makeFrame(frameID: UInt32?, surface: Surface) -> RDPGraphicsFrameSnapshot? {
        guard let mapping = surface.outputMapping else {
            return nil
        }
        let maximumCoordinate = UInt32(UInt16.max)
        let surfaceWidth = UInt32(surface.width)
        let surfaceHeight = UInt32(surface.height)
        guard surfaceWidth <= maximumCoordinate,
              surfaceHeight <= maximumCoordinate,
              mapping.x <= maximumCoordinate - surfaceWidth,
              mapping.y <= maximumCoordinate - surfaceHeight
        else {
            return nil
        }

        let outputLeft = UInt16(mapping.x)
        let outputTop = UInt16(mapping.y)
        let unscaledSurfaceRect = RDPFrameRect(
            left: outputLeft,
            top: outputTop,
            right: outputLeft + UInt16(surface.width),
            bottom: outputTop + UInt16(surface.height)
        )
        let mappedOutputRect: RDPFrameRect?
        do {
            mappedOutputRect = try scaledOutputRect(mapping, outputLeft: outputLeft, outputTop: outputTop)
        } catch {
            return nil
        }
        let destinationRect = mappedOutputRect ?? unscaledSurfaceRect
        let bitmap: (data: Data, bytesPerRow: Int)
        if let targetWidth = mapping.targetWidth,
           let targetHeight = mapping.targetHeight {
            let targetWidth = Int(targetWidth)
            let targetHeight = Int(targetHeight)
            bitmap = (
                scaleBGRA(
                    surface.data,
                    sourceWidth: surface.width,
                    sourceHeight: surface.height,
                    sourceBytesPerRow: surface.bytesPerRow,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight
                ),
                targetWidth * 4
            )
        } else {
            bitmap = (surface.data, surface.bytesPerRow)
        }
        let regionRects = surface.dirtyRects.map { rect in
            mappedOutputRect.map {
                scaledRegionRect(
                    rect,
                    sourceWidth: surface.width,
                    sourceHeight: surface.height,
                    targetRect: $0
                )
            } ?? RDPFrameRect(
                left: outputLeft + rect.left,
                top: outputTop + rect.top,
                right: outputLeft + rect.right,
                bottom: outputTop + rect.bottom
            )
        }
        return RDPGraphicsFrameSnapshot(
            frameID: frameID,
            surfaceID: surface.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            pixelFormat: surface.pixelFormat,
            graphicsOutputRect: graphicsOutputRect,
            surfaceRect: unscaledSurfaceRect,
            mappedOutputRect: mappedOutputRect,
            destinationRect: destinationRect,
            regionRects: regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: bitmap.data,
            decodedBitmapBytesPerRow: bitmap.bytesPerRow
        )
    }

    func surfaceRect(surfaceID: UInt16) -> RDPFrameRect? {
        guard let surface = surfaces[surfaceID],
              let mapping = surface.outputMapping
        else {
            return nil
        }
        let maximumCoordinate = UInt32(UInt16.max)
        let surfaceWidth = UInt32(surface.width)
        let surfaceHeight = UInt32(surface.height)
        guard surfaceWidth <= maximumCoordinate,
              surfaceHeight <= maximumCoordinate,
              mapping.x <= maximumCoordinate - surfaceWidth,
              mapping.y <= maximumCoordinate - surfaceHeight
        else {
            return nil
        }
        let outputLeft = UInt16(mapping.x)
        let outputTop = UInt16(mapping.y)
        return RDPFrameRect(
            left: outputLeft,
            top: outputTop,
            right: outputLeft + UInt16(surface.width),
            bottom: outputTop + UInt16(surface.height)
        )
    }

    func mappedOutputRect(surfaceID: UInt16) -> RDPFrameRect? {
        guard let surface = surfaces[surfaceID],
              let mapping = surface.outputMapping,
              mapping.x <= UInt32(UInt16.max),
              mapping.y <= UInt32(UInt16.max)
        else {
            return nil
        }
        return try? scaledOutputRect(
            mapping,
            outputLeft: UInt16(mapping.x),
            outputTop: UInt16(mapping.y)
        )
    }

    func outputRect() -> RDPFrameRect? {
        graphicsOutputRect
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
        guard surfaces[pdu.surfaceID] == nil else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let width = Int(pdu.width)
        let height = Int(pdu.height)
        let bytesPerRow = width * 4
        surfaces[pdu.surfaceID] = Surface(
            surfaceID: pdu.surfaceID,
            width: width,
            height: height,
            pixelFormat: pdu.pixelFormat,
            bytesPerRow: bytesPerRow,
            data: Data(repeating: 0, count: bytesPerRow * height)
        )
    }

    private func deleteSurface(_ pdu: RDPGFXDeleteSurfacePDU) throws {
        guard surfaces.removeValue(forKey: pdu.surfaceID) != nil else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        codecContexts = Set(codecContexts.filter { $0.surfaceID != pdu.surfaceID })
        remoteFX.removeProgressiveState(surfaceID: pdu.surfaceID)
    }

    private func deleteEncodingContext(_ pdu: RDPGFXDeleteEncodingContextPDU) throws {
        let key = CodecContextKey(surfaceID: pdu.surfaceID, codecContextID: pdu.codecContextID)
        guard surfaces[pdu.surfaceID] != nil,
              codecContexts.remove(key) != nil
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        remoteFX.removeProgressiveState(
            surfaceID: pdu.surfaceID,
            codecContextID: pdu.codecContextID
        )
    }

    private func mapSurfaceToOutput(_ pdu: RDPGFXMapSurfaceToOutputPDU) throws {
        guard var surface = surfaces[pdu.surfaceID] else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        surface.outputMapping = OutputMapping(x: pdu.outputOriginX, y: pdu.outputOriginY)
        surfaces[pdu.surfaceID] = surface
    }

    private func mapSurfaceToScaledOutput(_ pdu: RDPGFXMapSurfaceToScaledOutputPDU) throws {
        guard var surface = surfaces[pdu.surfaceID] else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        surface.outputMapping = OutputMapping(
            x: pdu.outputOriginX,
            y: pdu.outputOriginY,
            targetWidth: pdu.targetWidth,
            targetHeight: pdu.targetHeight
        )
        surfaces[pdu.surfaceID] = surface
    }

    private func wireToSurface(_ pdu: RDPGFXWireToSurface1PDU, clearCodec: RDPClearCodecDecoder) throws {
        guard let surface = surfaces[pdu.surfaceID],
              pdu.destinationRect.right >= pdu.destinationRect.left,
              pdu.destinationRect.bottom >= pdu.destinationRect.top
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if pdu.codecID == RDPGFXCodecID.avc420
            || pdu.codecID == RDPGFXCodecID.avc444
            || pdu.codecID == RDPGFXCodecID.avc444v2
        {
            guard Int(pdu.destinationRect.left) <= surface.width,
                  Int(pdu.destinationRect.top) <= surface.height,
                  Int(pdu.destinationRect.right) <= surface.width,
                  Int(pdu.destinationRect.bottom) <= surface.height
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        if pdu.codecID == RDPGFXCodecID.alpha {
            let alphaStream = try RDPGFXAlphaBitmapStream.parse(
                from: pdu.bitmapData,
                pixelCount: Int(pdu.destinationRect.width) * Int(pdu.destinationRect.height)
            )
            try updateAlpha(
                alphaStream.alphaValues,
                width: Int(pdu.destinationRect.width),
                height: Int(pdu.destinationRect.height),
                surfaceID: pdu.surfaceID,
                x: Int(pdu.destinationRect.left),
                y: Int(pdu.destinationRect.top)
            )
            markDirty(pdu.destinationRect, surfaceID: pdu.surfaceID)
            return
        }

        if pdu.codecID == RDPGFXCodecID.uncompressed {
            let bitmap = try decodeUncompressedBitmap(pdu)
            try blit(
                bitmap.data,
                sourceBytesPerRow: bitmap.bytesPerRow,
                width: bitmap.width,
                height: bitmap.height,
                to: pdu.surfaceID,
                x: Int(pdu.destinationRect.left),
                y: Int(pdu.destinationRect.top)
            )
            markDirty(pdu.destinationRect, surfaceID: pdu.surfaceID)
            return
        }

        if pdu.codecID == RDPGFXCodecID.planar {
            let width = Int(pdu.destinationRect.width)
            let height = Int(pdu.destinationRect.height)
            let data = try RDP6BitmapDecoder.decode(pdu.bitmapData, width: width, height: height)
            try blit(
                data,
                sourceBytesPerRow: width * 4,
                width: width,
                height: height,
                to: pdu.surfaceID,
                x: Int(pdu.destinationRect.left),
                y: Int(pdu.destinationRect.top)
            )
            markDirty(pdu.destinationRect, surfaceID: pdu.surfaceID)
            return
        }

        if pdu.codecID == RDPGFXCodecID.cavideo {
            let frame = try remoteFX.decode(pdu.bitmapData)
            for tile in frame.tiles {
                for region in frame.regionRects {
                    guard let surface = surfaces[pdu.surfaceID] else {
                        continue
                    }
                    let left = max(tile.x, Int(region.left))
                    let top = max(tile.y, Int(region.top))
                    let right = min(
                        tile.x + 64,
                        Int(region.right),
                        Int(pdu.destinationRect.width),
                        surface.width - Int(pdu.destinationRect.left)
                    )
                    let bottom = min(
                        tile.y + 64,
                        Int(region.bottom),
                        Int(pdu.destinationRect.height),
                        surface.height - Int(pdu.destinationRect.top)
                    )
                    guard right > left, bottom > top else {
                        continue
                    }
                    let x = Int(pdu.destinationRect.left) + left
                    let y = Int(pdu.destinationRect.top) + top
                    try blit(
                        tile.bgraData,
                        sourceBytesPerRow: tile.bytesPerRow,
                        sourceX: left - tile.x,
                        sourceY: top - tile.y,
                        width: right - left,
                        height: bottom - top,
                        to: pdu.surfaceID,
                        x: x,
                        y: y
                    )
                    markDirty(
                        RDPGFXRect16(
                            left: UInt16(x),
                            top: UInt16(y),
                            right: UInt16(x + right - left),
                            bottom: UInt16(y + bottom - top)
                        ),
                        surfaceID: pdu.surfaceID
                    )
                }
            }
            return
        }

        guard pdu.codecID == RDPGFXCodecID.clearCodec else {
            return
        }
        let bitmap = try clearCodec.decode(
            pdu.bitmapData,
            width: Int(pdu.destinationRect.width),
            height: Int(pdu.destinationRect.height)
        )
        try blit(
            bitmap.bgraData,
            sourceBytesPerRow: bitmap.bytesPerRow,
            width: bitmap.width,
            height: bitmap.height,
            to: pdu.surfaceID,
            x: Int(pdu.destinationRect.left),
            y: Int(pdu.destinationRect.top)
        )
        markDirty(pdu.destinationRect, surfaceID: pdu.surfaceID)
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
            permitsUpgrade: codecContexts.contains(contextKey)
        )
        codecContexts.insert(contextKey)
        for tile in frame.tiles {
            let x = tile.x
            let y = tile.y
            guard let surface = surfaces[pdu.surfaceID],
                  x < surface.width,
                  y < surface.height
            else {
                continue
            }
            let width = min(64, surface.width - x)
            let height = min(64, surface.height - y)
            try blit(
                tile.bgraData,
                sourceBytesPerRow: tile.bytesPerRow,
                width: width,
                height: height,
                to: pdu.surfaceID,
                x: x,
                y: y
            )
        }
        guard let surface = surfaces[pdu.surfaceID] else {
            return
        }
        for region in frame.regionRects {
            let rect = RDPGFXRect16(
                left: region.left,
                top: region.top,
                right: region.right,
                bottom: region.bottom
            )
            if let clipped = clipped(rect, width: surface.width, height: surface.height) {
                markDirty(clipped, surfaceID: pdu.surfaceID)
            }
        }
    }

    private func decodeUncompressedBitmap(_ pdu: RDPGFXWireToSurface1PDU) throws -> (
        data: Data,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) {
        let width = Int(pdu.destinationRect.width)
        let height = Int(pdu.destinationRect.height)
        let bytesPerRow = width * 4
        guard pdu.bitmapData.count == bytesPerRow * height else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var data = pdu.bitmapData
        let byteCount = data.count
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            for pixelOffset in stride(from: 3, to: byteCount, by: 4) {
                baseAddress.advanced(by: pixelOffset).assumingMemoryBound(to: UInt8.self).pointee = 0xFF
            }
        }
        return (data, bytesPerRow, width, height)
    }

    private func updateAlpha(
        _ alphaValues: Data,
        width: Int,
        height: Int,
        surfaceID: UInt16,
        x: Int,
        y: Int
    ) throws {
        guard var surface = surfaces[surfaceID],
              width >= 0,
              height >= 0,
              x >= 0,
              y >= 0,
              x + width <= surface.width,
              y + height <= surface.height,
              alphaValues.count == width * height
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        for row in 0 ..< height {
            for column in 0 ..< width {
                let sourceOffset = row * width + column
                let destinationOffset = (y + row) * surface.bytesPerRow + (x + column) * 4 + 3
                surface.data[destinationOffset] = alphaValues[sourceOffset]
            }
        }
        surfaces[surfaceID] = surface
    }

    private func solidFill(_ pdu: RDPGFXSolidFillPDU) throws {
        guard surfaces[pdu.surfaceID] != nil else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for rect in pdu.fillRects {
            try fill(rect, color: pdu.fillPixel, surfaceID: pdu.surfaceID)
            markDirty(rect, surfaceID: pdu.surfaceID)
        }
    }

    private func surfaceToSurface(_ pdu: RDPGFXSurfaceToSurfacePDU) throws {
        guard let sourceSurface = surfaces[pdu.sourceSurfaceID],
              surfaces[pdu.destinationSurfaceID] != nil
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let sourceRect = try containedSourceRect(pdu.sourceRect, width: sourceSurface.width, height: sourceSurface.height)

        let width = Int(sourceRect.width)
        let height = Int(sourceRect.height)
        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
        copy(
            source: sourceSurface.data,
            sourceBytesPerRow: sourceSurface.bytesPerRow,
            sourceX: Int(sourceRect.left),
            sourceY: Int(sourceRect.top),
            destination: &data,
            destinationBytesPerRow: bytesPerRow,
            destinationX: 0,
            destinationY: 0,
            width: width,
            height: height
        )

        for point in pdu.destinationPoints {
            let destinationX = Int(point.x)
            let destinationY = Int(point.y)
            guard destinationX >= 0,
                  destinationY >= 0
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            try blit(
                data,
                sourceBytesPerRow: bytesPerRow,
                width: width,
                height: height,
                to: pdu.destinationSurfaceID,
                x: destinationX,
                y: destinationY
            )
            markDirty(
                RDPGFXRect16(
                    left: UInt16(destinationX),
                    top: UInt16(destinationY),
                    right: UInt16(destinationX + width),
                    bottom: UInt16(destinationY + height)
                ),
                surfaceID: pdu.destinationSurfaceID
            )
        }
    }

    private func surfaceToCache(_ pdu: RDPGFXSurfaceToCachePDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let surface = surfaces[pdu.surfaceID]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let rect = try containedSourceRect(pdu.sourceRect, width: surface.width, height: surface.height)

        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let replacedByteCount = cacheSlots[pdu.cacheSlot]?.data.count ?? 0
        guard byteCount <= maximumCacheByteCount,
              cachedByteCount - replacedByteCount <= maximumCacheByteCount - byteCount
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var data = Data(repeating: 0, count: byteCount)
        copy(
            source: surface.data,
            sourceBytesPerRow: surface.bytesPerRow,
            sourceX: Int(rect.left),
            sourceY: Int(rect.top),
            destination: &data,
            destinationBytesPerRow: bytesPerRow,
            destinationX: 0,
            destinationY: 0,
            width: width,
            height: height
        )
        cacheSlots[pdu.cacheSlot] = CacheEntry(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            data: data
        )
        cachedByteCount += byteCount - replacedByteCount
    }

    private func cacheToSurface(_ pdu: RDPGFXCacheToSurfacePDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let cacheEntry = cacheSlots[pdu.cacheSlot],
              surfaces[pdu.surfaceID] != nil
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for point in pdu.destinationPoints {
            let destinationX = Int(point.x)
            let destinationY = Int(point.y)
            guard destinationX >= 0,
                  destinationY >= 0
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            try blit(
                cacheEntry.data,
                sourceBytesPerRow: cacheEntry.bytesPerRow,
                width: cacheEntry.width,
                height: cacheEntry.height,
                to: pdu.surfaceID,
                x: destinationX,
                y: destinationY
            )
            markDirty(
                RDPGFXRect16(
                    left: UInt16(destinationX),
                    top: UInt16(destinationY),
                    right: UInt16(destinationX + cacheEntry.width),
                    bottom: UInt16(destinationY + cacheEntry.height)
                ),
                surfaceID: pdu.surfaceID
            )
        }
    }

    private func evictCacheEntry(_ pdu: RDPGFXEvictCacheEntryPDU) throws {
        guard pdu.cacheSlot <= maximumCacheSlot,
              let entry = cacheSlots.removeValue(forKey: pdu.cacheSlot)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        cachedByteCount -= entry.data.count
    }

    private func scaledOutputRect(
        _ mapping: OutputMapping,
        outputLeft: UInt16,
        outputTop: UInt16
    ) throws -> RDPFrameRect? {
        guard let targetWidth = mapping.targetWidth,
              let targetHeight = mapping.targetHeight
        else {
            return nil
        }
        guard targetWidth > 0,
              targetHeight > 0,
              targetWidth <= UInt32(UInt16.max),
              targetHeight <= UInt32(UInt16.max),
              mapping.x <= UInt32(UInt16.max) - targetWidth,
              mapping.y <= UInt32(UInt16.max) - targetHeight
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPFrameRect(
            left: outputLeft,
            top: outputTop,
            right: outputLeft + UInt16(targetWidth),
            bottom: outputTop + UInt16(targetHeight)
        )
    }

    private func scaledRegionRect(
        _ rect: RDPGFXRect16,
        sourceWidth: Int,
        sourceHeight: Int,
        targetRect: RDPFrameRect
    ) -> RDPFrameRect {
        let targetWidth = Int(targetRect.width)
        let targetHeight = Int(targetRect.height)
        let left = Int(targetRect.left) + Int(rect.left) * targetWidth / sourceWidth
        let top = Int(targetRect.top) + Int(rect.top) * targetHeight / sourceHeight
        let right = Int(targetRect.left) + (Int(rect.right) * targetWidth + sourceWidth - 1) / sourceWidth
        let bottom = Int(targetRect.top) + (Int(rect.bottom) * targetHeight + sourceHeight - 1) / sourceHeight
        return RDPFrameRect(
            left: UInt16(left),
            top: UInt16(top),
            right: min(targetRect.right, UInt16(right)),
            bottom: min(targetRect.bottom, UInt16(bottom))
        )
    }

    private func scaleBGRA(
        _ source: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceBytesPerRow: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data {
        if sourceWidth == targetWidth,
           sourceHeight == targetHeight {
            return source
        }

        var destination = Data(repeating: 0, count: targetWidth * targetHeight * 4)
        for targetY in 0 ..< targetHeight {
            let sourceY = min(sourceHeight - 1, targetY * sourceHeight / targetHeight)
            for targetX in 0 ..< targetWidth {
                let sourceX = min(sourceWidth - 1, targetX * sourceWidth / targetWidth)
                let sourceOffset = sourceY * sourceBytesPerRow + sourceX * 4
                let destinationOffset = (targetY * targetWidth + targetX) * 4
                destination[destinationOffset] = source[sourceOffset]
                destination[destinationOffset + 1] = source[sourceOffset + 1]
                destination[destinationOffset + 2] = source[sourceOffset + 2]
                destination[destinationOffset + 3] = source[sourceOffset + 3]
            }
        }
        return destination
    }

    private func fill(_ rect: RDPGFXRect16, color: RDPGFXColor32, surfaceID: UInt16) throws {
        guard var surface = surfaces[surfaceID],
              let rect = clipped(rect, width: surface.width, height: surface.height)
        else {
            return
        }
        let alpha = surface.pixelFormat == RDPGFXPixelFormat.argb8888 ? color.alpha : 0xFF

        for row in Int(rect.top) ..< Int(rect.bottom) {
            for column in Int(rect.left) ..< Int(rect.right) {
                let offset = row * surface.bytesPerRow + column * 4
                surface.data[offset] = color.blue
                surface.data[offset + 1] = color.green
                surface.data[offset + 2] = color.red
                surface.data[offset + 3] = alpha
            }
        }
        surfaces[surfaceID] = surface
    }

    private func blit(
        _ source: Data,
        sourceBytesPerRow: Int,
        sourceX: Int = 0,
        sourceY: Int = 0,
        width: Int,
        height: Int,
        to surfaceID: UInt16,
        x: Int,
        y: Int
    ) throws {
        guard var surface = surfaces[surfaceID],
              width >= 0,
              height >= 0,
              sourceX >= 0,
              sourceY >= 0,
              x >= 0,
              y >= 0,
              sourceBytesPerRow >= (sourceX + width) * 4,
              x + width <= surface.width,
              y + height <= surface.height,
              source.count >= sourceBytesPerRow * (sourceY + height)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        copy(
            source: source,
            sourceBytesPerRow: sourceBytesPerRow,
            sourceX: sourceX,
            sourceY: sourceY,
            destination: &surface.data,
            destinationBytesPerRow: surface.bytesPerRow,
            destinationX: x,
            destinationY: y,
            width: width,
            height: height
        )
        surfaces[surfaceID] = surface
    }

    private func copy(
        source: Data,
        sourceBytesPerRow: Int,
        sourceX: Int,
        sourceY: Int,
        destination: inout Data,
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
                    let sourceRow = sourceBase.advanced(by: (sourceY + row) * sourceBytesPerRow + sourceX * 4)
                    let destinationRow = destinationBase.advanced(
                        by: (destinationY + row) * destinationBytesPerRow + destinationX * 4
                    )
                    memcpy(destinationRow, sourceRow, width * 4)
                }
            }
        }
    }

    private func clipped(_ rect: RDPGFXRect16, width: Int, height: Int) -> RDPGFXRect16? {
        let left = min(Int(rect.left), width)
        let top = min(Int(rect.top), height)
        let right = min(Int(rect.right), width)
        let bottom = min(Int(rect.bottom), height)
        guard right > left, bottom > top else {
            return nil
        }
        return RDPGFXRect16(
            left: UInt16(left),
            top: UInt16(top),
            right: UInt16(right),
            bottom: UInt16(bottom)
        )
    }

    private func containedSourceRect(_ rect: RDPGFXRect16, width: Int, height: Int) throws -> RDPGFXRect16 {
        guard let clippedRect = clipped(rect, width: width, height: height),
              clippedRect == rect
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return clippedRect
    }

    private func markDirty(_ rect: RDPGFXRect16, surfaceID: UInt16) {
        guard var surface = surfaces[surfaceID],
              let rect = clipped(rect, width: surface.width, height: surface.height)
        else {
            return
        }
        surface.dirtyRects.append(rect)
        surfaces[surfaceID] = surface
    }

    private func clearDirtyRects() {
        for surfaceID in surfaces.keys {
            surfaces[surfaceID]?.dirtyRects.removeAll()
        }
    }
}
