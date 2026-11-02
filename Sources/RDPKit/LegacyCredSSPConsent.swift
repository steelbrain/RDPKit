import Foundation

/// Whether a connection allows CredSSP below version 5, which
/// ``RDPConnectionConfiguration/legacyCredSSP`` accepts and RDPKit otherwise refuses before any
/// credential is sent: offered to the user after the server connected to answered with it,
/// and allowed only for the one connection their agreement starts. Any other connection, a
/// later one to the same server included, refuses it again, and so does a Server
/// Redirection's target, which the user never agreed to.
///
/// Connect with ``connect(to:)``'s answer as `legacyCredSSP`, tell it how the connection
/// ended with ``connectionEnded(_:report:)``, show ``offer`` when there is one, and call
/// ``allow()`` when the user agrees, before connecting again.
public struct RDPLegacyCredSSPConsent: Equatable, Sendable {
    public struct Offer: Equatable, Sendable {
        public var target: RDPConnectionTarget
        /// The CredSSP version the server answered with.
        public var version: Int

        public init(target: RDPConnectionTarget, version: Int) {
            self.target = target
            self.version = version
        }
    }

    /// The server the last connection was refused for, until the next connection starts.
    public private(set) var offer: Offer?
    private var allowedTarget: RDPConnectionTarget?

    public init() {}

    /// Returns whether a connection to `target` allows CredSSP below version 5: only when the
    /// user just agreed to it for `target`. Forgets the offer and the agreement.
    public mutating func connect(to target: RDPConnectionTarget) -> Bool {
        defer {
            offer = nil
            allowedTarget = nil
        }
        return allowedTarget == target
    }

    /// Offers the old version after a connection to `target` ended with `failure`, which
    /// RDPKit refuses before any credential is sent. After a Server Redirection
    /// (`redirectionDepth` above 0) another server than `target` answered, which the user did
    /// not choose, so nothing is offered.
    public mutating func connectionEnded(
        _ target: RDPConnectionTarget,
        failure: RDPConnectionFailure?,
        redirectionDepth: Int
    ) {
        guard case let .legacyCredSSPVersion(version) = failure, redirectionDepth == 0 else {
            return
        }
        offer = Offer(target: target, version: version)
    }

    /// ``connectionEnded(_:failure:redirectionDepth:)`` with the report's failure and
    /// redirection depth.
    public mutating func connectionEnded(_ target: RDPConnectionTarget, report: RDPConnectionReport) {
        connectionEnded(target, failure: report.failure, redirectionDepth: report.redirectionDepth)
    }

    /// The user agreed to the offer: the next connection to its target allows the old version.
    /// Returns false without an offer.
    public mutating func allow() -> Bool {
        guard let offer else {
            return false
        }
        allowedTarget = offer.target
        return true
    }
}
