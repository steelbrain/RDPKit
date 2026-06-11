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

private struct RDPPendingDecodeFrame: Sendable {
    var frame: RDPGraphicsFrameSnapshot
    var receivedAt: Date
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
    private var pendingFrame: RDPPendingDecodeFrame?
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

        if pendingFrame != nil {
            skippedPendingFrameCount += 1
            latestSkippedFrameReceivedAt = receivedAt
        }
        pendingFrame = RDPPendingDecodeFrame(frame: frame, receivedAt: receivedAt)
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
        pendingFrame = nil
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
            pendingFrame = nil
            isDraining = false
            return nil
        }
        guard let nextFrame = pendingFrame else {
            isDraining = false
            return nil
        }
        pendingFrame = nil
        return nextFrame
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
