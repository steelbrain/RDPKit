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
///
/// The main queue has to run on the main thread, as it does under an app's run loop,
/// `RunLoop.main.run()` or an `async` `@main`. Under `dispatchMain()` it runs on another
/// thread, and the first delivery stops the process with a message saying so.
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
        /// The server's layout as of a frame, before that frame is decoded or fails to: with
        /// each connection's first frame, a Server Redirection's included, and with each frame
        /// whose layout differs from the one before, such as after a ResetGraphics, even to the
        /// same monitors. A connection is told apart by the `liveReport` that `run` passes on.
        public var onServerLayout: (@MainActor @Sendable (RDPServerLayout) -> Void)?
        /// The session ended on its own: called on the session thread with its report, so
        /// slow work such as decoding the report's first frame stays off the main thread; hand
        /// the rest to `deliver(_:)`. Not called once the session was cancelled, by `cancel()`
        /// or through its `cancellation`.
        public var onEnd: @Sendable (RDPConnectionReport) -> Void

        public init(
            onFrameDecoded: @escaping @MainActor @Sendable (RDPDecodedFramePresentation, Date, Date, RDPFrameDecodeTiming) -> Void,
            onFrameDecodeFailed: @escaping @MainActor @Sendable (Date, String) -> Void,
            onWireReceive: (@MainActor @Sendable (RDPWireReceiveSample) -> Void)? = nil,
            onServerLayout: (@MainActor @Sendable (RDPServerLayout) -> Void)? = nil,
            onEnd: @escaping @Sendable (RDPConnectionReport) -> Void
        ) {
            self.onFrameDecoded = onFrameDecoded
            self.onFrameDecodeFailed = onFrameDecodeFailed
            self.onWireReceive = onWireReceive
            self.onServerLayout = onServerLayout
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
    private var hasEnded = false
    /// The layout delivered last, and the `liveReport` connection its frame came on.
    private var deliveredServerLayout: (connection: Int, layout: RDPServerLayout)?
    private var endWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

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
        // Not written in the call: Swift checks a closure written there as main-actor code on
        // entry, which would warn of a data race ahead of the message below.
        let delivery: @Sendable () -> Void = { [self] in
            runOnMainQueueAsMainActor("RDPLiveSession") {
                guard lock.withLock({ isDelivering }) else {
                    return
                }
                work()
            }
        }
        DispatchQueue.main.async(execute: delivery)
    }

    /// Hands main-thread work to `object` through ``deliver(_:)`` while holding it weakly. Make
    /// one before ``start(events:run:)`` and let the handlers capture it in place of `object`,
    /// such as the view controller showing the session, so the session's thread does not keep
    /// a closed one alive.
    public func recipient<Object: AnyObject & Sendable>(_ object: Object) -> Recipient<Object> {
        Recipient(object: object, session: self)
    }

    /// An object that work from the session's thread runs with on the main queue; see
    /// ``RDPLiveSession/recipient(_:)``.
    public struct Recipient<Object: AnyObject & Sendable>: Sendable {
        private weak var object: Object?
        private let session: RDPLiveSession

        fileprivate init(object: Object, session: RDPLiveSession) {
            self.object = object
            self.session = session
        }

        /// Runs `work` with the object on the main queue, as ``RDPLiveSession/deliver(_:)``
        /// runs work, unless the object is gone by then.
        public func deliver(_ work: @escaping @MainActor @Sendable (Object) -> Void) {
            session.deliver { [weak object] in
                guard let object else {
                    return
                }
                work(object)
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

    /// Waits until the session's thread is done, up to `timeout` seconds: true once `run` has
    /// returned, which closes the connection, and `onEnd` too, if it was called; false when
    /// `timeout` passes first. A session that never started returns true at once. An app that
    /// quits waits on this after `cancel()`, so the session's thread tells the server the
    /// session is over and closes the connection, rather than the server seeing it drop when
    /// the process exits.
    public func waitUntilEnded(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        // Clamped to some 30 years, which DispatchTime holds.
        let seconds = timeout.isNaN ? 0 : min(max(timeout, 0), 1_000_000_000)
        return await withCheckedContinuation { continuation in
            let isDone = lock.withLock {
                guard hasStarted, !hasEnded else {
                    return true
                }
                endWaiters[id] = continuation
                return false
            }
            if isDone {
                continuation.resume(returning: true)
                return
            }
            // Weakly, so a long timeout does not keep an ended session alive: until it ends,
            // its thread holds it, and ending resumes every waiter.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.lock.withLock { self?.endWaiters.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
    }

    private func runSession(events: Events, run: @Sendable (Run) -> RDPConnectionReport) {
        defer {
            end()
        }
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
            onGraphicsFrame: { [self] frame in
                deliverServerLayout(of: frame, to: events.onServerLayout)
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

    /// Delivers the frame's layout when it differs from the one delivered last or came on
    /// another connection, before the frame goes to the decoder, whose result is delivered
    /// after it.
    private func deliverServerLayout(
        of frame: RDPGraphicsFrameSnapshot,
        to onServerLayout: (@MainActor @Sendable (RDPServerLayout) -> Void)?
    ) {
        guard let onServerLayout else {
            return
        }
        let layout = RDPServerLayout(frame)
        let connection = liveReport.connectionCount
        let isNew = lock.withLock {
            defer { deliveredServerLayout = (connection, layout) }
            return deliveredServerLayout?.connection != connection || deliveredServerLayout?.layout != layout
        }
        if isNew {
            deliver {
                onServerLayout(layout)
            }
        }
    }

    private func end() {
        let waiters = lock.withLock {
            hasEnded = true
            defer { endWaiters.removeAll() }
            return Array(endWaiters.values)
        }
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }
}

/// Runs `body` as main-actor code from a block that the main queue runs, or stops the process
/// with a message naming `owner` when the main queue runs off the main thread, as it does
/// under `dispatchMain()`. Swift's older isolation check, which an executable linked against
/// an older SDK gets, takes only the main thread for the main actor, so `MainActor.assumeIsolated`
/// would stop it there with "Incorrect actor executor assumption" and no cause.
func runOnMainQueueAsMainActor(_ owner: String, _ body: @MainActor () -> Void) {
    guard Thread.isMainThread else {
        fatalError(
            "\(owner) needs the main queue to run on the main thread, as it does under an app's run "
                + "loop, RunLoop.main.run() or an async @main; under dispatchMain() it runs on another thread"
        )
    }
    MainActor.assumeIsolated(body)
}
