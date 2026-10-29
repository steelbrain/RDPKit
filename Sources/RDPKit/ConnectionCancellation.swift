import Foundation

/// Polled on the connection thread before each receive, and about once a
/// second while the connection waits: to connect, for the TLS handshake, the
/// certificate trust evaluation, a send, or a receive. Returning true cancels
/// the connection. `RDPConnectionCancellation` takes effect without polling, and
/// also stops graphics decoding in progress.
public typealias RDPCancellationHandler = @Sendable () -> Bool

/// Cancels a running connection from any thread. Cancelling closes the socket,
/// so a blocked `run`/`connect` returns promptly with a report whose failure is
/// `.cancelled`. Graphics decoding in progress stops too, before the next update
/// in a message, bitmap rectangle or RemoteFX tile, so a message a debug build
/// takes seconds to decode, such as a wide desktop's CAPROGRESSIVE upgrade pass,
/// does not hold the call up.
public final class RDPConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var registrations: [ObjectIdentifier: RDPConnectionCancellationRegistration] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        let pending: [RDPConnectionCancellationRegistration] = lock.withLock {
            guard !cancelled else {
                return []
            }
            cancelled = true
            defer { registrations.removeAll() }
            return Array(registrations.values)
        }
        pending.forEach { $0.fire() }
    }

    /// Runs `handler` once when the connection is cancelled, or right away if it already is.
    func register(_ handler: @escaping @Sendable () -> Void) -> RDPConnectionCancellationRegistration {
        let registration = RDPConnectionCancellationRegistration(owner: self, handler: handler)
        let alreadyCancelled = lock.withLock {
            if !cancelled {
                registrations[ObjectIdentifier(registration)] = registration
            }
            return cancelled
        }
        if alreadyCancelled {
            registration.fire()
        }
        return registration
    }

    fileprivate func remove(_ registration: RDPConnectionCancellationRegistration) {
        _ = lock.withLock { registrations.removeValue(forKey: ObjectIdentifier(registration)) }
    }
}

final class RDPConnectionCancellationRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: RDPConnectionCancellation?
    private var handler: (@Sendable () -> Void)?

    fileprivate init(owner: RDPConnectionCancellation, handler: @escaping @Sendable () -> Void) {
        self.owner = owner
        self.handler = handler
    }

    /// Runs the handler under the registration lock, so `cancel()` cannot
    /// return while it is still running.
    fileprivate func fire() {
        lock.withLock {
            handler?()
            handler = nil
        }
    }

    /// Once this returns, the handler is not running and never will.
    func cancel() {
        lock.withLock { handler = nil }
        owner?.remove(self)
    }
}
