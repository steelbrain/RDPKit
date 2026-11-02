import Foundation
import RDPKit

/// Why RDPClient refuses a server's certificate before any credential is sent.
typealias CertificateRefusal = RDPServerCertificateRefusal

/// The option behind `acceptsUntrusted`. Profiles and drafts save it as `hideCertificateWarnings`.
enum UntrustedCertificatesOption {
    static let title = "Accept untrusted certificates"
    static let help = "Connects even when neither this Mac nor RDPClient trusts the server's certificate, "
        + "and sends your credentials without asking. Anyone able to intercept the connection could pose "
        + "as the server and capture them. A certificate that replaced one you trusted is still refused."
}

/// The certificates the user trusted, kept in UserDefaults; RDPKit's
/// `RDPTrustedServerCertificates` decides what they trust. Sendable because UserDefaults is
/// thread-safe; the session thread checks certificates.
struct TrustedCertificateStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey = "trusted-server-certificates.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isTrusted(host: String, port: UInt16, sha256: String?) -> Bool {
        trusted().isTrusted(host: host, port: port, sha256: sha256)
    }

    func isTrusted(_ key: RDPServerCertificateTrustKey) -> Bool {
        trusted().contains(key)
    }

    func isChanged(_ certificate: RDPServerCertificateInfo, port: UInt16) -> Bool {
        trusted().isChanged(certificate, port: port)
    }

    /// `acceptsUntrusted` is Accept untrusted certificates.
    func refusal(of certificate: RDPServerCertificateInfo, port: UInt16, acceptsUntrusted: Bool) -> CertificateRefusal? {
        trusted().refusal(of: certificate, port: port, acceptsUntrusted: acceptsUntrusted)
    }

    /// Replaces the certificate trusted for the key's host, if any.
    func trust(_ key: RDPServerCertificateTrustKey) {
        var certificates = trusted()
        certificates.trust(key)
        save(certificates)
    }

    func removeTrust(_ key: RDPServerCertificateTrustKey) {
        var certificates = trusted()
        certificates.removeTrust(key)
        save(certificates)
    }

    private func trusted() -> RDPTrustedServerCertificates {
        RDPTrustedServerCertificates(storageIdentifiers: defaults.stringArray(forKey: storageKey) ?? [])
    }

    private func save(_ certificates: RDPTrustedServerCertificates) {
        defaults.set(certificates.storageIdentifiers.sorted(), forKey: storageKey)
    }
}
