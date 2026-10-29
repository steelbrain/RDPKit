import CoreImage
import CoreVideo
import Foundation

public struct RDPDecodedFramePresentation: @unchecked Sendable {
    public var frame: RDPGraphicsFrameSnapshot
    /// The decoded picture. Coded video can be larger than `frame`: only its top-left
    /// `frame.width` x `frame.height` is shown.
    public var imageBuffer: CVImageBuffer

    public init(frame: RDPGraphicsFrameSnapshot, imageBuffer: CVImageBuffer) {
        self.frame = frame
        self.imageBuffer = imageBuffer
    }
}

public struct RDPFrameDecodeTiming: Sendable {
    public var samplePreparationMilliseconds: Double
    public var videoToolboxMilliseconds: Double
    public var imageConversionMilliseconds: Double
    public var totalMilliseconds: Double
    public var decodedPixelFormat: UInt32?
    public var usesHardwareAcceleration: Bool?

    public init(
        samplePreparationMilliseconds: Double,
        videoToolboxMilliseconds: Double,
        imageConversionMilliseconds: Double,
        totalMilliseconds: Double,
        decodedPixelFormat: UInt32?,
        usesHardwareAcceleration: Bool?
    ) {
        self.samplePreparationMilliseconds = samplePreparationMilliseconds
        self.videoToolboxMilliseconds = videoToolboxMilliseconds
        self.imageConversionMilliseconds = imageConversionMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.decodedPixelFormat = decodedPixelFormat
        self.usesHardwareAcceleration = usesHardwareAcceleration
    }
}

public enum RDPFrameDecodeCompletion: Equatable, Sendable {
    case decoded
    case failed(errorDescription: String)
    case cancelled

    public func requireDecoded() throws {
        switch self {
        case .decoded:
            return
        case .failed(let errorDescription):
            throw RDPFrameDecodeQueueError.decodeFailed(errorDescription)
        case .cancelled:
            throw RDPFrameDecodeQueueError.cancelled
        }
    }
}

public enum RDPFrameDecodeQueueError: Error, Equatable, CustomStringConvertible, Sendable {
    case decodeFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .decodeFailed(let errorDescription):
            return "frame decode failed: \(errorDescription)"
        case .cancelled:
            return "frame decode was cancelled before updating the graphics output"
        }
    }
}

private final class RDPFrameDecodeCompletionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: RDPFrameDecodeCompletion?

    func store(_ completion: RDPFrameDecodeCompletion) {
        lock.withLock {
            self.completion = completion
        }
    }

    func load() -> RDPFrameDecodeCompletion? {
        lock.withLock { completion }
    }
}

final class RDPDecodedVideoSurfaceCompositor {
    private struct Surface {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var data: Data
    }

    private struct DirectSurface {
        var width: Int
        var height: Int
        var outputRect: RDPFrameRect
        var imageBuffer: CVImageBuffer
    }

    private var surfaces: [UInt16: Surface] = [:]
    private var directSurfaces: [UInt16: DirectSurface] = [:]
    private var chromaEnhancedAVC444Surfaces = Set<UInt16>()
    /// Surfaces holding pixels other codecs drew beside their video, as in Windows mixed
    /// mode. Their decoded video is valid only inside each update's regions.
    private var surfacesWithBitmapContent = Set<UInt16>()
    /// Cache entries and ClearCodec glyphs the session's surface copies stored here.
    private var storedBlocks: [RDPGraphicsSurfaceCopy.Location: Surface] = [:]
    private var graphicsOutput: Surface?
    private let imageConverter = RDPDecodedImageBufferConverter()
    private let pixelBufferPool = RDPBGRAPixelBufferPool()

    /// Composes `frame` and returns what the graphics output shows; nil for video of a
    /// surface not mapped to it, which only later copies out of the surface bring there.
    func presentation(
        for frame: RDPGraphicsFrameSnapshot,
        decodedImageBuffer: CVImageBuffer
    ) throws -> RDPDecodedFramePresentation? {
        forgetDeletedState(before: frame)
        guard frame.contentKind == .video else {
            if let outputRect = frame.graphicsOutputRect {
                try materializeDirectGraphicsOutputIfNeeded(
                    outputRect: outputRect,
                    excludingSurfaceID: frame.surfaceID
                )
            }
            let bitmap = bitmapSurface(from: frame)
            if frame.graphicsOutputRect != nil, let bitmap, let surfaceRect = frame.surfaceRect {
                try materializeDirectSurface(surfaceID: frame.surfaceID)
                let surface = merge(bitmap, regionRects: frame.regionRects, surfaceRect: surfaceRect, into: frame.surfaceID)
                surfacesWithBitmapContent.insert(frame.surfaceID)
                guard let mappedOutputRect = frame.mappedOutputRect else {
                    return try graphicsOutputPresentation(from: frame, displayedSurface: surface)
                }
                var scaledFrame = frame
                scaledFrame.destinationRect = mappedOutputRect
                scaledFrame.regionRects = frame.regionRects.map {
                    scaledOutputRegionRect($0, sourceRect: surfaceRect, targetRect: mappedOutputRect)
                }
                return try graphicsOutputPresentation(
                    from: scaledFrame,
                    displayedSurface: scaledSurface(
                        surface,
                        width: Int(mappedOutputRect.width),
                        height: Int(mappedOutputRect.height)
                    )
                )
            }
            directSurfaces[frame.surfaceID] = nil
            surfaces[frame.surfaceID] = frame.mappedOutputRect == nil ? bitmap : nil
            if frame.graphicsOutputRect != nil, let bitmap {
                return try graphicsOutputPresentation(from: frame, displayedSurface: bitmap)
            }
            return RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedImageBuffer)
        }

        let updateRect = frame.destinationRect
        let isUnmapped = frame.graphicsOutputRect != nil && frame.surfaceRect == nil
        // An unmapped surface is as large as what this compositor holds of it.
        let heldSurface = isUnmapped ? surfaces[frame.surfaceID] : nil
        let requestedSurfaceRect = frame.surfaceRect ?? inferredSurfaceRect(
            from: updateRect,
            minimumWidth: heldSurface?.width ?? 0,
            minimumHeight: heldSurface?.height ?? 0
        )
        let surfaceWidth = Int(requestedSurfaceRect.width)
        let surfaceHeight = Int(requestedSurfaceRect.height)
        guard surfaceWidth > 0, surfaceHeight > 0 else {
            return RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedImageBuffer)
        }

        let surfaceRect = frame.surfaceRect ?? RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(clamping: surfaceWidth),
            bottom: UInt16(clamping: surfaceHeight)
        )
        if updateCoversSurface(frame, surfaceRect: surfaceRect) {
            surfacesWithBitmapContent.remove(frame.surfaceID)
        }
        let canPresentDirectly = !isUnmapped && canPresentDirectly(frame, surfaceRect: surfaceRect)
        recordAVC444ChromaUpdate(frame)
        if canPresentDirectly,
           let presentation = directPresentation(
            for: frame,
            decodedImageBuffer: decodedImageBuffer,
            surfaceRect: surfaceRect
        ) {
            surfaces[frame.surfaceID] = nil
            directSurfaces[frame.surfaceID] = DirectSurface(
                width: surfaceWidth,
                height: surfaceHeight,
                outputRect: surfaceRect,
                imageBuffer: decodedImageBuffer
            )
            graphicsOutput = nil
            return presentation
        }

        try materializeDirectSurface(surfaceID: frame.surfaceID)
        let copyRegions = videoCopyRegions(
            updateRect: updateRect,
            regionRects: frame.regionRects + frame.auxiliaryRegionRects,
            relative: frame.hasRelativeRegions,
            sourceWidth: CVPixelBufferGetWidth(decodedImageBuffer),
            sourceHeight: CVPixelBufferGetHeight(decodedImageBuffer),
            surfaceWidth: max(surfaceWidth, surfaces[frame.surfaceID]?.width ?? 0),
            surfaceHeight: max(surfaceHeight, surfaces[frame.surfaceID]?.height ?? 0)
        )
        // Only the part of the picture the regions copy is converted.
        let source = try copyRegions.sourceBounds.map { try imageConverter.bgraData(from: decodedImageBuffer, in: $0) }
        var surface = takeSurface(for: frame.surfaceID, width: surfaceWidth, height: surfaceHeight)
        if let source {
            for region in copyRegions {
                copy(
                    source: source.data,
                    sourceBytesPerRow: source.bytesPerRow,
                    destination: &surface.data,
                    destinationBytesPerRow: surface.bytesPerRow,
                    sourceX: region.sourceX - source.x,
                    sourceY: region.sourceY - source.y,
                    destinationX: region.destinationX,
                    destinationY: region.destinationY,
                    width: region.width,
                    height: region.height
                )
            }
        }
        surfaces[frame.surfaceID] = surface
        guard !isUnmapped else {
            return nil
        }
        return try presentation(from: frame, surface: surface, surfaceRect: surfaceRect)
    }

    /// Applies an update the session made of this compositor's own pixels: a
    /// ``RDPGraphicsSurfaceCopy``, or alpha for its decoded pixels. Returns the presentation
    /// of a mapped surface it changed, and nil for anything else, or when it reads pixels
    /// this compositor never got.
    func presentation(applying frame: RDPGraphicsFrameSnapshot) throws -> RDPDecodedFramePresentation? {
        forgetDeletedState(before: frame)
        switch frame.contentKind {
        case .surfaceCopy:
            return try makeCopy(frame)
        case .alpha:
            return try setAlpha(frame)
        case .video, .bitmap:
            return nil
        }
    }

    private func makeCopy(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPDecodedFramePresentation? {
        guard let surfaceCopy = frame.surfaceCopy else {
            return nil
        }
        // Every block copies the source as it was before the copy.
        var blocks: [(pixels: Surface, destination: RDPFrameRect)] = []
        for block in surfaceCopy.blocks {
            guard let pixels = try pixels(of: surfaceCopy.source, in: block.source) else {
                return nil
            }
            blocks.append((pixels, block.destination))
        }
        guard case let .surface(surfaceID) = surfaceCopy.destination else {
            storedBlocks[surfaceCopy.destination] = blocks.last?.pixels
            return nil
        }
        return try presentation(of: frame, changing: surfaceID, in: blocks.map(\.destination)) { surface in
            for (pixels, destination) in blocks {
                copy(
                    source: pixels.data,
                    sourceBytesPerRow: pixels.bytesPerRow,
                    destination: &surface.data,
                    destinationBytesPerRow: surface.bytesPerRow,
                    sourceX: 0,
                    sourceY: 0,
                    destinationX: Int(destination.left),
                    destinationY: Int(destination.top),
                    width: min(pixels.width, Int(destination.width)),
                    height: min(pixels.height, Int(destination.height))
                )
            }
        }
    }

    private func setAlpha(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPDecodedFramePresentation? {
        guard let alpha = bitmapSurface(from: frame),
              surfaces[frame.surfaceID] != nil || directSurfaces[frame.surfaceID] != nil
        else {
            return nil
        }
        let rect = frame.destinationRect
        return try presentation(of: frame, changing: frame.surfaceID, in: frame.regionRects) { surface in
            let bytesPerRow = surface.bytesPerRow
            let surfaceWidth = surface.width
            let surfaceHeight = surface.height
            surface.data.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                alpha.data.withUnsafeBytes { (alphaPixels: UnsafeRawBufferPointer) in
                    for region in frame.regionRects {
                        let left = max(Int(region.left), Int(rect.left))
                        let top = max(Int(region.top), Int(rect.top))
                        let right = min(Int(region.right), Int(rect.right), surfaceWidth)
                        let bottom = min(Int(region.bottom), Int(rect.bottom), surfaceHeight)
                        for y in top ..< max(top, bottom) {
                            for x in left ..< max(left, right) {
                                pixels[y * bytesPerRow + x * 4 + 3] = alphaPixels[
                                    (y - Int(rect.top)) * alpha.bytesPerRow + (x - Int(rect.left)) * 4 + 3
                                ]
                            }
                        }
                    }
                }
            }
        }
    }

    /// Changes the surface's pixels in `regions`, in surface coordinates, and keeps the
    /// pixels this compositor holds everywhere else; presents the surface when it is mapped.
    private func presentation(
        of frame: RDPGraphicsFrameSnapshot,
        changing surfaceID: UInt16,
        in regions: [RDPFrameRect],
        _ change: (inout Surface) -> Void
    ) throws -> RDPDecodedFramePresentation? {
        if let outputRect = frame.graphicsOutputRect, frame.surfaceRect != nil {
            try materializeDirectGraphicsOutputIfNeeded(outputRect: outputRect, excludingSurfaceID: surfaceID)
        }
        try materializeDirectSurface(surfaceID: surfaceID)
        var surface = takeSurface(
            for: surfaceID,
            width: regions.map { Int($0.right) }.reduce(Int(frame.surfaceRect?.width ?? 0), max),
            height: regions.map { Int($0.bottom) }.reduce(Int(frame.surfaceRect?.height ?? 0), max)
        )
        change(&surface)
        surfaces[surfaceID] = surface
        surfacesWithBitmapContent.insert(surfaceID)
        guard frame.graphicsOutputRect != nil, let surfaceRect = frame.surfaceRect else {
            return nil
        }
        var changed = frame
        changed.destinationRect = RDPFrameRect(left: 0, top: 0, right: surfaceRect.width, bottom: surfaceRect.height)
        changed.regionRects = regions
        return try presentation(from: changed, surface: surface, surfaceRect: surfaceRect)
    }

    func forgetDeletedState(before frame: RDPGraphicsFrameSnapshot) {
        for surfaceID in frame.deletedSurfaceIDs {
            surfaces[surfaceID] = nil
            directSurfaces[surfaceID] = nil
            chromaEnhancedAVC444Surfaces.remove(surfaceID)
            surfacesWithBitmapContent.remove(surfaceID)
        }
        for slot in frame.evictedCacheSlots {
            storedBlocks[.cacheSlot(slot)] = nil
        }
    }

    /// A copy of `rect` of a surface or stored block, or nil when this compositor never got it.
    private func pixels(of location: RDPGraphicsSurfaceCopy.Location, in rect: RDPFrameRect) throws -> Surface? {
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = Surface(width: width, height: height, bytesPerRow: width * 4, data: Data(count: width * height * 4))
        switch location {
        case .cacheSlot, .clearCodecGlyph:
            guard let entry = storedBlocks[location] else {
                return nil
            }
            copyBlock(of: entry, in: rect, to: &pixels)
        case let .surface(surfaceID):
            if let directSurface = directSurfaces[surfaceID] {
                let bounds = CGRect(x: Int(rect.left), y: Int(rect.top), width: width, height: height)
                    .intersection(CGRect(
                        x: 0,
                        y: 0,
                        width: CVPixelBufferGetWidth(directSurface.imageBuffer),
                        height: CVPixelBufferGetHeight(directSurface.imageBuffer)
                    ))
                guard !bounds.isEmpty else {
                    return pixels
                }
                let converted = try imageConverter.bgraData(from: directSurface.imageBuffer, in: bounds)
                copyBlock(
                    of: Surface(width: converted.width, height: converted.height, bytesPerRow: converted.bytesPerRow, data: converted.data),
                    in: RDPFrameRect(left: 0, top: 0, right: UInt16(converted.width), bottom: UInt16(converted.height)),
                    to: &pixels
                )
            } else if let surface = surfaces[surfaceID] {
                copyBlock(of: surface, in: rect, to: &pixels)
            } else {
                return nil
            }
        }
        return pixels
    }

    /// Copies the part of `rect` inside `source` to `destination`'s origin.
    private func copyBlock(of source: Surface, in rect: RDPFrameRect, to destination: inout Surface) {
        let width = min(Int(rect.right), source.width) - Int(rect.left)
        let height = min(Int(rect.bottom), source.height) - Int(rect.top)
        guard width > 0, height > 0 else {
            return
        }
        copy(
            source: source.data,
            sourceBytesPerRow: source.bytesPerRow,
            destination: &destination.data,
            destinationBytesPerRow: destination.bytesPerRow,
            sourceX: Int(rect.left),
            sourceY: Int(rect.top),
            destinationX: 0,
            destinationY: 0,
            width: min(width, destination.width),
            height: min(height, destination.height)
        )
    }

    private func canPresentDirectly(
        _ frame: RDPGraphicsFrameSnapshot,
        surfaceRect: RDPFrameRect
    ) -> Bool {
        // The whole decoded picture would cover what other codecs drew outside the regions.
        guard !surfacesWithBitmapContent.contains(frame.surfaceID) else {
            return false
        }
        guard frame.codecID == RDPGFXCodecID.avc444 || frame.codecID == RDPGFXCodecID.avc444v2 else {
            return true
        }
        switch frame.avc444SubframeLayout {
        case .yuv420Only:
            return chromaEnhancedAVC444Surfaces.contains(frame.surfaceID) == false
                || regionsCoverSurface(frame.regionRects, frame: frame, surfaceRect: surfaceRect)
        case .yuv420AndChroma420:
            return regionsCoverSurface(frame.regionRects, frame: frame, surfaceRect: surfaceRect)
                || regionsCoverSurface(frame.auxiliaryRegionRects, frame: frame, surfaceRect: surfaceRect)
        case .chroma420Only:
            return regionsCoverSurface(frame.regionRects, frame: frame, surfaceRect: surfaceRect)
        case nil:
            return false
        }
    }

    /// Whether the update writes the whole surface; no regions means its whole update rectangle.
    private func updateCoversSurface(_ frame: RDPGraphicsFrameSnapshot, surfaceRect: RDPFrameRect) -> Bool {
        let regions = frame.regionRects + frame.auxiliaryRegionRects
        guard !regions.isEmpty else {
            return frame.destinationRect.left == 0
                && frame.destinationRect.top == 0
                && frame.destinationRect.width >= surfaceRect.width
                && frame.destinationRect.height >= surfaceRect.height
        }
        return regionsCoverSurface(regions, frame: frame, surfaceRect: surfaceRect)
    }

    /// Copies `bitmap`'s pixels inside `regionRects` (output coordinates) into the surface and
    /// keeps its decoded video everywhere else. A surface with no pixels yet takes the bitmap.
    private func merge(
        _ bitmap: Surface,
        regionRects: [RDPFrameRect],
        surfaceRect: RDPFrameRect,
        into surfaceID: UInt16
    ) -> Surface {
        guard surfaces[surfaceID] != nil else {
            surfaces[surfaceID] = bitmap
            return bitmap
        }
        var surface = takeSurface(for: surfaceID, width: bitmap.width, height: bitmap.height)
        for region in regionRects {
            let left = max(Int(region.left) - Int(surfaceRect.left), 0)
            let top = max(Int(region.top) - Int(surfaceRect.top), 0)
            let right = min(Int(region.right) - Int(surfaceRect.left), bitmap.width)
            let bottom = min(Int(region.bottom) - Int(surfaceRect.top), bitmap.height)
            guard right > left, bottom > top else {
                continue
            }
            copy(
                source: bitmap.data,
                sourceBytesPerRow: bitmap.bytesPerRow,
                destination: &surface.data,
                destinationBytesPerRow: surface.bytesPerRow,
                sourceX: left,
                sourceY: top,
                destinationX: left,
                destinationY: top,
                width: right - left,
                height: bottom - top
            )
        }
        surfaces[surfaceID] = surface
        return surface
    }

    private func regionsCoverSurface(
        _ regions: [RDPFrameRect],
        frame: RDPGraphicsFrameSnapshot,
        surfaceRect: RDPFrameRect
    ) -> Bool {
        let relative = frame.hasRelativeRegions
        return regions.contains {
            outputRegionRect($0, updateRect: frame.destinationRect, relative: relative, surfaceRect: surfaceRect) == surfaceRect
        }
    }

    private func recordAVC444ChromaUpdate(_ frame: RDPGraphicsFrameSnapshot) {
        let hasChromaUpdate = switch frame.avc444SubframeLayout {
        case .yuv420AndChroma420:
            frame.auxiliaryRegionRects.isEmpty == false
        case .chroma420Only:
            frame.regionRects.isEmpty == false
        case .yuv420Only, nil:
            false
        }
        if hasChromaUpdate {
            chromaEnhancedAVC444Surfaces.insert(frame.surfaceID)
        }
    }

    private func directPresentation(
        for frame: RDPGraphicsFrameSnapshot,
        decodedImageBuffer: CVImageBuffer,
        surfaceRect: RDPFrameRect
    ) -> RDPDecodedFramePresentation? {
        guard let outputRect = frame.graphicsOutputRect,
              surfaceRect == outputRect,
              frame.mappedOutputRect == nil || frame.mappedOutputRect == surfaceRect,
              frame.destinationRect.left == 0,
              frame.destinationRect.top == 0,
              frame.destinationRect.width == surfaceRect.width,
              frame.destinationRect.height == surfaceRect.height,
              CVPixelBufferGetWidth(decodedImageBuffer) >= Int(surfaceRect.width),
              CVPixelBufferGetHeight(decodedImageBuffer) >= Int(surfaceRect.height)
        else {
            return nil
        }

        var outputFrame = frame
        outputFrame.surfaceRect = outputRect
        outputFrame.destinationRect = outputRect
        let relative = frame.hasRelativeRegions
        let regionRects = (frame.regionRects + frame.auxiliaryRegionRects).compactMap {
            outputRegionRect($0, updateRect: frame.destinationRect, relative: relative, surfaceRect: surfaceRect)
        }
        outputFrame.regionRects = regionRects.isEmpty ? [outputRect] : regionRects
        outputFrame.auxiliaryRegionRects = []
        return RDPDecodedFramePresentation(frame: outputFrame, imageBuffer: decodedImageBuffer)
    }

    private func materializeDirectSurface(surfaceID: UInt16) throws {
        guard let directSurface = directSurfaces.removeValue(forKey: surfaceID) else {
            return
        }
        let source = try imageConverter.bgraData(from: directSurface.imageBuffer)
        var surface = takeSurface(
            for: surfaceID,
            width: directSurface.width,
            height: directSurface.height
        )
        copy(
            source: source.data,
            sourceBytesPerRow: source.bytesPerRow,
            destination: &surface.data,
            destinationBytesPerRow: surface.bytesPerRow,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: min(source.width, surface.width),
            height: min(source.height, surface.height)
        )
        surfaces[surfaceID] = surface
    }

    private func materializeDirectGraphicsOutputIfNeeded(
        outputRect: RDPFrameRect,
        excludingSurfaceID: UInt16
    ) throws {
        guard graphicsOutput == nil,
              let entry = directSurfaces.first(where: {
                  $0.key != excludingSurfaceID && $0.value.outputRect == outputRect
              })
        else {
            return
        }
        try materializeDirectSurface(surfaceID: entry.key)
        graphicsOutput = surfaces[entry.key]
    }

    /// The surface, grown to at least `width` x `height`, taken out of `surfaces`: the caller
    /// owns its pixels and stores it back, so writing to them copies none of the rest.
    private func takeSurface(for surfaceID: UInt16, width: Int, height: Int) -> Surface {
        let existing = surfaces.removeValue(forKey: surfaceID)
        if let existing,
           existing.width >= width,
           existing.height >= height
        {
            return existing
        }

        let nextWidth = max(width, existing?.width ?? 0)
        let nextHeight = max(height, existing?.height ?? 0)
        let bytesPerRow = nextWidth * 4
        var surface = Surface(
            width: nextWidth,
            height: nextHeight,
            bytesPerRow: bytesPerRow,
            data: Data(repeating: 0, count: bytesPerRow * nextHeight)
        )

        if let existing {
            copy(
                source: existing.data,
                sourceBytesPerRow: existing.bytesPerRow,
                destination: &surface.data,
                destinationBytesPerRow: surface.bytesPerRow,
                sourceX: 0,
                sourceY: 0,
                destinationX: 0,
                destinationY: 0,
                width: existing.width,
                height: existing.height
            )
        }
        return surface
    }

    private func composedFrame(
        from frame: RDPGraphicsFrameSnapshot,
        displayedSurface: Surface,
        surfaceRect: RDPFrameRect
    ) -> RDPGraphicsFrameSnapshot {
        let destinationRect = frame.mappedOutputRect ?? surfaceRect
        let relative = frame.hasRelativeRegions
        var regionRects = (frame.regionRects + frame.auxiliaryRegionRects).compactMap {
            outputRegionRect($0, updateRect: frame.destinationRect, relative: relative, surfaceRect: surfaceRect)
        }
        if let mappedOutputRect = frame.mappedOutputRect {
            regionRects = regionRects.map {
                scaledOutputRegionRect($0, sourceRect: surfaceRect, targetRect: mappedOutputRect)
            }
        }
        return RDPGraphicsFrameSnapshot(
            frameID: frame.frameID,
            surfaceID: frame.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            videoCodec: frame.videoCodec,
            pixelFormat: frame.pixelFormat,
            graphicsOutputRect: frame.graphicsOutputRect,
            monitors: frame.monitors,
            surfaceRect: surfaceRect,
            mappedOutputRect: frame.mappedOutputRect,
            destinationRect: destinationRect,
            regionRects: regionRects.isEmpty ? [destinationRect] : regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap
        )
    }

    private func presentation(
        from frame: RDPGraphicsFrameSnapshot,
        surface: Surface,
        surfaceRect: RDPFrameRect
    ) throws -> RDPDecodedFramePresentation {
        let destinationRect = frame.mappedOutputRect ?? surfaceRect
        let displayedSurface = scaledSurface(
            surface,
            width: Int(destinationRect.width),
            height: Int(destinationRect.height)
        )
        let frame = composedFrame(from: frame, displayedSurface: displayedSurface, surfaceRect: surfaceRect)
        return try graphicsOutputPresentation(from: frame, displayedSurface: displayedSurface)
    }

    private func graphicsOutputPresentation(
        from frame: RDPGraphicsFrameSnapshot,
        displayedSurface: Surface
    ) throws -> RDPDecodedFramePresentation {
        guard let outputRect = frame.graphicsOutputRect else {
            return RDPDecodedFramePresentation(
                frame: frame,
                imageBuffer: try makePixelBuffer(surface: displayedSurface)
            )
        }
        let outputWidth = Int(outputRect.width)
        let outputHeight = Int(outputRect.height)
        guard outputWidth > 0, outputHeight > 0 else {
            throw RDPBitmapFrameDecodeError.invalidBitmapLayout
        }

        var output = takeGraphicsOutput(width: outputWidth, height: outputHeight)
        blit(displayedSurface, destinationRect: frame.destinationRect, to: &output)
        graphicsOutput = output

        let regionRects = frame.regionRects.compactMap { clippedOutputRect($0, outputRect: outputRect) }
        let outputFrame = RDPGraphicsFrameSnapshot(
            frameID: frame.frameID,
            surfaceID: frame.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "graphics-output-bgra",
            videoCodec: frame.videoCodec,
            pixelFormat: frame.pixelFormat,
            graphicsOutputRect: outputRect,
            monitors: frame.monitors,
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: regionRects.isEmpty ? [outputRect] : regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap
        )
        // The pixels go out only in the image buffer: a frame holding the output's
        // pixels too would make the next blit copy all of them first.
        return RDPDecodedFramePresentation(
            frame: outputFrame,
            imageBuffer: try makePixelBuffer(surface: output)
        )
    }

    /// The graphics output, taken like a surface so the blit writes in place; a new, black
    /// one when its size changed.
    private func takeGraphicsOutput(width: Int, height: Int) -> Surface {
        defer {
            graphicsOutput = nil
        }
        if let graphicsOutput, graphicsOutput.width == width, graphicsOutput.height == height {
            return graphicsOutput
        }
        return Surface(width: width, height: height, bytesPerRow: width * 4, data: Data(count: width * height * 4))
    }

    private func bitmapSurface(from frame: RDPGraphicsFrameSnapshot) -> Surface? {
        guard let data = frame.decodedBitmapData,
              let bytesPerRow = frame.decodedBitmapBytesPerRow,
              frame.width > 0,
              frame.height > 0,
              bytesPerRow >= Int(frame.width) * 4,
              data.count >= bytesPerRow * Int(frame.height)
        else {
            return nil
        }
        return Surface(
            width: Int(frame.width),
            height: Int(frame.height),
            bytesPerRow: bytesPerRow,
            data: data
        )
    }

    private func blit(_ source: Surface, destinationRect: RDPFrameRect, to output: inout Surface) {
        let destinationX = Int(destinationRect.left)
        let destinationY = Int(destinationRect.top)
        guard destinationX < output.width, destinationY < output.height else {
            return
        }
        let width = min(source.width, output.width - destinationX)
        let height = min(source.height, output.height - destinationY)
        guard width > 0, height > 0 else {
            return
        }
        copy(
            source: source.data,
            sourceBytesPerRow: source.bytesPerRow,
            destination: &output.data,
            destinationBytesPerRow: output.bytesPerRow,
            sourceX: 0,
            sourceY: 0,
            destinationX: destinationX,
            destinationY: destinationY,
            width: width,
            height: height
        )
    }

    private func scaledSurface(_ surface: Surface, width: Int, height: Int) -> Surface {
        guard width > 0,
              height > 0,
              width != surface.width || height != surface.height
        else {
            return surface
        }
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        surface.data.withUnsafeBytes { sourceBuffer in
            data.withUnsafeMutableBytes { destinationBuffer in
                guard let source = sourceBuffer.baseAddress,
                      let destination = destinationBuffer.baseAddress
                else {
                    return
                }
                for targetY in 0 ..< height {
                    let sourceY = min(surface.height - 1, targetY * surface.height / height)
                    let sourceRow = source.advanced(by: sourceY * surface.bytesPerRow)
                    let targetRow = destination.advanced(by: targetY * bytesPerRow)
                    for targetX in 0 ..< width {
                        let sourceX = min(surface.width - 1, targetX * surface.width / width)
                        targetRow.advanced(by: targetX * 4).copyMemory(
                            from: sourceRow.advanced(by: sourceX * 4),
                            byteCount: 4
                        )
                    }
                }
            }
        }
        return Surface(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    private func makePixelBuffer(surface: Surface) throws -> CVPixelBuffer {
        try rdpMakeBGRAPixelBuffer(
            width: surface.width,
            height: surface.height,
            copying: surface.data,
            bytesPerRow: surface.bytesPerRow,
            pool: pixelBufferPool
        )
    }
}

private struct RDPVideoCopyRegion {
    var sourceX: Int
    var sourceY: Int
    var destinationX: Int
    var destinationY: Int
    var width: Int
    var height: Int
}

private extension [RDPVideoCopyRegion] {
    /// The smallest block of the decoded picture holding every region's source.
    var sourceBounds: CGRect? {
        guard let first else {
            return nil
        }
        return dropFirst().reduce(CGRect(x: first.sourceX, y: first.sourceY, width: first.width, height: first.height)) {
            $0.union(CGRect(x: $1.sourceX, y: $1.sourceY, width: $1.width, height: $1.height))
        }
    }
}

private func inferredSurfaceRect(from updateRect: RDPFrameRect, minimumWidth: Int, minimumHeight: Int) -> RDPFrameRect {
    RDPFrameRect(
        left: 0,
        top: 0,
        right: max(updateRect.right, updateRect.width, UInt16(clamping: minimumWidth)),
        bottom: max(updateRect.bottom, updateRect.height, UInt16(clamping: minimumHeight))
    )
}

/// `relative` says whether `regionRects` are relative to `updateRect` or in surface
/// coordinates (``RDPGraphicsFrameSnapshot/hasRelativeRegions``).
private func videoCopyRegions(
    updateRect: RDPFrameRect,
    regionRects: [RDPFrameRect],
    relative: Bool,
    sourceWidth: Int,
    sourceHeight: Int,
    surfaceWidth: Int,
    surfaceHeight: Int
) -> [RDPVideoCopyRegion] {
    let regions = regionRects.isEmpty
        ? [RDPFrameRect(left: 0, top: 0, right: updateRect.width, bottom: updateRect.height)]
        : regionRects
    return regions.compactMap { region in
        let sourceLeft: Int
        let sourceTop: Int
        let destinationLeft: Int
        let destinationTop: Int
        if relative || regionRects.isEmpty {
            sourceLeft = Int(region.left)
            sourceTop = Int(region.top)
            destinationLeft = Int(updateRect.left) + sourceLeft
            destinationTop = Int(updateRect.top) + sourceTop
        } else {
            sourceLeft = Int(region.left) - Int(updateRect.left)
            sourceTop = Int(region.top) - Int(updateRect.top)
            destinationLeft = Int(region.left)
            destinationTop = Int(region.top)
        }

        return clippedVideoCopyRegion(
            sourceLeft: sourceLeft,
            sourceTop: sourceTop,
            destinationLeft: destinationLeft,
            destinationTop: destinationTop,
            width: Int(region.width),
            height: Int(region.height),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight
        )
    }
}

private func clippedVideoCopyRegion(
    sourceLeft: Int,
    sourceTop: Int,
    destinationLeft: Int,
    destinationTop: Int,
    width: Int,
    height: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    surfaceWidth: Int,
    surfaceHeight: Int
) -> RDPVideoCopyRegion? {
    let shiftX = max(0, -sourceLeft, -destinationLeft)
    let shiftY = max(0, -sourceTop, -destinationTop)
    let sourceX = sourceLeft + shiftX
    let sourceY = sourceTop + shiftY
    let destinationX = destinationLeft + shiftX
    let destinationY = destinationTop + shiftY
    let clippedWidth = min(
        width - shiftX,
        sourceWidth - sourceX,
        surfaceWidth - destinationX
    )
    let clippedHeight = min(
        height - shiftY,
        sourceHeight - sourceY,
        surfaceHeight - destinationY
    )
    guard clippedWidth > 0, clippedHeight > 0 else {
        return nil
    }
    return RDPVideoCopyRegion(
        sourceX: sourceX,
        sourceY: sourceY,
        destinationX: destinationX,
        destinationY: destinationY,
        width: clippedWidth,
        height: clippedHeight
    )
}

private func outputRegionRect(
    _ region: RDPFrameRect,
    updateRect: RDPFrameRect,
    relative: Bool,
    surfaceRect: RDPFrameRect
) -> RDPFrameRect? {
    let outputLeft = relative
        ? Int(surfaceRect.left) + Int(updateRect.left) + Int(region.left)
        : Int(surfaceRect.left) + Int(region.left)
    let outputTop = relative
        ? Int(surfaceRect.top) + Int(updateRect.top) + Int(region.top)
        : Int(surfaceRect.top) + Int(region.top)
    let outputRight = outputLeft + Int(region.width)
    let outputBottom = outputTop + Int(region.height)
    let clippedLeft = min(max(outputLeft, Int(surfaceRect.left)), Int(surfaceRect.right))
    let clippedTop = min(max(outputTop, Int(surfaceRect.top)), Int(surfaceRect.bottom))
    let clippedRight = min(max(outputRight, Int(surfaceRect.left)), Int(surfaceRect.right))
    let clippedBottom = min(max(outputBottom, Int(surfaceRect.top)), Int(surfaceRect.bottom))
    guard clippedRight > clippedLeft, clippedBottom > clippedTop else {
        return nil
    }
    return RDPFrameRect(
        left: UInt16(clippedLeft),
        top: UInt16(clippedTop),
        right: UInt16(clippedRight),
        bottom: UInt16(clippedBottom)
    )
}

private func scaledOutputRegionRect(
    _ rect: RDPFrameRect,
    sourceRect: RDPFrameRect,
    targetRect: RDPFrameRect
) -> RDPFrameRect {
    let sourceWidth = Int(sourceRect.width)
    let sourceHeight = Int(sourceRect.height)
    let targetWidth = Int(targetRect.width)
    let targetHeight = Int(targetRect.height)
    let relativeLeft = Int(rect.left) - Int(sourceRect.left)
    let relativeTop = Int(rect.top) - Int(sourceRect.top)
    let relativeRight = Int(rect.right) - Int(sourceRect.left)
    let relativeBottom = Int(rect.bottom) - Int(sourceRect.top)
    return RDPFrameRect(
        left: UInt16(Int(targetRect.left) + relativeLeft * targetWidth / sourceWidth),
        top: UInt16(Int(targetRect.top) + relativeTop * targetHeight / sourceHeight),
        right: min(
            targetRect.right,
            UInt16(Int(targetRect.left) + (relativeRight * targetWidth + sourceWidth - 1) / sourceWidth)
        ),
        bottom: min(
            targetRect.bottom,
            UInt16(Int(targetRect.top) + (relativeBottom * targetHeight + sourceHeight - 1) / sourceHeight)
        )
    )
}

private func clippedOutputRect(_ rect: RDPFrameRect, outputRect: RDPFrameRect) -> RDPFrameRect? {
    let left = max(rect.left, outputRect.left)
    let top = max(rect.top, outputRect.top)
    let right = min(rect.right, outputRect.right)
    let bottom = min(rect.bottom, outputRect.bottom)
    guard right > left, bottom > top else {
        return nil
    }
    return RDPFrameRect(left: left, top: top, right: right, bottom: bottom)
}

/// Converted pixels of a decoded picture's `width` x `height` block at (`x`, `y`).
private struct RDPDecodedBGRAImage {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var data: Data
}

private final class RDPDecodedImageBufferConverter {
    private let ciContext = CIContext()
    /// Reused between pictures; allocating a frame's worth of pixels costs more than filling them.
    private var pixels = Data()

    /// The pixels of `imageBuffer` inside `bounds` (top-left origin, the whole picture by
    /// default) as packed BGRA rows. They are valid until the next call.
    func bgraData(from imageBuffer: CVImageBuffer, in bounds: CGRect? = nil) throws -> RDPDecodedBGRAImage {
        let pictureWidth = CVPixelBufferGetWidth(imageBuffer)
        let pictureHeight = CVPixelBufferGetHeight(imageBuffer)
        let bounds = bounds ?? CGRect(x: 0, y: 0, width: pictureWidth, height: pictureHeight)
        let x = Int(bounds.minX)
        let y = Int(bounds.minY)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0, x >= 0, y >= 0, x + width <= pictureWidth, y + height <= pictureHeight else {
            throw RDPBitmapFrameDecodeError.invalidBitmapLayout
        }
        let bytesPerRow = width * 4
        if pixels.count < bytesPerRow * height {
            pixels = Data(count: bytesPerRow * height)
        }

        if CVPixelBufferGetPixelFormatType(imageBuffer) == kCVPixelFormatType_32BGRA {
            try copyBGRARows(from: imageBuffer, x: x, y: y, width: width, height: height)
        } else {
            pixels.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return
                }
                // Core Image puts the origin at the bottom left.
                ciContext.render(
                    CIImage(cvImageBuffer: imageBuffer),
                    toBitmap: baseAddress,
                    rowBytes: bytesPerRow,
                    bounds: CGRect(x: x, y: pictureHeight - y - height, width: width, height: height),
                    format: .BGRA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
            }
        }
        return RDPDecodedBGRAImage(x: x, y: y, width: width, height: height, bytesPerRow: bytesPerRow, data: pixels)
    }

    private func copyBGRARows(from imageBuffer: CVImageBuffer, x: Int, y: Int, width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        }
        guard let source = CVPixelBufferGetBaseAddress(imageBuffer) else {
            throw RDPBitmapFrameDecodeError.missingBaseAddress
        }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        pixels.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else {
                return
            }
            for row in 0 ..< height {
                memcpy(
                    destination.advanced(by: row * width * 4),
                    source.advanced(by: (y + row) * sourceBytesPerRow + x * 4),
                    width * 4
                )
            }
        }
    }
}

private func copy(
    source: Data,
    sourceBytesPerRow: Int,
    destination: inout Data,
    destinationBytesPerRow: Int,
    sourceX: Int,
    sourceY: Int,
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

/// Decodes and composes graphics frames in arrival order on a background queue.
/// `submitAndWait` returns once the frame has been presented, so callers can acknowledge
/// frames (MS-RDPEGFX RDPGFX_FRAME_ACKNOWLEDGE_PDU) only after they were decoded.
public final class RDPFrameDecodeQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RDPKit.FrameDecode", qos: .userInitiated)
    // The decoder and compositor are only used on `queue`.
    private let decoder = RDPVideoToolboxFrameDecoder()
    private let videoCompositor = RDPDecodedVideoSurfaceCompositor()
    private let lock = NSLock()
    private var isCancelled = false
    private let shouldCancel: () -> Bool
    private let onDecoded: (
        RDPDecodedFramePresentation,
        Date,
        Date,
        RDPFrameDecodeTiming
    ) -> Void
    private let onDecodeFailed: (Date, String) -> Void

    public init(
        shouldCancel: @escaping () -> Bool,
        onDecoded: @escaping (
            RDPDecodedFramePresentation,
            Date,
            Date,
            RDPFrameDecodeTiming
        ) -> Void,
        onDecodeFailed: @escaping (Date, String) -> Void
    ) {
        self.shouldCancel = shouldCancel
        self.onDecoded = onDecoded
        self.onDecodeFailed = onDecodeFailed
    }

    public func submitAndWait(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        shouldContinue: @escaping @Sendable () -> Bool
    ) -> RDPFrameDecodeCompletion {
        let processed = DispatchSemaphore(value: 0)
        let waiter = RDPFrameDecodeCompletionWaiter()
        queue.async { [self] in
            waiter.store(decode(frame, receivedAt: receivedAt))
            processed.signal()
        }
        while processed.wait(timeout: .now() + 0.1) == .timedOut {
            guard shouldContinue() else {
                return .cancelled
            }
        }
        return waiter.load() ?? .cancelled
    }

    public func cancel() {
        lock.withLock {
            isCancelled = true
        }
    }

    private func decode(_ frame: RDPGraphicsFrameSnapshot, receivedAt: Date) -> RDPFrameDecodeCompletion {
        guard lock.withLock({ isCancelled }) == false, shouldCancel() == false else {
            return .cancelled
        }
        return autoreleasepool {
            let decodeStartedAt = Date()
            // The session reports these only once, with this frame, whether or not it decodes.
            decoder.discardSurfaces(frame.deletedSurfaceIDs)
            videoCompositor.forgetDeletedState(before: frame)
            do {
                if frame.contentKind == .surfaceCopy || frame.contentKind == .alpha {
                    if let presentation = try videoCompositor.presentation(applying: frame) {
                        let presentedAt = Date()
                        onDecoded(presentation, receivedAt, presentedAt, RDPFrameDecodeTiming(
                            samplePreparationMilliseconds: 0,
                            videoToolboxMilliseconds: 0,
                            imageConversionMilliseconds: 0,
                            totalMilliseconds: presentedAt.timeIntervalSince(decodeStartedAt) * 1000,
                            decodedPixelFormat: nil,
                            usesHardwareAcceleration: nil
                        ))
                    }
                    return .decoded
                }
                let decodedFrame = try decoder.decodeDetailed(frame)
                let decodedAt = Date()
                guard let presentation = try videoCompositor.presentation(
                    for: frame,
                    decodedImageBuffer: decodedFrame.imageBuffer
                ) else {
                    return .decoded
                }
                onDecoded(
                    presentation,
                    receivedAt,
                    decodedAt,
                    RDPFrameDecodeTiming(
                        samplePreparationMilliseconds: decodedFrame.samplePreparationMilliseconds,
                        videoToolboxMilliseconds: decodedFrame.videoToolboxMilliseconds,
                        imageConversionMilliseconds: decodedFrame.imageConversionMilliseconds,
                        totalMilliseconds: decodedAt.timeIntervalSince(decodeStartedAt) * 1000,
                        decodedPixelFormat: decodedFrame.decodedPixelFormat,
                        usesHardwareAcceleration: decodedFrame.usesHardwareAcceleration
                    )
                )
                return .decoded
            } catch {
                let errorDescription = String(describing: error)
                onDecodeFailed(receivedAt, errorDescription)
                return .failed(errorDescription: errorDescription)
            }
        }
    }
}
