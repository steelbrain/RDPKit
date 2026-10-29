import Foundation
import RDPKit

/// Sendable because UserDefaults is thread-safe; the session thread checks certificates.
struct TrustedCertificateStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey = "trusted-server-certificates.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isTrusted(host: String, port: UInt16, sha256: String?) -> Bool {
        guard let key = RDPServerCertificateTrustKey(host: host, port: port, sha256: sha256) else {
            return false
        }
        return isTrusted(key)
    }

    func isTrusted(_ key: RDPServerCertificateTrustKey) -> Bool {
        trustedCertificateIDs().contains(key.storageIdentifier)
    }

    /// A certificate the system does not trust from a host the user trusted another certificate
    /// for: the server's key changed, or someone is intercepting the connection.
    func isChanged(_ certificate: RDPServerCertificateInfo, port: UInt16) -> Bool {
        // A certificate without a fingerprint cannot be the trusted one.
        guard certificate.trusted == false,
              let key = RDPServerCertificateTrustKey(host: certificate.host, port: port, sha256: certificate.sha256 ?? "none")
        else {
            return false
        }
        let certificateIDs = trustedCertificateIDs()
        let hostAndPort = Self.hostAndPort(of: key.storageIdentifier)
        return certificateIDs.contains(key.storageIdentifier) == false
            && certificateIDs.contains { Self.hostAndPort(of: $0) == hostAndPort }
    }

    /// Replaces the certificate trusted for the key's host, if any.
    func trust(_ key: RDPServerCertificateTrustKey) {
        let hostAndPort = Self.hostAndPort(of: key.storageIdentifier)
        var certificateIDs = trustedCertificateIDs().filter { Self.hostAndPort(of: $0) != hostAndPort }
        certificateIDs.insert(key.storageIdentifier)
        saveTrustedCertificateIDs(certificateIDs)
    }

    func removeTrust(_ key: RDPServerCertificateTrustKey) {
        var certificateIDs = trustedCertificateIDs()
        certificateIDs.remove(key.storageIdentifier)
        saveTrustedCertificateIDs(certificateIDs)
    }

    private func trustedCertificateIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    private func saveTrustedCertificateIDs(_ certificateIDs: Set<String>) {
        defaults.set(certificateIDs.sorted(), forKey: storageKey)
    }

    /// A storage identifier without its trailing fingerprint.
    private static func hostAndPort(of certificateID: String) -> Substring? {
        certificateID.lastIndex(of: "\u{1f}").map { certificateID[..<$0] }
    }
}
