import Foundation

final class RDPGFXSurfaceCompositor {
    private struct OutputMapping {
        var x: UInt32
        var y: UInt32
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
    private let remoteFX = RDPRemoteFXDecoder()

    func process(_ message: RDPGFXHeader, clearCodec: RDPClearCodecDecoder) throws {
        switch message.commandID {
        case RDPGFXCommandID.resetGraphics:
            surfaces.removeAll()
            cacheSlots.removeAll()
        case RDPGFXCommandID.createSurface:
            try createSurface(RDPGFXCreateSurfacePDU.parse(from: message))
        case RDPGFXCommandID.mapSurfaceToOutput:
            try mapSurfaceToOutput(RDPGFXMapSurfaceToOutputPDU.parse(from: message))
        case RDPGFXCommandID.wireToSurface1:
            try wireToSurface(RDPGFXWireToSurface1PDU.parse(from: message), clearCodec: clearCodec)
        case RDPGFXCommandID.solidFill:
            try solidFill(RDPGFXSolidFillPDU.parse(from: message))
        case RDPGFXCommandID.surfaceToCache:
            try surfaceToCache(RDPGFXSurfaceToCachePDU.parse(from: message))
        case RDPGFXCommandID.cacheToSurface:
            try cacheToSurface(RDPGFXCacheToSurfacePDU.parse(from: message))
        default:
            break
        }
    }

    func makeFrame(frameID: UInt32?) -> RDPGraphicsFrameSnapshot? {
        guard let surfaceID = surfaces.keys.sorted().first(where: { surfaceID in
            surfaces[surfaceID]?.dirtyRects.isEmpty == false
        }),
            let surface = surfaces[surfaceID]
        else {
            return nil
        }

        let mapping = surface.outputMapping ?? OutputMapping(x: 0, y: 0)
        guard mapping.x <= UInt32(UInt16.max),
              mapping.y <= UInt32(UInt16.max),
              mapping.x + UInt32(surface.width) <= UInt32(UInt16.max),
              mapping.y + UInt32(surface.height) <= UInt32(UInt16.max)
        else {
            clearDirtyRects()
            return nil
        }

        let outputLeft = UInt16(mapping.x)
        let outputTop = UInt16(mapping.y)
        let destinationRect = RDPFrameRect(
            left: outputLeft,
            top: outputTop,
            right: outputLeft + UInt16(surface.width),
            bottom: outputTop + UInt16(surface.height)
        )
        let regionRects = surface.dirtyRects.map { rect in
            RDPFrameRect(
                left: outputLeft + rect.left,
                top: outputTop + rect.top,
                right: outputLeft + rect.right,
                bottom: outputTop + rect.bottom
            )
        }
        clearDirtyRects()

        return RDPGraphicsFrameSnapshot(
            frameID: frameID,
            surfaceID: surface.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            pixelFormat: surface.pixelFormat,
            destinationRect: destinationRect,
            regionRects: regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: surface.data,
            decodedBitmapBytesPerRow: surface.bytesPerRow
        )
    }

    private func createSurface(_ pdu: RDPGFXCreateSurfacePDU) {
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

    private func mapSurfaceToOutput(_ pdu: RDPGFXMapSurfaceToOutputPDU) {
        guard var surface = surfaces[pdu.surfaceID] else {
            return
        }
        surface.outputMapping = OutputMapping(x: pdu.outputOriginX, y: pdu.outputOriginY)
        surfaces[pdu.surfaceID] = surface
    }

    private func wireToSurface(_ pdu: RDPGFXWireToSurface1PDU, clearCodec: RDPClearCodecDecoder) throws {
        if pdu.codecID == RDPGFXCodecID.cavideo {
            let frame = try remoteFX.decode(pdu.bitmapData)
            for tile in frame.tiles {
                let x = Int(pdu.destinationRect.left) + tile.x
                let y = Int(pdu.destinationRect.top) + tile.y
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
                markDirty(
                    RDPGFXRect16(
                        left: UInt16(x),
                        top: UInt16(y),
                        right: UInt16(x + width),
                        bottom: UInt16(y + height)
                    ),
                    surfaceID: pdu.surfaceID
                )
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

    private func solidFill(_ pdu: RDPGFXSolidFillPDU) throws {
        guard surfaces[pdu.surfaceID] != nil else {
            return
        }
        for rect in pdu.fillRects {
            try fill(rect, color: pdu.fillPixel, surfaceID: pdu.surfaceID)
            markDirty(rect, surfaceID: pdu.surfaceID)
        }
    }

    private func surfaceToCache(_ pdu: RDPGFXSurfaceToCachePDU) throws {
        guard let surface = surfaces[pdu.surfaceID],
              let rect = clipped(pdu.sourceRect, width: surface.width, height: surface.height)
        else {
            return
        }

        let width = Int(rect.width)
        let height = Int(rect.height)
        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
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
    }

    private func cacheToSurface(_ pdu: RDPGFXCacheToSurfacePDU) throws {
        guard let cacheEntry = cacheSlots[pdu.cacheSlot] else {
            return
        }
        for point in pdu.destinationPoints {
            try blit(
                cacheEntry.data,
                sourceBytesPerRow: cacheEntry.bytesPerRow,
                width: cacheEntry.width,
                height: cacheEntry.height,
                to: pdu.surfaceID,
                x: Int(point.x),
                y: Int(point.y)
            )
            markDirty(
                RDPGFXRect16(
                    left: point.x,
                    top: point.y,
                    right: UInt16(Int(point.x) + cacheEntry.width),
                    bottom: UInt16(Int(point.y) + cacheEntry.height)
                ),
                surfaceID: pdu.surfaceID
            )
        }
    }

    private func fill(_ rect: RDPGFXRect16, color: RDPGFXColor32, surfaceID: UInt16) throws {
        guard var surface = surfaces[surfaceID],
              let rect = clipped(rect, width: surface.width, height: surface.height)
        else {
            return
        }

        for row in Int(rect.top) ..< Int(rect.bottom) {
            for column in Int(rect.left) ..< Int(rect.right) {
                let offset = row * surface.bytesPerRow + column * 4
                surface.data[offset] = color.blue
                surface.data[offset + 1] = color.green
                surface.data[offset + 2] = color.red
                surface.data[offset + 3] = 0xFF
            }
        }
        surfaces[surfaceID] = surface
    }

    private func blit(
        _ source: Data,
        sourceBytesPerRow: Int,
        width: Int,
        height: Int,
        to surfaceID: UInt16,
        x: Int,
        y: Int
    ) throws {
        guard var surface = surfaces[surfaceID],
              width >= 0,
              height >= 0,
              x >= 0,
              y >= 0,
              sourceBytesPerRow >= width * 4,
              x + width <= surface.width,
              y + height <= surface.height,
              source.count >= sourceBytesPerRow * height
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        copy(
            source: source,
            sourceBytesPerRow: sourceBytesPerRow,
            sourceX: 0,
            sourceY: 0,
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
