import Foundation
@testable import RDPKit
import Testing

private func connectFailure(_ errno: Int32) -> RDPConnectionError {
    RDPConnectionError.connect(RDPSocketError(errno: errno), "connect failed")
}

/// A connect the server may answer later is tried again, each try numbered first, until one
/// connects or the attempts run out; the last failure is the one thrown.
@Test func aConnectThatMayWorkLaterIsTriedAgain() throws {
    for errno in [EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, EIO] {
        var tries: [Int] = []
        let connected = try connectRetrying(attempts: 3, delay: 0, callbacks: RDPSessionCallbacks(), onAttempt: { tries.append($0) }) {
            guard tries.count == 3 else {
                throw connectFailure(errno)
            }
            return "connected"
        }
        #expect(connected == "connected")
        #expect(tries == [1, 2, 3])
    }

    var tries: [Int] = []
    let error = #expect(throws: RDPConnectionError.self) {
        try connectRetrying(attempts: 2, delay: 0, callbacks: RDPSessionCallbacks(), onAttempt: { tries.append($0) }) { () -> String in
            throw connectFailure(tries.count == 1 ? EHOSTUNREACH : ETIMEDOUT)
        }
    }
    #expect(tries == [1, 2])
    #expect(error?.failure == .connect(error: RDPSocketError(errno: ETIMEDOUT)))
}

/// A refused connection, one the system does not permit, a name that does not resolve or any
/// failure past the TCP connect fails at once, as does every one with a single attempt.
@Test func aConnectThatWillNotWorkIsNotTriedAgain() {
    let failures = [
        connectFailure(ECONNREFUSED),
        connectFailure(EPERM),
        RDPConnectionError.addressResolution("no such host"),
        RDPConnectionError(.connectionClosed, description: "closed"),
    ]
    for failure in failures {
        var tries = 0
        #expect(throws: RDPConnectionError.self) {
            try connectRetrying(attempts: 3, delay: 0, callbacks: RDPSessionCallbacks(), onAttempt: { _ in tries += 1 }) { () -> String in
                throw failure
            }
        }
        #expect(tries == 1)
    }
    var tries = 0
    #expect(throws: RDPConnectionError.self) {
        try connectRetrying(attempts: 1, delay: 0, callbacks: RDPSessionCallbacks(), onAttempt: { _ in tries += 1 }) { () -> String in
            throw connectFailure(EHOSTUNREACH)
        }
    }
    #expect(tries == 1)
}

/// Tries are `delay` apart, and cancelling ends the pause at once.
@Test func aConnectRetryWaitsItsDelayUnlessCancelled() throws {
    var tries: [ContinuousClock.Instant] = []
    _ = try connectRetrying(attempts: 2, delay: 0.3, callbacks: RDPSessionCallbacks(), onAttempt: { _ in tries.append(.now) }) {
        guard tries.count == 2 else {
            throw connectFailure(EHOSTUNREACH)
        }
        return "connected"
    }
    #expect(tries[1] - tries[0] >= .milliseconds(300))

    let cancellation = RDPConnectionCancellation()
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.2)
        cancellation.cancel()
    }
    let started = ContinuousClock.now
    var count = 0
    let error = #expect(throws: RDPConnectionError.self) {
        try connectRetrying(attempts: 3, delay: 60, callbacks: RDPSessionCallbacks(cancellation: cancellation), onAttempt: { _ in count += 1 }) { () -> String in
            throw connectFailure(EHOSTUNREACH)
        }
    }
    #expect(error?.failure == .cancelled)
    #expect(count == 1)
    #expect(ContinuousClock.now - started < .seconds(10))

    // A polled `shouldCancel` ends it within about a second.
    let polledStart = ContinuousClock.now
    let polled = #expect(throws: RDPConnectionError.self) {
        try connectRetrying(
            attempts: 3,
            delay: 60,
            callbacks: RDPSessionCallbacks(shouldCancel: { ContinuousClock.now - polledStart > .milliseconds(200) }),
            onAttempt: { _ in }
        ) { () -> String in
            throw connectFailure(EHOSTUNREACH)
        }
    }
    #expect(polled?.failure == .cancelled)
    #expect(ContinuousClock.now - polledStart < .seconds(10))
}

/// Each pause before a try says when that try starts, and ends with nil, also when cancelled.
@Test func aConnectRetrySaysWhenTheNextTryStarts() throws {
    var events: [String] = []
    var waits: [Date] = []
    _ = try connectRetrying(
        attempts: 3,
        delay: 0.2,
        callbacks: RDPSessionCallbacks(),
        onAttempt: { events.append("attempt \($0)") },
        onWait: { date in
            events.append(date == nil ? "waited" : "waiting")
            if let date {
                waits.append(date)
            }
        }
    ) {
        guard waits.count == 2 else {
            throw connectFailure(ETIMEDOUT)
        }
        return "connected"
    }
    #expect(events == ["attempt 1", "waiting", "waited", "attempt 2", "waiting", "waited", "attempt 3"])
    #expect(waits.count == 2)
    #expect(waits.allSatisfy { $0.timeIntervalSinceNow < 0.1 && $0.timeIntervalSinceNow > -5 })
    #expect(waits.count == 2 && waits[1].timeIntervalSince(waits[0]) >= 0.2)

    // A delay out of range is waited as its nearest in range: none, or an hour.
    for (delay, seconds) in [(-600.0, 0.0), (.nan, 0), (7200, 3600)] {
        var starts: [Date] = []
        let cancellation = RDPConnectionCancellation()
        let requested = Date()
        #expect(throws: RDPConnectionError.self) {
            try connectRetrying(
                attempts: 2,
                delay: delay,
                callbacks: RDPSessionCallbacks(cancellation: cancellation),
                onAttempt: { _ in },
                onWait: { date in
                    if let date {
                        starts.append(date)
                        // Ends a long pause at once; a short one ends on its own.
                        cancellation.cancel()
                    }
                }
            ) { () -> String in
                throw connectFailure(EHOSTUNREACH)
            }
        }
        #expect(starts.count == 1)
        #expect(abs((starts.first ?? .distantPast).timeIntervalSince(requested) - seconds) < 5)
    }
}
