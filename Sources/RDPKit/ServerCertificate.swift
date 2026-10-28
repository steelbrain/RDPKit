import CryptoKit
import Darwin
import Foundation
@preconcurrency import NIOSSL
import Security

public struct RDPServerCertificateInfo: Encodable, Equatable, Sendable {
    public var trusted: Bool
    public var sha256: String?
    public var warnings: [RDPProbeWarning]

    public init(trusted: Bool, sha256: String?, warnings: [RDPProbeWarning]) {
        self.trusted = trusted
        self.sha256 = sha256
        self.warnings = warnings
    }
}

/// Called on the connection thread once the TLS handshake completes, before
/// any credential leaves the client (neither CredSSP nor the Client Info PDU
/// has been sent). Cancelling the connection from this handler, through its
/// `RDPConnectionCancellation` or `shouldCancel`, rejects the server.
public typealias RDPServerCertificateHandler = @Sendable (RDPServerCertificateInfo) -> Void

func inspectPeerCertificates(
    _ certificates: [NIOSSLCertificate],
    host: String,
    hideCertificateWarnings: Bool
) throws -> RDPServerCertificateInfo {
    guard !certificates.isEmpty else {
        throw RDPPreflightError.tls("server did not provide a TLS certificate")
    }

    let secCertificates = try certificates.map { certificate -> SecCertificate in
        let der = try Data(certificate.toDERBytes())
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw RDPPreflightError.tls("failed to parse server certificate")
        }
        return secCertificate
    }

    let policy = SecPolicyCreateSSL(true, host as CFString)
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(secCertificates as CFArray, policy, &trust)
    guard status == errSecSuccess, let trust else {
        throw RDPPreflightError.tls("failed to create server certificate trust")
    }

    var trustError: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &trustError)
    let sha256 = leafCertificateSHA256(from: certificates[0])

    guard !trusted else {
        return RDPServerCertificateInfo(trusted: true, sha256: sha256, warnings: [])
    }

    let detail = trustError.map { CFErrorCopyDescription($0) as String? } ?? nil
    let message: String
    if let detail {
        message = "Server certificate is not trusted by this system: \(detail)"
    } else {
        message = "Server certificate is not trusted by this system."
    }

    let warnings = hideCertificateWarnings ? [] : [
        RDPProbeWarning(code: "unrecognized-certificate", message: message),
    ]

    return RDPServerCertificateInfo(trusted: false, sha256: sha256, warnings: warnings)
}

func leafCertificateSHA256(from certificate: NIOSSLCertificate) -> String? {
    guard let der = try? certificate.toDERBytes() else {
        return nil
    }

    let digest = SHA256.hash(data: Data(der))
    return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
}

func tlsVersionName(_ value: TLSVersion?) -> String {
    switch value {
    case .tlsv1:
        "tls1.0"
    case .tlsv11:
        "tls1.1"
    case .tlsv12:
        "tls1.2"
    case .tlsv13:
        "tls1.3"
    case nil:
        "unknown"
    }
}

/// SNI carries DNS names only: no IP literals (RFC 6066 section 3), scoped IPv6
/// addresses, or trailing root dot.
func sniHostname(for host: String) -> String? {
    var ipv4 = in_addr()
    let isIPv4 = host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
    guard !isIPv4, !host.contains(":"), !host.contains("%") else {
        return nil
    }
    let name = host.hasSuffix(".") ? String(host.dropLast()) : host
    return name.isEmpty ? nil : name
}
