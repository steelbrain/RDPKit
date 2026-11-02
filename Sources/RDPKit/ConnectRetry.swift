import Foundation

/// Runs `connect` until it succeeds, it fails other than a TCP connect the server may answer
/// later does, or `attempts` tries have failed, `delay` seconds apart. `onAttempt` gets each
/// try's number, from 1, as it starts, with no date; as the pause after a failed try begins,
/// that try's number with when the next starts; and that number with no date again when
/// cancellation ends the pause, with ``RDPConnectionError/cancelled``. Each call is the whole
/// state, so a reader never sees a try's number apart from its date.
func connectRetrying<Connection>(
    attempts: Int,
    delay: TimeInterval,
    callbacks: RDPSessionCallbacks,
    onAttempt: (_ attempt: Int, _ nextAttemptDate: Date?) -> Void,
    connect: () throws -> Connection
) throws -> Connection {
    // Up to an hour, which also keeps the deadline within what DispatchTime holds.
    let delay = delay.isNaN ? 0 : min(max(delay, 0), 3600)
    var attempt = 1
    while true {
        onAttempt(attempt, nil)
        do {
            return try connect()
        } catch let error as RDPConnectionError where attempt < attempts && error.isRetriableConnectFailure {
            onAttempt(attempt, Date(timeIntervalSinceNow: delay))
            do {
                try pauseBeforeRetry(seconds: delay, callbacks: callbacks)
            } catch {
                onAttempt(attempt, nil)
                throw error
            }
            attempt += 1
        }
    }
}

/// Waits `seconds`, ending early with ``RDPConnectionError/cancelled`` once the connection is
/// cancelled: at once through its cancellation, within about a second through `shouldCancel`.
private func pauseBeforeRetry(seconds: TimeInterval, callbacks: RDPSessionCallbacks) throws {
    let cancelled = DispatchSemaphore(value: 0)
    let registration = callbacks.cancellation?.register {
        cancelled.signal()
    }
    defer { registration?.cancel() }
    let deadline = DispatchTime.now() + seconds
    while cancelled.wait(timeout: min(deadline, .now() + 1)) == .timedOut {
        try callbacks.throwIfCancelled()
        if DispatchTime.now() >= deadline {
            return
        }
    }
    try callbacks.throwIfCancelled()
}

extension RDPConnectionError {
    /// A TCP connect that failed before the server answered, which a later try may get past:
    /// the host or its network could not be reached, it did not answer in time, or it failed
    /// without a category. Not a refused connection, one the system does not permit, or a host
    /// name that does not resolve.
    var isRetriableConnectFailure: Bool {
        guard case let .connect(error) = failure else {
            return false
        }
        return [.hostUnreachable, .networkUnreachable, .timedOut, .other].contains(error.category)
    }
}

extension RDPConnectionReport {
    /// Sets the connect attempt and when the next starts at once, so a live report's copy
    /// never has one without the other.
    mutating func noteConnectAttempt(_ attempt: Int, nextAttemptDate: Date?) {
        connectAttempt = attempt
        nextConnectAttemptDate = nextAttemptDate
    }
}
