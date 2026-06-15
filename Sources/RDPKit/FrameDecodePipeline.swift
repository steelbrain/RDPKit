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

public final class RDPLatestFrameDecodeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = RDPVideoToolboxFrameDecoder()
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
                    }
                    let decodedFrame = try decoder.decodeDetailed(pendingFrame.frame)
                    let decodedAt = Date()
                    onDecoded(
                        RDPDecodedFramePresentation(
                            frame: pendingFrame.frame,
                            imageBuffer: decodedFrame.imageBuffer
                        ),
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
