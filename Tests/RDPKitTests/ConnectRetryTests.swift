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
