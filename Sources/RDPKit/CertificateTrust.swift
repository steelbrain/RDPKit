import Foundation

public struct RDPServerCertificateTrustKey: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public var sha256: String

    public init?(host: String, port: UInt16, sha256: String?) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedHost.isEmpty == false else {
            return nil
        }

        guard let sha256 else {
            return nil
        }
        let normalizedSHA256 = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedSHA256.isEmpty == false else {
            return nil
        }

        self.host = normalizedHost
        self.port = port
        self.sha256 = normalizedSHA256
    }

    /// The key as one string, to store; `init?(storageIdentifier:)` reads it back.
    public var storageIdentifier: String {
        [
            host,
            String(port),
            sha256,
        ].joined(separator: "\u{1f}")
    }

    /// The key a `storageIdentifier` holds; nil for a string that is not one.
    public init?(storageIdentifier: String) {
        let parts = storageIdentifier.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard parts.count == 3, let port = UInt16(parts[1]) else {
            return nil
        }
        self.init(host: String(parts[0]), port: port, sha256: String(parts[2]))
    }
}

/// Why a server's certificate is refused before any credential is sent.
public enum RDPServerCertificateRefusal: Equatable, Sendable {
    /// Neither the system nor the user trusts it.
    case untrusted
    /// The user trusted another certificate for its host and port: the server's key changed,
    /// or someone is intercepting the connection.
    case changed
}

/// The certificates a user trusted, one per host and port, by the storage identifiers an app
/// keeps, and the trust-on-first-use rule for a server's certificate: one the system does not
/// trust is refused unless the user trusted it, and one that replaced a certificate the user
/// trusted is refused always.
public struct RDPTrustedServerCertificates: Equatable, Sendable {
    /// What to store; identifiers that are not a key's are kept and ignored.
    public private(set) var storageIdentifiers: Set<String>

    public init(storageIdentifiers: some Sequence<String> = [String]()) {
        self.storageIdentifiers = Set(storageIdentifiers)
    }

    public func contains(_ key: RDPServerCertificateTrustKey) -> Bool {
        storageIdentifiers.contains(key.storageIdentifier)
    }

    public func isTrusted(host: String, port: UInt16, sha256: String?) -> Bool {
        RDPServerCertificateTrustKey(host: host, port: port, sha256: sha256).map(contains) ?? false
    }

    /// Trusts `key`, in place of the certificate trusted for its host and port.
    public mutating func trust(_ key: RDPServerCertificateTrustKey) {
        storageIdentifiers = storageIdentifiers.filter { !Self.identifier($0, isFor: key) }
        storageIdentifiers.insert(key.storageIdentifier)
    }

    public mutating func removeTrust(_ key: RDPServerCertificateTrustKey) {
        storageIdentifiers.remove(key.storageIdentifier)
    }

    /// Whether `certificate`, which the system does not trust, came from a host and port the
    /// user trusted another certificate for. One without a fingerprint cannot be that one.
    public func isChanged(_ certificate: RDPServerCertificateInfo, port: UInt16) -> Bool {
        guard certificate.trusted == false,
              let key = RDPServerCertificateTrustKey(host: certificate.host, port: port, sha256: certificate.sha256 ?? "none")
        else {
            return false
        }
        return contains(key) == false && storageIdentifiers.contains { Self.identifier($0, isFor: key) }
    }

    /// Why `certificate` must be refused before credentials are sent, or nil to go ahead.
    /// `acceptsUntrusted` lets through a certificate nobody trusts, but never one that replaced
    /// a certificate the user trusted.
    public func refusal(
        of certificate: RDPServerCertificateInfo,
        port: UInt16,
        acceptsUntrusted: Bool
    ) -> RDPServerCertificateRefusal? {
        if isChanged(certificate, port: port) {
            return .changed
        }
        guard certificate.trusted == false,
              acceptsUntrusted == false,
              isTrusted(host: certificate.host, port: port, sha256: certificate.sha256) == false
        else {
            return nil
        }
        return .untrusted
    }

    /// Whether `identifier` is a key's for the host and port of `key`.
    private static func identifier(_ identifier: String, isFor key: RDPServerCertificateTrustKey) -> Bool {
        RDPServerCertificateTrustKey(storageIdentifier: identifier).map { $0.host == key.host && $0.port == key.port } ?? false
    }
}
