import Foundation

public struct RDPRenderMetrics: Equatable {
    private struct WireReceiveRecord: Equatable {
        var receivedAt: Date
        var byteCount: Int
    }

    private static let rollingWireWindowSeconds = 5.0

    public var connectionStartedAt: Date?
    public var firstFrameReceivedAt: Date?
    public var lastFrameReceivedAt: Date?
    public var lastFrameDecodedAt: Date?
    public var decodedFrameCount = 0
    public var failedDecodeCount = 0
    public var skippedDecodeFrameCount = 0
    public var skippedPresentationFrameCount = 0
    public var decodedByteCount = 0
    public var wireByteCount = 0
    public var totalDecodeMilliseconds = 0.0
    public var lastDecodeMilliseconds: Double?
    public var maxDecodeMilliseconds: Double?
    public var totalSamplePreparationMilliseconds = 0.0
    public var lastSamplePreparationMilliseconds: Double?
    public var maxSamplePreparationMilliseconds: Double?
    public var totalVideoToolboxMilliseconds = 0.0
    public var lastVideoToolboxMilliseconds: Double?
    public var maxVideoToolboxMilliseconds: Double?
    public var totalImageConversionMilliseconds = 0.0
    public var lastImageConversionMilliseconds: Double?
    public var maxImageConversionMilliseconds: Double?
    public var decodedPixelFormat: UInt32?
    public var usesHardwareAcceleration: Bool?
    public var totalCropMilliseconds = 0.0
    public var lastCropMilliseconds: Double?
    public var maxCropMilliseconds: Double?
    public var lastDecodeError: String?
    private var recentFrameDecodedAt: [Date] = []
    private var firstRecentFrameDecodedAtIndex = 0
    private var recentWireReceiveRecords: [WireReceiveRecord] = []
    private var firstRecentWireReceiveRecordIndex = 0
    private var recentWireByteCount = 0
    private var rollingWireMegabitsPerSecondValue: Double?

    public init(connectionStartedAt: Date? = nil) {
        self.connectionStartedAt = connectionStartedAt
    }

    public static func == (lhs: RDPRenderMetrics, rhs: RDPRenderMetrics) -> Bool {
        lhs.connectionStartedAt == rhs.connectionStartedAt
            && lhs.firstFrameReceivedAt == rhs.firstFrameReceivedAt
            && lhs.lastFrameReceivedAt == rhs.lastFrameReceivedAt
            && lhs.lastFrameDecodedAt == rhs.lastFrameDecodedAt
            && lhs.decodedFrameCount == rhs.decodedFrameCount
            && lhs.failedDecodeCount == rhs.failedDecodeCount
            && lhs.skippedDecodeFrameCount == rhs.skippedDecodeFrameCount
            && lhs.skippedPresentationFrameCount == rhs.skippedPresentationFrameCount
            && lhs.decodedByteCount == rhs.decodedByteCount
            && lhs.wireByteCount == rhs.wireByteCount
            && lhs.totalDecodeMilliseconds == rhs.totalDecodeMilliseconds
            && lhs.lastDecodeMilliseconds == rhs.lastDecodeMilliseconds
            && lhs.maxDecodeMilliseconds == rhs.maxDecodeMilliseconds
            && lhs.totalSamplePreparationMilliseconds == rhs.totalSamplePreparationMilliseconds
            && lhs.lastSamplePreparationMilliseconds == rhs.lastSamplePreparationMilliseconds
            && lhs.maxSamplePreparationMilliseconds == rhs.maxSamplePreparationMilliseconds
            && lhs.totalVideoToolboxMilliseconds == rhs.totalVideoToolboxMilliseconds
            && lhs.lastVideoToolboxMilliseconds == rhs.lastVideoToolboxMilliseconds
            && lhs.maxVideoToolboxMilliseconds == rhs.maxVideoToolboxMilliseconds
            && lhs.totalImageConversionMilliseconds == rhs.totalImageConversionMilliseconds
            && lhs.lastImageConversionMilliseconds == rhs.lastImageConversionMilliseconds
            && lhs.maxImageConversionMilliseconds == rhs.maxImageConversionMilliseconds
            && lhs.decodedPixelFormat == rhs.decodedPixelFormat
            && lhs.usesHardwareAcceleration == rhs.usesHardwareAcceleration
            && lhs.totalCropMilliseconds == rhs.totalCropMilliseconds
            && lhs.lastCropMilliseconds == rhs.lastCropMilliseconds
            && lhs.maxCropMilliseconds == rhs.maxCropMilliseconds
            && lhs.lastDecodeError == rhs.lastDecodeError
            && lhs.rollingWireMegabitsPerSecondValue == rhs.rollingWireMegabitsPerSecondValue
    }

    public var hasActivity: Bool {
        connectionStartedAt != nil
            || decodedFrameCount > 0
            || failedDecodeCount > 0
            || skippedDecodeFrameCount > 0
            || skippedPresentationFrameCount > 0
            || wireByteCount > 0
    }

    public var firstFrameLatencyMilliseconds: Double? {
        guard let connectionStartedAt,
              let firstFrameReceivedAt
        else {
            return nil
        }
        return max(0, firstFrameReceivedAt.timeIntervalSince(connectionStartedAt) * 1000)
    }

    public var averageDecodeMilliseconds: Double? {
        guard decodedFrameCount > 0 else {
            return nil
        }
        return totalDecodeMilliseconds / Double(decodedFrameCount)
    }

    public var averageSamplePreparationMilliseconds: Double? {
        averageComponentMilliseconds(totalSamplePreparationMilliseconds)
    }

    public var averageVideoToolboxMilliseconds: Double? {
        averageComponentMilliseconds(totalVideoToolboxMilliseconds)
    }

    public var averageImageConversionMilliseconds: Double? {
        averageComponentMilliseconds(totalImageConversionMilliseconds)
    }

    public var averageCropMilliseconds: Double? {
        averageComponentMilliseconds(totalCropMilliseconds)
    }

    public var averageFramesPerSecond: Double? {
        guard decodedFrameCount > 1,
              let firstFrameReceivedAt,
              let lastFrameDecodedAt
        else {
            return nil
        }
        let elapsed = lastFrameDecodedAt.timeIntervalSince(firstFrameReceivedAt)
        guard elapsed > 0 else {
            return nil
        }
        return Double(decodedFrameCount - 1) / elapsed
    }

    public var rollingFramesPerSecond: Double? {
        guard firstRecentFrameDecodedAtIndex < recentFrameDecodedAt.count,
              let last = recentFrameDecodedAt.last
        else {
            return nil
        }
        let visibleFrameCount = recentFrameDecodedAt.count - firstRecentFrameDecodedAtIndex
        guard visibleFrameCount > 1 else {
            return nil
        }
        let first = recentFrameDecodedAt[firstRecentFrameDecodedAtIndex]
        let elapsed = last.timeIntervalSince(first)
        guard elapsed > 0 else {
            return nil
        }
        return Double(visibleFrameCount - 1) / elapsed
    }

    public var rollingWireMegabitsPerSecond: Double? {
        rollingWireMegabitsPerSecondValue
    }

    public var averageWireMegabitsPerSecond: Double? {
        guard let connectionStartedAt else {
            return nil
        }
        let elapsed = max(0.25, Date().timeIntervalSince(connectionStartedAt))
        return megabitsPerSecond(byteCount: wireByteCount, elapsedSeconds: elapsed)
    }

    public mutating func recordWireReceive(_ sample: RDPWireReceiveSample) {
        if connectionStartedAt == nil {
            connectionStartedAt = sample.receivedAt
        }
        wireByteCount += sample.byteCount
        recentWireReceiveRecords.append(
            WireReceiveRecord(receivedAt: sample.receivedAt, byteCount: sample.byteCount)
        )
        recentWireByteCount += sample.byteCount
        let cutoff = sample.receivedAt.addingTimeInterval(-Self.rollingWireWindowSeconds)
        while firstRecentWireReceiveRecordIndex < recentWireReceiveRecords.count,
              recentWireReceiveRecords[firstRecentWireReceiveRecordIndex].receivedAt < cutoff
        {
            recentWireByteCount -= recentWireReceiveRecords[firstRecentWireReceiveRecordIndex].byteCount
            firstRecentWireReceiveRecordIndex += 1
        }

        compactRecentWireRecordsIfNeeded()

        guard firstRecentWireReceiveRecordIndex < recentWireReceiveRecords.count else {
            recentWireReceiveRecords.removeAll(keepingCapacity: true)
            firstRecentWireReceiveRecordIndex = 0
            recentWireByteCount = 0
            rollingWireMegabitsPerSecondValue = nil
            return
        }
        let first = recentWireReceiveRecords[firstRecentWireReceiveRecordIndex]
        let elapsed = min(
            Self.rollingWireWindowSeconds,
            max(0.25, sample.receivedAt.timeIntervalSince(first.receivedAt))
        )
        rollingWireMegabitsPerSecondValue = megabitsPerSecond(
            byteCount: recentWireByteCount,
            elapsedSeconds: elapsed
        )
    }

    private mutating func compactRecentWireRecordsIfNeeded() {
        guard firstRecentWireReceiveRecordIndex > 64,
              firstRecentWireReceiveRecordIndex * 2 >= recentWireReceiveRecords.count
        else {
            return
        }
        recentWireReceiveRecords.removeFirst(firstRecentWireReceiveRecordIndex)
        firstRecentWireReceiveRecordIndex = 0
    }

    public mutating func recordDecodedFrame(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        decodedAt: Date,
        timing: RDPFrameDecodeTiming
    ) {
        if connectionStartedAt == nil {
            connectionStartedAt = receivedAt
        }
        if firstFrameReceivedAt == nil {
            firstFrameReceivedAt = receivedAt
        }
        lastFrameReceivedAt = receivedAt
        lastFrameDecodedAt = decodedAt
        decodedFrameCount += 1
        decodedByteCount += frame.payloadByteCount
        totalDecodeMilliseconds += timing.totalMilliseconds
        lastDecodeMilliseconds = timing.totalMilliseconds
        maxDecodeMilliseconds = max(maxDecodeMilliseconds ?? 0, timing.totalMilliseconds)
        totalSamplePreparationMilliseconds += timing.samplePreparationMilliseconds
        lastSamplePreparationMilliseconds = timing.samplePreparationMilliseconds
        maxSamplePreparationMilliseconds = max(
            maxSamplePreparationMilliseconds ?? 0,
            timing.samplePreparationMilliseconds
        )
        totalVideoToolboxMilliseconds += timing.videoToolboxMilliseconds
        lastVideoToolboxMilliseconds = timing.videoToolboxMilliseconds
        maxVideoToolboxMilliseconds = max(
            maxVideoToolboxMilliseconds ?? 0,
            timing.videoToolboxMilliseconds
        )
        totalImageConversionMilliseconds += timing.imageConversionMilliseconds
        lastImageConversionMilliseconds = timing.imageConversionMilliseconds
        maxImageConversionMilliseconds = max(
            maxImageConversionMilliseconds ?? 0,
            timing.imageConversionMilliseconds
        )
        decodedPixelFormat = timing.decodedPixelFormat
        usesHardwareAcceleration = timing.usesHardwareAcceleration
        totalCropMilliseconds += timing.cropMilliseconds
        lastCropMilliseconds = timing.cropMilliseconds
        maxCropMilliseconds = max(maxCropMilliseconds ?? 0, timing.cropMilliseconds)
        lastDecodeError = nil

        recentFrameDecodedAt.append(decodedAt)
        let cutoff = decodedAt.addingTimeInterval(-5)
        while firstRecentFrameDecodedAtIndex < recentFrameDecodedAt.count,
              recentFrameDecodedAt[firstRecentFrameDecodedAtIndex] < cutoff
        {
            firstRecentFrameDecodedAtIndex += 1
        }
        let earliestRetainedIndex = max(firstRecentFrameDecodedAtIndex, recentFrameDecodedAt.count - 240)
        if earliestRetainedIndex > firstRecentFrameDecodedAtIndex {
            firstRecentFrameDecodedAtIndex = earliestRetainedIndex
        }
        compactRecentFrameTimestampsIfNeeded()
    }

    private mutating func compactRecentFrameTimestampsIfNeeded() {
        guard firstRecentFrameDecodedAtIndex > 64,
              firstRecentFrameDecodedAtIndex * 2 >= recentFrameDecodedAt.count
        else {
            return
        }
        recentFrameDecodedAt.removeFirst(firstRecentFrameDecodedAtIndex)
        firstRecentFrameDecodedAtIndex = 0
    }

    public mutating func recordDecodeFailure(receivedAt: Date, errorDescription: String) {
        if connectionStartedAt == nil {
            connectionStartedAt = receivedAt
        }
        if firstFrameReceivedAt == nil {
            firstFrameReceivedAt = receivedAt
        }
        lastFrameReceivedAt = receivedAt
        failedDecodeCount += 1
        lastDecodeError = errorDescription
    }

    public mutating func recordSkippedDecodeFrames(_ count: Int, receivedAt: Date) {
        guard count > 0 else {
            return
        }
        if connectionStartedAt == nil {
            connectionStartedAt = receivedAt
        }
        skippedDecodeFrameCount += count
    }

    public mutating func recordSkippedPresentationFrame(at timestamp: Date) {
        if connectionStartedAt == nil {
            connectionStartedAt = timestamp
        }
        skippedPresentationFrameCount += 1
    }

    private func megabitsPerSecond(byteCount: Int, elapsedSeconds: TimeInterval) -> Double? {
        guard byteCount > 0, elapsedSeconds > 0 else {
            return nil
        }
        return Double(byteCount) * 8 / elapsedSeconds / 1_000_000
    }

    private func averageComponentMilliseconds(_ total: Double) -> Double? {
        guard decodedFrameCount > 0 else {
            return nil
        }
        return total / Double(decodedFrameCount)
    }
}

public final class RDPRenderMetricsStore: @unchecked Sendable {
    private static let snapshotIntervalSeconds = 0.5

    public private(set) var metrics = RDPRenderMetrics()
    private var lastSnapshotAt: Date?

    public init() {}

    public func reset(connectionStartedAt: Date? = nil) {
        metrics = RDPRenderMetrics(connectionStartedAt: connectionStartedAt)
        lastSnapshotAt = nil
    }

    public func recordWireReceive(_ sample: RDPWireReceiveSample) {
        metrics.recordWireReceive(sample)
    }

    public func recordDecodedFrame(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        decodedAt: Date,
        timing: RDPFrameDecodeTiming
    ) {
        metrics.recordDecodedFrame(
            frame,
            receivedAt: receivedAt,
            decodedAt: decodedAt,
            timing: timing
        )
    }

    public func recordDecodeFailure(receivedAt: Date, errorDescription: String) {
        metrics.recordDecodeFailure(
            receivedAt: receivedAt,
            errorDescription: errorDescription
        )
    }

    public func recordSkippedDecodeFrames(_ count: Int, receivedAt: Date) {
        metrics.recordSkippedDecodeFrames(count, receivedAt: receivedAt)
    }

    public func recordSkippedPresentationFrame(at timestamp: Date) {
        metrics.recordSkippedPresentationFrame(at: timestamp)
    }

    public func snapshotIfNeeded(force: Bool = false, at timestamp: Date = Date()) -> RDPRenderMetrics? {
        if force {
            lastSnapshotAt = timestamp
            return metrics
        }

        guard let lastSnapshotAt else {
            lastSnapshotAt = timestamp
            return metrics
        }

        guard timestamp.timeIntervalSince(lastSnapshotAt) >= Self.snapshotIntervalSeconds else {
            return nil
        }

        self.lastSnapshotAt = timestamp
        return metrics
    }
}

public final class RDPWireReceiveMetricsCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let flushDelay: DispatchTimeInterval
    private let shouldCancel: () -> Bool
    private let onFlush: (RDPWireReceiveSample) -> Void
    private var pendingByteCount = 0
    private var pendingReceivedAt: Date?
    private var isFlushScheduled = false
    private var isCancelled = false

    public init(
        flushDelay: DispatchTimeInterval = .milliseconds(250),
        shouldCancel: @escaping () -> Bool,
        onFlush: @escaping (RDPWireReceiveSample) -> Void
    ) {
        self.flushDelay = flushDelay
        self.shouldCancel = shouldCancel
        self.onFlush = onFlush
    }

    public func record(_ sample: RDPWireReceiveSample) {
        let shouldScheduleFlush: Bool

        lock.lock()
        guard !isCancelled, !shouldCancel() else {
            lock.unlock()
            return
        }

        pendingByteCount += sample.byteCount
        pendingReceivedAt = sample.receivedAt
        shouldScheduleFlush = !isFlushScheduled
        if shouldScheduleFlush {
            isFlushScheduled = true
        }
        lock.unlock()

        if shouldScheduleFlush {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + flushDelay) { [weak self] in
                self?.flushScheduled()
            }
        }
    }

    public func flush() {
        flushPending()
    }

    public func takePendingSample() -> RDPWireReceiveSample? {
        let sample: RDPWireReceiveSample?

        lock.lock()
        isFlushScheduled = false
        if isCancelled || pendingByteCount == 0 {
            pendingByteCount = 0
            pendingReceivedAt = nil
            sample = nil
        } else {
            sample = RDPWireReceiveSample(
                byteCount: pendingByteCount,
                receivedAt: pendingReceivedAt ?? Date()
            )
            pendingByteCount = 0
            pendingReceivedAt = nil
        }
        lock.unlock()

        return sample
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        pendingByteCount = 0
        pendingReceivedAt = nil
        isFlushScheduled = false
        lock.unlock()
    }

    private func flushScheduled() {
        flushPending()
    }

    private func flushPending() {
        if let sample = takePendingSample() {
            onFlush(sample)
        }
    }
}
