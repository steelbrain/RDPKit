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

struct RDPPendingDecodeFrame: Sendable {
    var frame: RDPGraphicsFrameSnapshot
    var receivedAt: Date
    var resetDecoderBeforeDecode = false
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
    private(set) var waitingForVideoResync = false
    var limits: RDPFrameDecodeQueueLimits

    init(limits: RDPFrameDecodeQueueLimits = RDPFrameDecodeQueueLimits()) {
        self.limits = limits
    }

    mutating func append(_ frame: RDPPendingDecodeFrame) -> [RDPPendingDecodeFrame] {
        if frame.frame.contentKind == .bitmap {
            let dropped = frames
            frames = [frame]
            if dropped.contains(where: { $0.frame.contentKind == .video }) {
                waitingForVideoResync = true
            }
            return dropped
        }

        if waitingForVideoResync {
            guard frame.frame.isVideoResyncFrame else {
                return [frame]
            }
            var resyncFrame = frame
            resyncFrame.resetDecoderBeforeDecode = true
            frames.append(resyncFrame)
            waitingForVideoResync = false
            return []
        }

        frames.append(frame)
        return trimVideoBacklogIfNeeded()
    }

    mutating func takeNext(shouldCancel: Bool) -> RDPPendingDecodeFrame? {
        guard !shouldCancel else {
            frames.removeAll()
            return nil
        }
        guard !frames.isEmpty else {
            return nil
        }
        return frames.removeFirst()
    }

    mutating func removeAll() {
        frames.removeAll()
        waitingForVideoResync = false
    }

    private mutating func trimVideoBacklogIfNeeded() -> [RDPPendingDecodeFrame] {
        guard exceedsVideoBacklogLimit else {
            return []
        }

        if let resyncIndex = frames.indices.reversed().first(where: { frames[$0].frame.isVideoResyncFrame }),
           resyncIndex > frames.startIndex
        {
            let dropped = Array(frames[..<resyncIndex])
            frames.removeFirst(resyncIndex)
            frames[frames.startIndex].resetDecoderBeforeDecode = true
            return dropped
        }

        let dropped = frames
        frames.removeAll()
        waitingForVideoResync = true
        return dropped
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

    private var surfaces: [UInt16: Surface] = [:]
    private let imageConverter = RDPDecodedImageBufferConverter()

    func reset() {
        surfaces.removeAll()
    }

    func presentation(
        for frame: RDPGraphicsFrameSnapshot,
        decodedImageBuffer: CVImageBuffer
    ) throws -> RDPDecodedFramePresentation {
        guard frame.contentKind == .video else {
            synchronizeBitmapSurface(from: frame)
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
        }
        var surface = surface(for: frame.surfaceID, width: surfaceWidth, height: surfaceHeight)
        let surfaceRect = frame.surfaceRect ?? RDPFrameRect(
            left: 0,
            top: 0,
            right: UInt16(clamping: surface.width),
            bottom: UInt16(clamping: surface.height)
        )
        let source = try imageConverter.bgraData(from: decodedImageBuffer)
        let copyRegions = videoCopyRegions(
            updateRect: updateRect,
            regionRects: frame.regionRects,
            sourceWidth: source.width,
            sourceHeight: source.height,
            surfaceWidth: surface.width,
            surfaceHeight: surface.height
        )
        guard copyRegions.isEmpty == false else {
            let imageBuffer = try makePixelBuffer(surface: surface)
            return RDPDecodedFramePresentation(
                frame: composedFrame(from: frame, surface: surface, surfaceRect: surfaceRect),
                imageBuffer: imageBuffer
            )
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

        let imageBuffer = try makePixelBuffer(surface: surface)
        return RDPDecodedFramePresentation(
            frame: composedFrame(from: frame, surface: surface, surfaceRect: surfaceRect),
            imageBuffer: imageBuffer
        )
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
        surface: Surface,
        surfaceRect: RDPFrameRect
    ) -> RDPGraphicsFrameSnapshot {
        let destinationRect = surfaceRect
        let regionRects = frame.regionRects.compactMap {
            outputRegionRect($0, updateRect: frame.destinationRect, surfaceRect: surfaceRect)
        }
        return RDPGraphicsFrameSnapshot(
            frameID: frame.frameID,
            surfaceID: frame.surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: "surface-bgra",
            videoCodec: frame.videoCodec,
            pixelFormat: frame.pixelFormat,
            surfaceRect: surfaceRect,
            destinationRect: destinationRect,
            regionRects: regionRects.isEmpty ? [destinationRect] : regionRects,
            encodedVideoData: Data(),
            contentKind: .bitmap,
            decodedBitmapData: surface.data,
            decodedBitmapBytesPerRow: surface.bytesPerRow
        )
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

    public func submit(_ frame: RDPGraphicsFrameSnapshot, receivedAt: Date) {
        let shouldStartDrain: Bool

        lock.lock()
        guard !isCancelled, !shouldCancel() else {
            lock.unlock()
            return
        }

        recordSkippedFrames(backlog.append(RDPPendingDecodeFrame(frame: frame, receivedAt: receivedAt)))
        if isDraining {
            shouldStartDrain = false
        } else {
            isDraining = true
            shouldStartDrain = true
        }
        lock.unlock()

        if shouldStartDrain {
            Task.detached(priority: .userInitiated) { [self] in
                drain()
            }
        }
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        backlog.removeAll()
        skippedPendingFrameCount = 0
        latestSkippedFrameReceivedAt = nil
        lock.unlock()
    }

    private func drain() {
        while !shouldCancel() {
            let didProcessFrame = autoreleasepool { () -> Bool in
                guard let pendingFrame = takeNextFrame() else {
                    return false
                }
                if let skippedFrames = takeSkippedFrameSummary() {
                    onSkippedFrames(skippedFrames.count, skippedFrames.receivedAt)
                }

                let decodeStartedAt = Date()
                do {
                    if pendingFrame.resetDecoderBeforeDecode {
                        decoder.reset()
                        videoCompositor.reset()
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
                    onDecodeFailed(
                        pendingFrame.receivedAt,
                        String(describing: error)
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
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !shouldCancel() else {
            isCancelled = true
            backlog.removeAll()
            isDraining = false
            return nil
        }
        guard let nextFrame = backlog.takeNext(shouldCancel: false) else {
            isDraining = false
            return nil
        }
        return nextFrame
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
