import CoreImage
import CoreVideo
import Foundation

public struct RDPDecodedFramePresentation: @unchecked Sendable {
    public var frame: RDPGraphicsFrameSnapshot
    public var imageBuffer: CVImageBuffer

    public init(frame: RDPGraphicsFrameSnapshot, imageBuffer: CVImageBuffer) {
        self.frame = frame
        self.imageBuffer = imageBuffer
    }
}

@MainActor
public final class RDPFramePresentationBuffer {
    private var pendingPresentation: RDPDecodedFramePresentation?

    public init() {}

    public func replacePendingPresentation(_ presentation: RDPDecodedFramePresentation) -> Bool {
        let replacedPendingPresentation = pendingPresentation != nil
        pendingPresentation = presentation
        return replacedPendingPresentation
    }

    public func takePendingPresentation() -> RDPDecodedFramePresentation? {
        let presentation = pendingPresentation
        pendingPresentation = nil
        return presentation
    }

    public func clear() {
        pendingPresentation = nil
    }
}

public enum RDPReportFirstFrameDecodeResult: @unchecked Sendable {
    case decoded(
        presentation: RDPDecodedFramePresentation,
        receivedAt: Date,
        decodedAt: Date,
        timing: RDPFrameDecodeTiming
    )
    case failed(receivedAt: Date, errorDescription: String)
}

public struct RDPFrameDecodeTiming: Sendable {
    public var samplePreparationMilliseconds: Double
    public var videoToolboxMilliseconds: Double
    public var imageConversionMilliseconds: Double
    public var cropMilliseconds: Double
    public var totalMilliseconds: Double
    public var decodedPixelFormat: UInt32?
    public var usesHardwareAcceleration: Bool?

    public init(
        samplePreparationMilliseconds: Double,
        videoToolboxMilliseconds: Double,
        imageConversionMilliseconds: Double,
        cropMilliseconds: Double,
        totalMilliseconds: Double,
        decodedPixelFormat: UInt32?,
        usesHardwareAcceleration: Bool?
    ) {
        self.samplePreparationMilliseconds = samplePreparationMilliseconds
        self.videoToolboxMilliseconds = videoToolboxMilliseconds
        self.imageConversionMilliseconds = imageConversionMilliseconds
        self.cropMilliseconds = cropMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.decodedPixelFormat = decodedPixelFormat
        self.usesHardwareAcceleration = usesHardwareAcceleration
    }
}

public enum RDPFrameDecodeCompletion: Equatable, Sendable {
    case decoded
    case failed(errorDescription: String)
    case dropped
    case cancelled

    public func requireDecoded() throws {
        switch self {
        case .decoded:
            return
        case .failed(let errorDescription):
            throw RDPFrameDecodeQueueError.decodeFailed(errorDescription)
        case .dropped:
            throw RDPFrameDecodeQueueError.frameDropped
        case .cancelled:
            throw RDPFrameDecodeQueueError.cancelled
        }
    }
}

public enum RDPFrameDecodeQueueError: Error, Equatable, CustomStringConvertible, Sendable {
    case decodeFailed(String)
    case frameDropped
    case cancelled

    public var description: String {
        switch self {
        case .decodeFailed(let errorDescription):
            return "frame decode failed: \(errorDescription)"
        case .frameDropped:
            return "frame decode was dropped before updating the graphics output"
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

struct RDPPendingDecodeFrame: Sendable {
    var frame: RDPGraphicsFrameSnapshot
    var receivedAt: Date
    var resetDecoderBeforeDecode = false
    var onCompleted: (@Sendable (RDPFrameDecodeCompletion) -> Void)? = nil
    var onProcessed: (@Sendable () -> Void)? = nil
}

struct RDPFrameDecodeQueueLimits: Equatable, Sendable {
    var maxQueuedVideoFrames: Int
    var maxQueuedVideoLatency: TimeInterval
    var maxQueuedVideoBytes: Int

    init(
        maxQueuedVideoFrames: Int = 30,
        maxQueuedVideoLatency: TimeInterval = 0.5,
        maxQueuedVideoBytes: Int = 64 * 1024 * 1024
    ) {
        self.maxQueuedVideoFrames = max(1, maxQueuedVideoFrames)
        self.maxQueuedVideoLatency = max(0, maxQueuedVideoLatency)
        self.maxQueuedVideoBytes = max(1, maxQueuedVideoBytes)
    }
}

struct RDPFrameDecodeBacklog: Sendable {
    private(set) var frames: [RDPPendingDecodeFrame] = []
    private var waitingForVideoResyncSurfaceIDs: Set<UInt16> = []
    var limits: RDPFrameDecodeQueueLimits

    var waitingForVideoResync: Bool {
        waitingForVideoResyncSurfaceIDs.isEmpty == false
    }

    init(limits: RDPFrameDecodeQueueLimits = RDPFrameDecodeQueueLimits()) {
        self.limits = limits
    }

    mutating func append(_ frame: RDPPendingDecodeFrame) -> [RDPPendingDecodeFrame] {
        if frame.frame.contentKind == .bitmap {
            let dropped = frames
            frames = [frame]
            waitingForVideoResyncSurfaceIDs.formUnion(dropped.compactMap {
                $0.frame.contentKind == .video ? $0.frame.surfaceID : nil
            })
            return dropped
        }

        let surfaceID = frame.frame.surfaceID
        if waitingForVideoResyncSurfaceIDs.contains(surfaceID) {
            guard frame.frame.isVideoResyncFrame else {
                return [frame]
            }
            var resyncFrame = frame
            resyncFrame.resetDecoderBeforeDecode = true
            frames.append(resyncFrame)
            waitingForVideoResyncSurfaceIDs.remove(surfaceID)
            return trimVideoBacklogIfNeeded()
        }

        frames.append(frame)
        return trimVideoBacklogIfNeeded()
    }

    mutating func takeNext(shouldCancel: Bool) -> RDPPendingDecodeFrame? {
        guard !shouldCancel else {
            frames.removeAll()
            waitingForVideoResyncSurfaceIDs.removeAll()
            return nil
        }
        guard !frames.isEmpty else {
            return nil
        }
        return frames.removeFirst()
    }

    mutating func removeAll() -> [RDPPendingDecodeFrame] {
        let removed = frames
        frames.removeAll()
        waitingForVideoResyncSurfaceIDs.removeAll()
        return removed
    }

    private mutating func trimVideoBacklogIfNeeded() -> [RDPPendingDecodeFrame] {
        guard exceedsVideoBacklogLimit else {
            return []
        }

        let videoSurfaceIDs = Set(frames.compactMap {
            $0.frame.contentKind == .video ? $0.frame.surfaceID : nil
        })
        var firstRetainedIndexes: [UInt16: Int] = [:]
        for surfaceID in videoSurfaceIDs {
            if let resyncIndex = frames.indices.reversed().first(where: {
                frames[$0].frame.surfaceID == surfaceID && frames[$0].frame.isVideoResyncFrame
            }) {
                firstRetainedIndexes[surfaceID] = resyncIndex
            }
        }

        let originalFrames = frames
        let retainedFrames = frames.enumerated().compactMap { index, frame -> (Int, RDPPendingDecodeFrame)? in
            guard frame.frame.contentKind == .video else {
                return (index, frame)
            }
            guard let firstRetainedIndex = firstRetainedIndexes[frame.frame.surfaceID] else {
                // Inter pictures remain dependent on the retained decoder chain. Treat the
                // queue limits as soft until the server supplies a safe recovery point.
                return (index, frame)
            }
            guard index >= firstRetainedIndex else {
                return nil
            }
            var retainedFrame = frame
            if index == firstRetainedIndex {
                retainedFrame.resetDecoderBeforeDecode = true
            }
            return (index, retainedFrame)
        }
        frames = retainedFrames.map(\.1)

        let retainedIndexes = Set(retainedFrames.map(\.0))
        return originalFrames.enumerated().compactMap { index, frame in
            retainedIndexes.contains(index) ? nil : frame
        }
    }

    private var exceedsVideoBacklogLimit: Bool {
        var videoFrameCount = 0
        var videoByteCount = 0
        var firstVideoReceivedAt: Date?
        var lastVideoReceivedAt: Date?

        for frame in frames where frame.frame.contentKind == .video {
            videoFrameCount += 1
            videoByteCount += frame.frame.payloadByteCount
            firstVideoReceivedAt = firstVideoReceivedAt ?? frame.receivedAt
            lastVideoReceivedAt = frame.receivedAt
        }

        if videoFrameCount > limits.maxQueuedVideoFrames {
            return true
        }
        if videoByteCount > limits.maxQueuedVideoBytes {
            return true
        }
        if let firstVideoReceivedAt,
           let lastVideoReceivedAt,
           lastVideoReceivedAt.timeIntervalSince(firstVideoReceivedAt) > limits.maxQueuedVideoLatency
        {
            return true
        }
        return false
    }
}

private extension RDPGraphicsFrameSnapshot {
    var isVideoResyncFrame: Bool {
        guard contentKind == .video else {
            return false
        }
        if avc444SubframeLayout == .chroma420Only {
            return false
        }

        let types = videoNalUnitTypes
        switch videoCodec {
        case .h264:
            return types.contains(5)
                && types.contains(7)
                && types.contains(8)
        case .hevc:
            return (types.contains(19) || types.contains(20) || types.contains(21))
                && types.contains(32)
                && types.contains(33)
                && types.contains(34)
        }
    }
}

public func decodeReportFirstFrame(_ frame: RDPGraphicsFrameSnapshot) -> RDPReportFirstFrameDecodeResult {
    autoreleasepool {
        let receivedAt = Date()
        let decodeStartedAt = Date()
        do {
            let decodedFrame = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame)
            let decodedAt = Date()
            return .decoded(
                presentation: RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedFrame.imageBuffer),
                receivedAt: receivedAt,
                decodedAt: decodedAt,
                timing: RDPFrameDecodeTiming(
                    samplePreparationMilliseconds: decodedFrame.samplePreparationMilliseconds,
                    videoToolboxMilliseconds: decodedFrame.videoToolboxMilliseconds,
                    imageConversionMilliseconds: decodedFrame.imageConversionMilliseconds,
                    cropMilliseconds: 0,
                    totalMilliseconds: decodedAt.timeIntervalSince(decodeStartedAt) * 1000,
                    decodedPixelFormat: decodedFrame.decodedPixelFormat,
                    usesHardwareAcceleration: decodedFrame.usesHardwareAcceleration
                )
            )
        } catch {
            return .failed(receivedAt: receivedAt, errorDescription: String(describing: error))
        }
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
    private var graphicsOutput: Surface?
    private let imageConverter = RDPDecodedImageBufferConverter()

    func reset() {
        surfaces.removeAll()
        directSurfaces.removeAll()
        chromaEnhancedAVC444Surfaces.removeAll()
        graphicsOutput = nil
    }

    func reset(surfaceID: UInt16) {
        surfaces[surfaceID] = nil
        directSurfaces[surfaceID] = nil
        chromaEnhancedAVC444Surfaces.remove(surfaceID)
    }

    func presentation(
        for frame: RDPGraphicsFrameSnapshot,
        decodedImageBuffer: CVImageBuffer
    ) throws -> RDPDecodedFramePresentation {
        guard frame.contentKind == .video else {
            if let outputRect = frame.graphicsOutputRect {
                try materializeDirectGraphicsOutputIfNeeded(
                    outputRect: outputRect,
                    excludingSurfaceID: frame.surfaceID
                )
            }
            directSurfaces[frame.surfaceID] = nil
            synchronizeBitmapSurface(from: frame)
            if let displayedSurface = bitmapSurface(from: frame) {
                return try graphicsOutputPresentation(from: frame, displayedSurface: displayedSurface)
            }
            return RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedImageBuffer)
        }

        let updateRect = frame.destinationRect
        let requestedSurfaceRect = frame.surfaceRect ?? inferredSurfaceRect(from: updateRect)
        let surfaceWidth = Int(requestedSurfaceRect.width)
        let surfaceHeight = Int(requestedSurfaceRect.height)
        guard surfaceWidth > 0, surfaceHeight > 0 else {
            return RDPDecodedFramePresentation(frame: frame, imageBuffer: decodedImageBuffer)
        }

        if frame.isVideoResyncFrame,
           updateRect.left == 0,
           updateRect.top == 0
        {
            surfaces[frame.surfaceID] = nil
            directSurfaces[frame.surfaceID] = nil
            chromaEnhancedAVC444Surfaces.remove(frame.surfaceID)
        }
        let surfaceRect = frame.surfaceRect ?? RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(clamping: surfaceWidth),
            bottom: UInt16(clamping: surfaceHeight)
        )
        let canPresentDirectly = canPresentDirectly(frame, surfaceRect: surfaceRect)
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
        var surface = surface(for: frame.surfaceID, width: surfaceWidth, height: surfaceHeight)
        let source = try imageConverter.bgraData(from: decodedImageBuffer)
        let copyRegions = videoCopyRegions(
            updateRect: updateRect,
            regionRects: frame.regionRects + frame.auxiliaryRegionRects,
            sourceWidth: source.width,
            sourceHeight: source.height,
            surfaceWidth: surface.width,
            surfaceHeight: surface.height
        )
        guard copyRegions.isEmpty == false else {
            return try presentation(from: frame, surface: surface, surfaceRect: surfaceRect)
        }

        for region in copyRegions {
            copy(
                source: source.data,
                sourceBytesPerRow: source.bytesPerRow,
                destination: &surface.data,
                destinationBytesPerRow: surface.bytesPerRow,
                sourceX: region.sourceX,
                sourceY: region.sourceY,
                destinationX: region.destinationX,
                destinationY: region.destinationY,
                width: region.width,
                height: region.height
            )
        }
        surfaces[frame.surfaceID] = surface

        return try presentation(from: frame, surface: surface, surfaceRect: surfaceRect)
    }

    private func canPresentDirectly(
        _ frame: RDPGraphicsFrameSnapshot,
        surfaceRect: RDPFrameRect
    ) -> Bool {
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

    private func regionsCoverSurface(
        _ regions: [RDPFrameRect],
        frame: RDPGraphicsFrameSnapshot,
        surfaceRect: RDPFrameRect
    ) -> Bool {
        regions.contains {
            outputRegionRect($0, updateRect: frame.destinationRect, surfaceRect: surfaceRect) == surfaceRect
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
        let regionRects = (frame.regionRects + frame.auxiliaryRegionRects).compactMap {
            outputRegionRect($0, updateRect: frame.destinationRect, surfaceRect: surfaceRect)
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
        var surface = surface(
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

    private func surface(for surfaceID: UInt16, width: Int, height: Int) -> Surface {
        if let existing = surfaces[surfaceID],
           existing.width >= width,
           existing.height >= height
        {
            return existing
        }

        let nextWidth = max(width, surfaces[surfaceID]?.width ?? 0)
        let nextHeight = max(height, surfaces[surfaceID]?.height ?? 0)
        let bytesPerRow = nextWidth * 4
        var surface = Surface(
            width: nextWidth,
            height: nextHeight,
            bytesPerRow: bytesPerRow,
            data: Data(repeating: 0, count: bytesPerRow * nextHeight)
        )

        if let existing = surfaces[surfaceID] {
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
        surfaces[surfaceID] = surface
        return surface
    }

    private func composedFrame(
        from frame: RDPGraphicsFrameSnapshot,
        displayedSurface: Surface,
        surfaceRect: RDPFrameRect
    ) -> RDPGraphicsFrameSnapshot {
        let destinationRect = frame.mappedOutputRect ?? surfaceRect
        var regionRects = (frame.regionRects + frame.auxiliaryRegionRects).compactMap {
            outputRegionRect($0, updateRect: frame.destinationRect, surfaceRect: surfaceRect)
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
            surfaceRect: surfaceRect,
            mappedOutputRect: frame.mappedOutputRect,
            destinationRect: destinationRect,
            regionRects: regionRects.isEmpty ? [destinationRect] : regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: displayedSurface.data,
            decodedBitmapBytesPerRow: displayedSurface.bytesPerRow
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

        var output = graphicsOutput
        if output?.width != outputWidth || output?.height != outputHeight {
            output = Surface(
                width: outputWidth,
                height: outputHeight,
                bytesPerRow: outputWidth * 4,
                data: Data(repeating: 0, count: outputWidth * outputHeight * 4)
            )
        }
        guard var output else {
            throw RDPBitmapFrameDecodeError.invalidBitmapLayout
        }
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
            surfaceRect: outputRect,
            destinationRect: outputRect,
            regionRects: regionRects.isEmpty ? [outputRect] : regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: output.data,
            decodedBitmapBytesPerRow: output.bytesPerRow
        )
        return RDPDecodedFramePresentation(
            frame: outputFrame,
            imageBuffer: try makePixelBuffer(surface: output)
        )
    }

    private func bitmapSurface(from frame: RDPGraphicsFrameSnapshot) -> Surface? {
        guard frame.graphicsOutputRect != nil,
              let data = frame.decodedBitmapData,
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
        var data = Data(repeating: 0, count: bytesPerRow * height)
        for targetY in 0 ..< height {
            let sourceY = min(surface.height - 1, targetY * surface.height / height)
            for targetX in 0 ..< width {
                let sourceX = min(surface.width - 1, targetX * surface.width / width)
                let sourceOffset = sourceY * surface.bytesPerRow + sourceX * 4
                let targetOffset = targetY * bytesPerRow + targetX * 4
                data[targetOffset ..< targetOffset + 4] = surface.data[sourceOffset ..< sourceOffset + 4]
            }
        }
        return Surface(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    private func makePixelBuffer(surface: Surface) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            surface.width,
            surface.height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RDPBitmapFrameDecodeError.coreVideo(operation: "create composed video pixel buffer", status: status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RDPBitmapFrameDecodeError.missingBaseAddress
        }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        surface.data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress else {
                return
            }
            for row in 0 ..< surface.height {
                memcpy(
                    destination.advanced(by: row * destinationBytesPerRow),
                    source.advanced(by: row * surface.bytesPerRow),
                    surface.width * 4
                )
            }
        }
        return pixelBuffer
    }

    private func synchronizeBitmapSurface(from frame: RDPGraphicsFrameSnapshot) {
        guard let data = frame.decodedBitmapData,
              let bytesPerRow = frame.decodedBitmapBytesPerRow,
              frame.mappedOutputRect == nil,
              frame.width > 0,
              frame.height > 0
        else {
            surfaces[frame.surfaceID] = nil
            return
        }
        surfaces[frame.surfaceID] = Surface(
            width: Int(frame.width),
            height: Int(frame.height),
            bytesPerRow: bytesPerRow,
            data: data
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

private func inferredSurfaceRect(from updateRect: RDPFrameRect) -> RDPFrameRect {
    RDPFrameRect(
        left: 0,
        top: 0,
        right: max(updateRect.right, updateRect.width),
        bottom: max(updateRect.bottom, updateRect.height)
    )
}

private func videoCopyRegions(
    updateRect: RDPFrameRect,
    regionRects: [RDPFrameRect],
    sourceWidth: Int,
    sourceHeight: Int,
    surfaceWidth: Int,
    surfaceHeight: Int
) -> [RDPVideoCopyRegion] {
    let regions = regionRects.isEmpty
        ? [RDPFrameRect(left: 0, top: 0, right: updateRect.width, bottom: updateRect.height)]
        : regionRects
    let regionsAreRelative = regions.allSatisfy {
        $0.left <= updateRect.width
            && $0.top <= updateRect.height
            && $0.right <= updateRect.width
            && $0.bottom <= updateRect.height
    }

    return regions.compactMap { region in
        let sourceLeft: Int
        let sourceTop: Int
        let destinationLeft: Int
        let destinationTop: Int
        if regionsAreRelative {
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
    surfaceRect: RDPFrameRect
) -> RDPFrameRect? {
    let relative = region.right <= updateRect.width && region.bottom <= updateRect.height
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

private struct RDPDecodedBGRAImage {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var data: Data
}

private final class RDPDecodedImageBufferConverter {
    private let ciContext = CIContext()

    func bgraData(from imageBuffer: CVImageBuffer) throws -> RDPDecodedBGRAImage {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width > 0, height > 0 else {
            throw RDPBitmapFrameDecodeError.invalidBitmapLayout
        }

        if CVPixelBufferGetPixelFormatType(imageBuffer) == kCVPixelFormatType_32BGRA {
            return try copyBGRAData(from: imageBuffer, width: width, height: height)
        }

        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            ciContext.render(
                CIImage(cvImageBuffer: imageBuffer),
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .BGRA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        return RDPDecodedBGRAImage(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    private func copyBGRAData(from imageBuffer: CVImageBuffer, width: Int, height: Int) throws -> RDPDecodedBGRAImage {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        }
        guard let source = CVPixelBufferGetBaseAddress(imageBuffer) else {
            throw RDPBitmapFrameDecodeError.missingBaseAddress
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let bytesPerRow = width * 4
        var data = Data(repeating: 0, count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            guard let destination = buffer.baseAddress else {
                return
            }
            for row in 0 ..< height {
                memcpy(
                    destination.advanced(by: row * bytesPerRow),
                    source.advanced(by: row * sourceBytesPerRow),
                    bytesPerRow
                )
            }
        }
        return RDPDecodedBGRAImage(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
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

public final class RDPLatestFrameDecodeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = RDPVideoToolboxFrameDecoder()
    private let videoCompositor = RDPDecodedVideoSurfaceCompositor()
    private var backlog: RDPFrameDecodeBacklog
    private var skippedPendingFrameCount = 0
    private var latestSkippedFrameReceivedAt: Date?
    private var isDraining = false
    private var isCancelled = false
    private let shouldCancel: () -> Bool
    private let onDecoded: (
        RDPDecodedFramePresentation,
        Date,
        Date,
        RDPFrameDecodeTiming
    ) -> Void
    private let onDecodeFailed: (Date, String) -> Void
    private let onSkippedFrames: (Int, Date) -> Void

    public init(
        maxQueuedVideoFrames: Int = 30,
        maxQueuedVideoLatency: TimeInterval = 0.5,
        maxQueuedVideoBytes: Int = 64 * 1024 * 1024,
        shouldCancel: @escaping () -> Bool,
        onDecoded: @escaping (
            RDPDecodedFramePresentation,
            Date,
            Date,
            RDPFrameDecodeTiming
        ) -> Void,
        onDecodeFailed: @escaping (Date, String) -> Void,
        onSkippedFrames: @escaping (Int, Date) -> Void
    ) {
        backlog = RDPFrameDecodeBacklog(limits: RDPFrameDecodeQueueLimits(
            maxQueuedVideoFrames: maxQueuedVideoFrames,
            maxQueuedVideoLatency: maxQueuedVideoLatency,
            maxQueuedVideoBytes: maxQueuedVideoBytes
        ))
        self.shouldCancel = shouldCancel
        self.onDecoded = onDecoded
        self.onDecodeFailed = onDecodeFailed
        self.onSkippedFrames = onSkippedFrames
    }

    public func submit(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        onProcessed: (@Sendable () -> Void)? = nil
    ) {
        enqueue(
            frame,
            receivedAt: receivedAt,
            onCompleted: nil,
            onProcessed: onProcessed
        )
    }

    public func submitReportingCompletion(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        onCompleted: @escaping @Sendable (RDPFrameDecodeCompletion) -> Void,
        onProcessed: (@Sendable () -> Void)? = nil
    ) {
        enqueue(
            frame,
            receivedAt: receivedAt,
            onCompleted: onCompleted,
            onProcessed: onProcessed
        )
    }

    private func enqueue(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        onCompleted: (@Sendable (RDPFrameDecodeCompletion) -> Void)?,
        onProcessed: (@Sendable () -> Void)?
    ) {
        let shouldStartDrain: Bool
        let droppedFrames: [RDPPendingDecodeFrame]

        lock.lock()
        guard !isCancelled, !shouldCancel() else {
            lock.unlock()
            onCompleted?(.cancelled)
            onProcessed?()
            return
        }

        droppedFrames = backlog.append(RDPPendingDecodeFrame(
            frame: frame,
            receivedAt: receivedAt,
            onCompleted: onCompleted,
            onProcessed: onProcessed
        ))
        recordSkippedFrames(droppedFrames)
        if isDraining {
            shouldStartDrain = false
        } else {
            isDraining = true
            shouldStartDrain = true
        }
        lock.unlock()
        complete(droppedFrames, with: .dropped)

        if shouldStartDrain {
            Task.detached(priority: .userInitiated) { [self] in
                drain()
            }
        }
    }

    public func submitAndWait(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        shouldContinue: @escaping @Sendable () -> Bool
    ) -> RDPFrameDecodeCompletion {
        let processed = DispatchSemaphore(value: 0)
        let waiter = RDPFrameDecodeCompletionWaiter()
        submitReportingCompletion(
            frame,
            receivedAt: receivedAt,
            onCompleted: { completion in
                waiter.store(completion)
                processed.signal()
            }
        )
        while processed.wait(timeout: .now() + 0.1) == .timedOut {
            guard shouldContinue() else {
                return .cancelled
            }
        }
        return waiter.load() ?? .cancelled
    }

    public func cancel() {
        let droppedFrames: [RDPPendingDecodeFrame]
        lock.lock()
        isCancelled = true
        droppedFrames = backlog.removeAll()
        skippedPendingFrameCount = 0
        latestSkippedFrameReceivedAt = nil
        lock.unlock()
        complete(droppedFrames, with: .cancelled)
    }

    private func drain() {
        while !shouldCancel() {
            let didProcessFrame = autoreleasepool { () -> Bool in
                guard let pendingFrame = takeNextFrame() else {
                    return false
                }
                var completion = RDPFrameDecodeCompletion.decoded
                defer {
                    pendingFrame.onCompleted?(completion)
                    pendingFrame.onProcessed?()
                }
                if let skippedFrames = takeSkippedFrameSummary() {
                    onSkippedFrames(skippedFrames.count, skippedFrames.receivedAt)
                }

                let decodeStartedAt = Date()
                do {
                    if pendingFrame.resetDecoderBeforeDecode {
                        decoder.reset(surfaceID: pendingFrame.frame.surfaceID)
                        videoCompositor.reset(surfaceID: pendingFrame.frame.surfaceID)
                    }
                    let decodedFrame = try decoder.decodeDetailed(pendingFrame.frame)
                    let decodedAt = Date()
                    let presentation = try videoCompositor.presentation(
                        for: pendingFrame.frame,
                        decodedImageBuffer: decodedFrame.imageBuffer
                    )
                    onDecoded(
                        presentation,
                        pendingFrame.receivedAt,
                        decodedAt,
                        RDPFrameDecodeTiming(
                            samplePreparationMilliseconds: decodedFrame.samplePreparationMilliseconds,
                            videoToolboxMilliseconds: decodedFrame.videoToolboxMilliseconds,
                            imageConversionMilliseconds: decodedFrame.imageConversionMilliseconds,
                            cropMilliseconds: 0,
                            totalMilliseconds: decodedAt.timeIntervalSince(decodeStartedAt) * 1000,
                            decodedPixelFormat: decodedFrame.decodedPixelFormat,
                            usesHardwareAcceleration: decodedFrame.usesHardwareAcceleration
                        )
                    )
                } catch {
                    let errorDescription = String(describing: error)
                    completion = .failed(errorDescription: errorDescription)
                    onDecodeFailed(
                        pendingFrame.receivedAt,
                        errorDescription
                    )
                }
                return true
            }

            guard didProcessFrame else {
                return
            }
        }
        cancel()
    }

    private func takeNextFrame() -> RDPPendingDecodeFrame? {
        var droppedFrames: [RDPPendingDecodeFrame] = []
        let nextFrame: RDPPendingDecodeFrame?
        lock.lock()
        if isCancelled || shouldCancel() {
            isCancelled = true
            droppedFrames = backlog.removeAll()
            isDraining = false
            nextFrame = nil
        } else {
            nextFrame = backlog.takeNext(shouldCancel: false)
            if nextFrame == nil {
                isDraining = false
            }
        }
        lock.unlock()
        complete(droppedFrames, with: .cancelled)
        return nextFrame
    }

    private func complete(
        _ frames: [RDPPendingDecodeFrame],
        with completion: RDPFrameDecodeCompletion
    ) {
        for frame in frames {
            frame.onCompleted?(completion)
            frame.onProcessed?()
        }
    }

    private func recordSkippedFrames(_ frames: [RDPPendingDecodeFrame]) {
        guard frames.isEmpty == false else {
            return
        }
        skippedPendingFrameCount += frames.count
        latestSkippedFrameReceivedAt = frames.last?.receivedAt ?? Date()
    }

    private func takeSkippedFrameSummary() -> (count: Int, receivedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard skippedPendingFrameCount > 0 else {
            return nil
        }

        let summary = (
            count: skippedPendingFrameCount,
            receivedAt: latestSkippedFrameReceivedAt ?? Date()
        )
        skippedPendingFrameCount = 0
        latestSkippedFrameReceivedAt = nil
        return summary
    }
}
