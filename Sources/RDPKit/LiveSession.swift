import Foundation

/// Runs one connection attempt for an application whose interface lives on the main thread.
/// `start(events:run:)` calls `run` on a thread of its own, as `RDPSessionClient.run` blocks
/// for the whole session, and hands it what to pass on to `RDPSessionClient.run`:
/// - `onGraphicsFrame` decodes each frame on an `RDPFrameDecodeQueue`, which `events` hears
///   of on the main queue. A frame that fails to decode is reported to the session as not
///   presented, so the session goes on and asks for a keyframe, and one none of whose frames
///   decode ends with `RDPConnectionFailure.noFramePresented` rather than waiting forever.
/// - `onWireReceive` coalesces the wire samples for `events.onWireReceive`.
/// - `liveReport` and `cancellation` are this session's.
///
/// The other handlers `run` passes run on the session thread as `RDPSessionClient.run` calls
/// them, and hand their main-thread part to `deliver(_:)`. What is delivered runs on the main
/// queue in the order it was handed over, after the frames and samples before it, and none of
/// it once `cancel()` has returned, so a session the application left can no longer change
/// what it shows. Make one per attempt.
public final class RDPLiveSession: @unchecked Sendable {
    /// What the session reports to the application.
    public struct Events: Sendable {
        /// A frame decoded and ready to present, with when it arrived and was decoded.
        public var onFrameDecoded: @MainActor @Sendable (
            RDPDecodedFramePresentation,
            _ receivedAt: Date,
            _ decodedAt: Date,
            RDPFrameDecodeTiming
        ) -> Void
        /// A frame that did not decode, such as video waiting for a keyframe; the session
        /// goes on.
        public var onFrameDecodeFailed: @MainActor @Sendable (_ receivedAt: Date, _ errorDescription: String) -> Void
        /// The bytes received since the last sample, at most every quarter second and once
        /// more before `onEnd`.
        public var onWireReceive: (@MainActor @Sendable (RDPWireReceiveSample) -> Void)?
        /// The session ended on its own: called on the session thread with its report, so
        /// slow work such as decoding the report's first frame stays off the main thread; hand
        /// the rest to `deliver(_:)`. Not called once the session was cancelled, by `cancel()`
        /// or through its `cancellation`.
        public var onEnd: @Sendable (RDPConnectionReport) -> Void

        public init(
            onFrameDecoded: @escaping @MainActor @Sendable (RDPDecodedFramePresentation, Date, Date, RDPFrameDecodeTiming) -> Void,
            onFrameDecodeFailed: @escaping @MainActor @Sendable (Date, String) -> Void,
            onWireReceive: (@MainActor @Sendable (RDPWireReceiveSample) -> Void)? = nil,
            onEnd: @escaping @Sendable (RDPConnectionReport) -> Void
        ) {
            self.onFrameDecoded = onFrameDecoded
            self.onFrameDecodeFailed = onFrameDecodeFailed
            self.onWireReceive = onWireReceive
            self.onEnd = onEnd
        }
    }

    /// What `run` passes on to `RDPSessionClient.run`, along with its own handlers.
    public struct Run: @unchecked Sendable {
        public let onGraphicsFrame: RDPGraphicsFrameHandler
        public let onWireReceive: RDPWireReceiveHandler
        public let liveReport: RDPLiveConnectionReport
        public let cancellation: RDPConnectionCancellation
    }

    public let cancellation = RDPConnectionCancellation()
    public let liveReport = RDPLiveConnectionReport()
    private let threadName: String
    private let lock = NSLock()
    private var isDelivering = true
    private var hasStarted = false

    /// `threadName` names the session's thread, as debuggers and crash reports show it.
    public init(threadName: String = "RDPKit session") {
        self.threadName = threadName
    }

    /// Starts the session on its thread; a session starts once.
    public func start(events: Events, run: @escaping @Sendable (Run) -> RDPConnectionReport) {
        let isFirstStart = lock.withLock {
            defer { hasStarted = true }
            return hasStarted == false
        }
        precondition(isFirstStart, "An RDPLiveSession starts once; make one per attempt.")
        let thread = Thread { [self] in
            runSession(events: events, run: run)
        }
        thread.name = threadName
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `work` on the main queue after what was delivered before it, unless `cancel()` has
    /// returned by then.
    public func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard lock.withLock({ isDelivering }) else {
                    return
                }
                work()
            }
        }
    }

    /// Ends the session: nothing delivered runs once this returns, and the session's thread
    /// closes the connection and stops decoding.
    @MainActor
    public func cancel() {
        lock.withLock {
            isDelivering = false
        }
        cancellation.cancel()
    }

    private func runSession(events: Events, run: @Sendable (Run) -> RDPConnectionReport) {
        let cancellation = cancellation
        let decodeQueue = RDPFrameDecodeQueue(
            shouldCancel: {
                cancellation.isCancelled
            },
            onDecoded: { [self] presentation, receivedAt, decodedAt, timing in
                deliver {
                    events.onFrameDecoded(presentation, receivedAt, decodedAt, timing)
                }
            },
            onDecodeFailed: { [self] receivedAt, errorDescription in
                deliver {
                    events.onFrameDecodeFailed(receivedAt, errorDescription)
                }
            }
        )
        let wireReceiveCoalescer = RDPWireReceiveMetricsCoalescer(
            shouldCancel: {
                cancellation.isCancelled
            },
            onFlush: { [self] sample in
                if let onWireReceive = events.onWireReceive {
                    deliver {
                        onWireReceive(sample)
                    }
                }
            }
        )
        let report = run(Run(
            onGraphicsFrame: { frame in
                try decodeQueue.submitAndWait(
                    frame,
                    receivedAt: Date(),
                    shouldContinue: {
                        cancellation.isCancelled == false
                    }
                ).requirePresented()
            },
            onWireReceive: { sample in
                wireReceiveCoalescer.record(sample)
            },
            liveReport: liveReport,
            cancellation: cancellation
        ))
        // Taken before the coalescer stops, so a timed flush cannot follow it.
        let finalWireReceiveSample = wireReceiveCoalescer.takePendingSample()
        wireReceiveCoalescer.cancel()
        decodeQueue.cancel()
        guard cancellation.isCancelled == false else {
            return
        }
        if let finalWireReceiveSample, let onWireReceive = events.onWireReceive {
            deliver {
                onWireReceive(finalWireReceiveSample)
            }
        }
        events.onEnd(report)
    }
}
