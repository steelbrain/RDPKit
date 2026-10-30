import Foundation

public struct RDPRenderMetrics: Equatable, Sendable {
    private struct WireReceiveRecord: Equatable, Sendable {
        var receivedAt: Date
        var byteCount: Int
    }

    private static let rollingWindowSeconds = 5.0
    private static let rollingFrameLimit = 240

    public var connectionStartedAt: Date?
    public var firstFrameReceivedAt: Date?
    public var lastFrameReceivedAt: Date?
    public var lastFrameDecodedAt: Date?
    public var decodedFrameCount = 0
    public var failedDecodeCount = 0
    public var skippedPresentationFrameCount = 0
    public var decodedByteCount = 0
    public var wireByteCount = 0
    public var totalDecodeMilliseconds = 0.0
    public var lastDecodeMilliseconds: Double?
    public var maxDecodeMilliseconds: Double?
    public var totalSamplePreparationMilliseconds = 0.0
    public var lastSamplePreparationMilliseconds: Double?
    public var totalVideoToolboxMilliseconds = 0.0
    public var lastVideoToolboxMilliseconds: Double?
    public var totalImageConversionMilliseconds = 0.0
    public var lastImageConversionMilliseconds: Double?
    public var decodedPixelFormat: UInt32?
    public var usesHardwareAcceleration: Bool?
    public var lastDecodeError: String?
    // At most rollingFrameLimit decode times from the last rollingWindowSeconds.
    private var recentFrameDecodedAt: [Date] = []
    // Wire records keep a moving start index and compact lazily, so trimming per packet stays amortized O(1).
    private var recentWireReceiveRecords: [WireReceiveRecord] = []
    private var firstRecentWireReceiveRecordIndex = 0
    private var recentWireByteCount = 0
    private var rollingWireMegabitsPerSecondValue: Double?

    public init(connectionStartedAt: Date? = nil) {
        self.connectionStartedAt = connectionStartedAt
    }

    public var hasActivity: Bool {
        connectionStartedAt != nil
            || decodedFrameCount > 0
            || failedDecodeCount > 0
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
        averageComponentMilliseconds(totalDecodeMilliseconds)
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

    /// The rate as of the last decoded frame, so it holds when frames stop.
    @available(*, deprecated, message: "Use rollingFramesPerSecond(at:), which falls when frames stop.")
    public var rollingFramesPerSecond: Double? {
        guard recentFrameDecodedAt.count > 1,
              let first = recentFrameDecodedAt.first,
              let last = recentFrameDecodedAt.last
        else {
            return nil
        }
        let elapsed = last.timeIntervalSince(first)
        guard elapsed > 0 else {
            return nil
        }
        return Double(recentFrameDecodedAt.count - 1) / elapsed
    }

    /// The rate as of the last wire sample, so it holds when traffic stops.
    @available(*, deprecated, message: "Use rollingWireMegabitsPerSecond(at:), which falls when traffic stops.")
    public var rollingWireMegabitsPerSecond: Double? {
        rollingWireMegabitsPerSecondValue
    }

    /// Frames decoded per second in the 5 s up to `date`. It falls as `date`
    /// moves past the last frame, to 0 once fewer than two frames are left in
    /// that window. Nil until two frames have been decoded.
    public func rollingFramesPerSecond(at date: Date) -> Double? {
        guard decodedFrameCount > 1 else {
            return nil
        }
        let cutoff = date.addingTimeInterval(-Self.rollingWindowSeconds)
        let recent = recentFrameDecodedAt.drop { $0 < cutoff }
        guard recent.count > 1, let first = recent.first, let last = recent.last else {
            return 0
        }
        let elapsed = max(date, last).timeIntervalSince(first)
        guard elapsed > 0 else {
            return nil
        }
        return Double(recent.count - 1) / elapsed
    }

    /// Megabits received per second in the 5 s up to `date`. It falls as
    /// `date` moves past the last sample, to 0 once none is left in that
    /// window. Nil until bytes have been received.
    public func rollingWireMegabitsPerSecond(at date: Date) -> Double? {
        guard wireByteCount > 0 else {
            return nil
        }
        let cutoff = date.addingTimeInterval(-Self.rollingWindowSeconds)
        var firstIndex = firstRecentWireReceiveRecordIndex
        var byteCount = recentWireByteCount
        while firstIndex < recentWireReceiveRecords.count,
              recentWireReceiveRecords[firstIndex].receivedAt < cutoff
        {
            byteCount -= recentWireReceiveRecords[firstIndex].byteCount
            firstIndex += 1
        }
        guard firstIndex < recentWireReceiveRecords.count, let last = recentWireReceiveRecords.last else {
            return 0
        }
        let first = recentWireReceiveRecords[firstIndex]
        let elapsed = min(
            Self.rollingWindowSeconds,
            max(0.25, max(date, last.receivedAt).timeIntervalSince(first.receivedAt))
        )
        return megabitsPerSecond(byteCount: byteCount, elapsedSeconds: elapsed) ?? 0
    }

    /// The rate up to now, read from the clock on each access.
    @available(*, deprecated, message: "Use averageWireMegabitsPerSecond(at:), which reads at a given time.")
    public var averageWireMegabitsPerSecond: Double? {
        averageWireMegabitsPerSecond(at: Date())
    }

    /// Megabits received per second from `connectionStartedAt` to `date`, over at least
    /// 0.25 s. Nil until bytes have been received.
    public func averageWireMegabitsPerSecond(at date: Date) -> Double? {
        guard let connectionStartedAt else {
            return nil
        }
        let elapsed = max(0.25, date.timeIntervalSince(connectionStartedAt))
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
        let cutoff = sample.receivedAt.addingTimeInterval(-Self.rollingWindowSeconds)
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
            Self.rollingWindowSeconds,
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
        totalVideoToolboxMilliseconds += timing.videoToolboxMilliseconds
        lastVideoToolboxMilliseconds = timing.videoToolboxMilliseconds
        totalImageConversionMilliseconds += timing.imageConversionMilliseconds
        lastImageConversionMilliseconds = timing.imageConversionMilliseconds
        decodedPixelFormat = timing.decodedPixelFormat
        usesHardwareAcceleration = timing.usesHardwareAcceleration
        lastDecodeError = nil

        recentFrameDecodedAt.append(decodedAt)
        let cutoff = decodedAt.addingTimeInterval(-Self.rollingWindowSeconds)
        let staleFrameCount = max(
            recentFrameDecodedAt.prefix { $0 < cutoff }.count,
            recentFrameDecodedAt.count - Self.rollingFrameLimit
        )
        recentFrameDecodedAt.removeFirst(staleFrameCount)
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

    private let lock = NSLock()
    private var storedMetrics = RDPRenderMetrics()
    private var lastSnapshotAt: Date?

    public init() {}

    public var metrics: RDPRenderMetrics {
        lock.withLock { storedMetrics }
    }

    public func reset(connectionStartedAt: Date? = nil) {
        lock.withLock {
            storedMetrics = RDPRenderMetrics(connectionStartedAt: connectionStartedAt)
            lastSnapshotAt = nil
        }
    }

    public func recordWireReceive(_ sample: RDPWireReceiveSample) {
        lock.withLock { storedMetrics.recordWireReceive(sample) }
    }

    public func recordDecodedFrame(
        _ frame: RDPGraphicsFrameSnapshot,
        receivedAt: Date,
        decodedAt: Date,
        timing: RDPFrameDecodeTiming
    ) {
        lock.withLock {
            storedMetrics.recordDecodedFrame(frame, receivedAt: receivedAt, decodedAt: decodedAt, timing: timing)
        }
    }

    public func recordDecodeFailure(receivedAt: Date, errorDescription: String) {
        lock.withLock { storedMetrics.recordDecodeFailure(receivedAt: receivedAt, errorDescription: errorDescription) }
    }

    public func recordSkippedPresentationFrame(at timestamp: Date) {
        lock.withLock { storedMetrics.recordSkippedPresentationFrame(at: timestamp) }
    }

    /// Returns the metrics at most every 0.5 s unless forced.
    public func snapshotIfNeeded(force: Bool = false, at timestamp: Date = Date()) -> RDPRenderMetrics? {
        lock.withLock {
            if !force,
               let lastSnapshotAt,
               timestamp.timeIntervalSince(lastSnapshotAt) < Self.snapshotIntervalSeconds
            {
                return nil
            }
            lastSnapshotAt = timestamp
            return storedMetrics
        }
    }
}

public final class RDPWireReceiveMetricsCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    // Timed flushes run here, so `cancel()` can wait for one in progress.
    private let flushQueue = DispatchQueue(label: "RDPKit.WireReceiveMetricsFlush", qos: .utility)
    private let flushQueueKey = DispatchSpecificKey<Void>()
    private let flushDelay: DispatchTimeInterval
    private let shouldCancel: @Sendable () -> Bool
    private let onFlush: @Sendable (RDPWireReceiveSample) -> Void
    private var pendingByteCount = 0
    private var pendingReceivedAt: Date?
    private var isFlushScheduled = false
    private var isCancelled = false

    /// A timed flush calls `onFlush` on a thread of its own.
    public init(
        flushDelay: DispatchTimeInterval = .milliseconds(250),
        shouldCancel: @escaping @Sendable () -> Bool,
        onFlush: @escaping @Sendable (RDPWireReceiveSample) -> Void
    ) {
        self.flushDelay = flushDelay
        self.shouldCancel = shouldCancel
        self.onFlush = onFlush
        flushQueue.setSpecific(key: flushQueueKey, value: ())
    }

    public func record(_ sample: RDPWireReceiveSample) {
        guard !shouldCancel() else {
            return
        }
        let shouldScheduleFlush: Bool = lock.withLock {
            guard !isCancelled else {
                return false
            }
            pendingByteCount += sample.byteCount
            pendingReceivedAt = sample.receivedAt
            let shouldScheduleFlush = !isFlushScheduled
            isFlushScheduled = true
            return shouldScheduleFlush
        }

        if shouldScheduleFlush {
            flushQueue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
                self?.flush()
            }
        }
    }

    public func flush() {
        if let sample = takePendingSample() {
            onFlush(sample)
        }
    }

    public func takePendingSample() -> RDPWireReceiveSample? {
        lock.withLock {
            defer {
                pendingByteCount = 0
                pendingReceivedAt = nil
                isFlushScheduled = false
            }
            guard !isCancelled, pendingByteCount > 0 else {
                return nil
            }
            return RDPWireReceiveSample(byteCount: pendingByteCount, receivedAt: pendingReceivedAt ?? Date())
        }
    }

    /// Once this returns, `onFlush` does not run again: a timed flush in progress finishes first.
    public func cancel() {
        lock.withLock {
            isCancelled = true
            pendingByteCount = 0
            pendingReceivedAt = nil
            isFlushScheduled = false
        }
        if DispatchQueue.getSpecific(key: flushQueueKey) == nil {
            flushQueue.sync {}
        }
    }
}
