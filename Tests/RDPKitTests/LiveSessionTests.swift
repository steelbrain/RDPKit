import Foundation
@testable import RDPKit
import Testing

/// What a live session handed the application, in the order it did.
private final class Received: @unchecked Sendable {
    let lock = NSLock()
    var events: [String] = []
    var endedOnMainThread: Bool?
    var ended = DispatchSemaphore(value: 0)

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] {
        lock.withLock { events }
    }
}

/// The end is recorded through `deliver`, as an application hands its main-thread part over.
private func events(_ received: Received, of session: RDPLiveSession) -> RDPLiveSession.Events {
    RDPLiveSession.Events(
        onFrameDecoded: { presentation, _, _, _ in
            received.append("decoded \(presentation.frame.frameID ?? 0)")
        },
        onFrameDecodeFailed: { _, _ in
            received.append("failed")
        },
        onWireReceive: { sample in
            received.append("wire \(sample.byteCount)")
        },
        onEnd: { report in
            received.lock.withLock { received.endedOnMainThread = Thread.isMainThread }
            session.deliver {
                received.append("end \(report.status)")
                received.ended.signal()
            }
        }
    )
}

/// Waits on a thread of its own, so the main queue that delivers the events keeps running.
private func wait(for semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 10) == .success)
        }
    }
}

/// Waits on the calling thread, as a test that must hold the main actor does.
private func blockingWait(for semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}

/// Runs what the main queue holds, such as the events delivered so far.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private func report(status: String) -> RDPConnectionReport {
    RDPConnectionReport(
        status: status,
        stage: "rdp-graphics-dynamic-channel",
        target: "example.test:3389",
        passwordConfigured: false,
        requestedProtocols: ["tls"],
        requestHex: "",
        warnings: []
    )
}

private func bitmapFrame(id: UInt32) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data([0, 0, 0, 255]),
        decodedBitmapBytesPerRow: 4
    )
}

/// A P-frame with no keyframe before it, which VideoToolbox cannot decode.
private func undecodableVideoFrame(id: UInt32) -> RDPGraphicsFrameSnapshot {
    let rect = RDPFrameRect(left: 0, top: 0, right: 4, bottom: 4)
    return RDPGraphicsFrameSnapshot(
        frameID: id,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: rect,
        regionRects: [rect],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x01, 0xFF])
    )
}

/// The session runs on a named thread of its own; a decoded frame reaches the application and
/// the session goes on, a frame that fails to decode is reported to it and to the session as
/// not presented, wire samples are coalesced with the last one sent before the end, and work
/// handed to `deliver` keeps its place among the events. The end comes on the session thread.
@Test(.timeLimit(.minutes(1)))
func liveSessionDecodesFramesAndDeliversEventsInOrder() async throws {
    let received = Received()
    let session = RDPLiveSession(threadName: "Test session")
    let threadName = Locked<String?>(nil)
    let notPresented = Locked<String?>(nil)
    session.start(events: events(received, of: session)) { run in
        threadName.withLock { $0 = Thread.current.name }
        #expect(Thread.isMainThread == false)
        #expect(run.liveReport === session.liveReport)
        #expect(run.cancellation === session.cancellation)
        try? run.onGraphicsFrame(bitmapFrame(id: 1))
        session.deliver {
            received.append("delivered")
        }
        do {
            try run.onGraphicsFrame(undecodableVideoFrame(id: 2))
        } catch let error as RDPGraphicsFrameNotPresented {
            notPresented.withLock { $0 = error.reason }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        run.onWireReceive(RDPWireReceiveSample(byteCount: 10, receivedAt: Date()))
        run.onWireReceive(RDPWireReceiveSample(byteCount: 20, receivedAt: Date()))
        return report(status: "success")
    }

    #expect(await wait(for: received.ended))
    await drainMainQueue()
    #expect(threadName.value == "Test session")
    #expect(notPresented.value != nil)
    #expect(received.snapshot == ["decoded 1", "delivered", "failed", "wire 30", "end success"])
    #expect(received.endedOnMainThread == false)
}

/// Once `cancel()` returns nothing more reaches the application, not even what the session
/// delivered before it that had not run yet, and the session sees its cancellation and gets no
/// end.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aCancelledLiveSessionDeliversNothingMore() async throws {
    let received = Received()
    let session = RDPLiveSession()
    let delivered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let sawCancellation = Locked(false)
    session.start(events: events(received, of: session)) { run in
        session.deliver {
            received.append("before cancel")
        }
        delivered.signal()
        proceed.wait()
        sawCancellation.withLock { $0 = run.cancellation.isCancelled }
        try? run.onGraphicsFrame(bitmapFrame(id: 1))
        session.deliver {
            received.append("after cancel")
        }
        run.onWireReceive(RDPWireReceiveSample(byteCount: 10, receivedAt: Date()))
        finished.signal()
        return report(status: "cancelled")
    }

    // The main actor waits here, so the delivery is still queued when the session is cancelled.
    #expect(blockingWait(for: delivered))
    session.cancel()
    proceed.signal()
    #expect(await wait(for: finished))
    // Long enough for an end, which would come right after `run` returns.
    try await Task.sleep(for: .milliseconds(300))
    await drainMainQueue()
    #expect(sawCancellation.value)
    #expect(received.snapshot == [])
}

/// A session cancelled through its cancellation, as a certificate the application refuses on
/// the session thread cancels it, still delivers what it hands over, such as why, but ends
/// with no end of its own.
@Test(.timeLimit(.minutes(1)))
func aSessionCancelledThroughItsCancellationStillDelivers() async throws {
    let received = Received()
    let session = RDPLiveSession()
    let finished = DispatchSemaphore(value: 0)
    session.start(events: events(received, of: session)) { run in
        run.cancellation.cancel()
        session.deliver {
            received.append("refused")
        }
        finished.signal()
        return report(status: "cancelled")
    }

    #expect(await wait(for: finished))
    try await Task.sleep(for: .milliseconds(300))
    await drainMainQueue()
    #expect(received.snapshot == ["refused"])
}

/// `waitUntilEnded(timeout:)` returns once the session's thread is done with `run` and with
/// `onEnd`, for every caller waiting; false when the time runs out first, and true at once for
/// a session that never started or has ended.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aLiveSessionCanBeWaitedOnUntilItEnds() async throws {
    #expect(await RDPLiveSession().waitUntilEnded(timeout: 30))

    let session = RDPLiveSession()
    let returned = Locked(false)
    session.start(events: events(Received(), of: session)) { run in
        while !run.cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // As closing the connection takes a moment after the cancellation.
        Thread.sleep(forTimeInterval: 0.2)
        returned.withLock { $0 = true }
        return report(status: "cancelled")
    }
    let waitStarted = ContinuousClock.now
    #expect(await session.waitUntilEnded(timeout: 0.2) == false)
    #expect(ContinuousClock.now - waitStarted < .seconds(10))
    async let first = session.waitUntilEnded(timeout: 30)
    async let second = session.waitUntilEnded(timeout: 30)
    session.cancel()
    #expect(await [first, second] == [true, true])
    #expect(returned.value)
    #expect(await session.waitUntilEnded(timeout: 0))

    let ending = RDPLiveSession()
    let endReturned = Locked(false)
    ending.start(events: RDPLiveSession.Events(
        onFrameDecoded: { _, _, _, _ in },
        onFrameDecodeFailed: { _, _ in },
        onEnd: { _ in
            Thread.sleep(forTimeInterval: 0.2)
            endReturned.withLock { $0 = true }
        }
    )) { _ in
        report(status: "success")
    }
    #expect(await ending.waitUntilEnded(timeout: 30))
    #expect(endReturned.value)
}

/// Waiting with a long timeout does not keep a session alive once it has ended.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aLiveSessionWaitedOnLongIsFreedOnceItEnds() async throws {
    var session = RDPLiveSession()
    let proceed = DispatchSemaphore(value: 0)
    session.start(events: events(Received(), of: session)) { _ in
        proceed.wait()
        return report(status: "success")
    }
    async let ended = session.waitUntilEnded(timeout: 3600)
    // Lets the wait start before the session ends.
    try await Task.sleep(nanoseconds: 100_000_000)
    proceed.signal()
    #expect(await ended)
    // Once its thread is done, only the test holds the session.
    let deadline = ContinuousClock.now + .seconds(10)
    while !isKnownUniquelyReferenced(&session), ContinuousClock.now < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(isKnownUniquelyReferenced(&session))
}

/// A recipient hands work to its object while the object lives, without keeping it alive.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aLiveSessionsRecipientHoldsItsObjectWeakly() async throws {
    @MainActor
    final class Controller {
        var events: [String] = []
    }
    let session = RDPLiveSession()
    var controller: Controller? = Controller()
    let recipient = session.recipient(try #require(controller))
    #expect(isKnownUniquelyReferenced(&controller))
    let received = Locked([String]())

    recipient.deliver { controller in
        controller.events.append("first")
        received.withLock { $0.append("first") }
    }
    await drainMainQueue()
    #expect(controller?.events == ["first"])

    controller = nil
    recipient.deliver { _ in
        received.withLock { $0.append("after release") }
    }
    await drainMainQueue()
    #expect(received.value == ["first"])
}

/// The server's layout comes with the first frame and with each frame whose layout differs,
/// before that frame's result, also one that fails to decode.
@Test(.timeLimit(.minutes(1)))
func aLiveSessionDeliversTheServersLayoutBeforeItsFrames() async throws {
    let received = Received()
    let session = RDPLiveSession()
    let monitor = RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1), isPrimary: true)
    func frame(_ id: UInt32, resets: UInt32, monitors: [RDPRemoteMonitor] = []) -> RDPGraphicsFrameSnapshot {
        var frame = id == 4 ? undecodableVideoFrame(id: id) : bitmapFrame(id: id)
        frame.graphicsResetCount = resets
        frame.monitors = monitors
        return frame
    }
    let frames = [
        frame(1, resets: 0),
        frame(2, resets: 0),
        frame(3, resets: 1, monitors: [monitor]),
        frame(4, resets: 2, monitors: [monitor]),
        frame(5, resets: 2),
    ]
    session.start(events: RDPLiveSession.Events(
        onFrameDecoded: { presentation, _, _, _ in
            received.append("decoded \(presentation.frame.frameID ?? 0)")
        },
        onFrameDecodeFailed: { _, _ in
            received.append("failed")
        },
        onServerLayout: { layout in
            received.append("layout \(layout.graphicsResetCount) \(layout.monitors.count)")
        },
        onEnd: { _ in
            session.deliver {
                received.ended.signal()
            }
        }
    )) { run in
        for frame in frames {
            try? run.onGraphicsFrame(frame)
        }
        return report(status: "success")
    }

    #expect(await wait(for: received.ended))
    #expect(received.snapshot == [
        "layout 0 0", "decoded 1", "decoded 2",
        "layout 1 1", "decoded 3",
        "layout 2 1", "failed",
        "layout 2 0", "decoded 5",
    ])
}

/// Each connection's first frame comes with the server's layout, though a Server Redirection's
/// server lays out the same monitors as the one before; the frames after it on the same
/// connection do not repeat it.
@Test(.timeLimit(.minutes(1)))
func aLiveSessionDeliversTheServersLayoutOncePerConnection() async throws {
    let received = Received()
    let session = RDPLiveSession()
    let monitor = RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1), isPrimary: true)
    let frames = (1 ... 4).map { id in
        var frame = bitmapFrame(id: UInt32(id))
        frame.graphicsResetCount = 1
        frame.monitors = [monitor]
        return frame
    }
    session.start(events: RDPLiveSession.Events(
        onFrameDecoded: { presentation, _, _, _ in
            received.append("decoded \(presentation.frame.frameID ?? 0)")
        },
        onFrameDecodeFailed: { _, _ in
            received.append("failed")
        },
        onServerLayout: { layout in
            received.append("layout \(layout.graphicsResetCount) \(layout.monitors.count)")
        },
        onEnd: { _ in
            session.deliver {
                received.ended.signal()
            }
        }
    )) { run in
        for (index, frame) in frames.enumerated() {
            if index % 2 == 0 {
                run.liveReport.follow(RDPConnectionReportStorage(report(status: "connecting")))
            }
            try? run.onGraphicsFrame(frame)
        }
        return report(status: "success")
    }

    #expect(await wait(for: received.ended))
    #expect(received.snapshot == [
        "layout 1 1", "decoded 1", "decoded 2",
        "layout 1 1", "decoded 3", "decoded 4",
    ])
}
