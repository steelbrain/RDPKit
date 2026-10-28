import CryptoKit
import Darwin
import Foundation
@preconcurrency import NIOSSL
import Security

public struct RDPServerCertificateInfo: Encodable, Equatable, Sendable {
    public var trusted: Bool
    public var sha256: String?
    public var warnings: [RDPProbeWarning]
    /// The host the certificate was checked against: after a server
    /// redirection, the redirection target rather than the configured host.
    public var host: String

    public init(trusted: Bool, sha256: String?, warnings: [RDPProbeWarning], host: String = "") {
        self.trusted = trusted
        self.sha256 = sha256
        self.warnings = warnings
        self.host = host
    }
}

/// Called on the connection thread once per TCP connection, including each
/// server redirection's target, when the TLS handshake completes and before
/// any credential leaves the client (neither CredSSP nor the Client Info PDU
/// has been sent). Cancelling the connection from this handler, through its
/// `RDPConnectionCancellation` or `shouldCancel`, rejects the server.
public typealias RDPServerCertificateHandler = @Sendable (RDPServerCertificateInfo) -> Void

/// Evaluates the chain the server presented (leaf first) for `host`. The
/// evaluation may fetch intermediates or revocation data, so it is bounded by
/// `timeoutSeconds` and cancellable; one that does not finish counts as untrusted.
func inspectPeerCertificates(
    _ certificates: [NIOSSLCertificate],
    host: String,
    hideCertificateWarnings: Bool,
    timeoutSeconds: Int,
    callbacks: RDPSessionCallbacks
) throws -> RDPServerCertificateInfo {
    guard let leaf = certificates.first else {
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

    let evaluation = try evaluate(trust, timeoutSeconds: timeoutSeconds, callbacks: callbacks)
    let sha256 = leafCertificateSHA256(from: leaf)
    guard !evaluation.trusted else {
        return RDPServerCertificateInfo(trusted: true, sha256: sha256, warnings: [], host: host)
    }

    let message = evaluation.detail.map { "Server certificate is not trusted by this system: \($0)" }
        ?? "Server certificate is not trusted by this system."
    let warnings = hideCertificateWarnings ? [] : [
        RDPProbeWarning(code: "unrecognized-certificate", message: message),
    ]
    return RDPServerCertificateInfo(trusted: false, sha256: sha256, warnings: warnings, host: host)
}

/// Runs the system trust evaluation off the connection thread, waiting at
/// most `timeoutSeconds` and polling for cancellation about once a second.
private func evaluate(
    _ trust: SecTrust,
    timeoutSeconds: Int,
    callbacks: RDPSessionCallbacks
) throws -> (trusted: Bool, detail: String?) {
    let result = RDPTrustEvaluation(trust)
    let completed = DispatchSemaphore(value: 0)
    trustEvaluationQueue.async {
        result.run()
        completed.signal()
    }
    let registration = callbacks.cancellation?.register {
        completed.signal()
    }
    defer { registration?.cancel() }

    let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
    while completed.wait(timeout: min(deadline, .now() + 1)) == .timedOut || callbacks.isCancelled {
        try callbacks.throwIfCancelled()
        if DispatchTime.now() >= deadline {
            return (false, "trust evaluation did not finish in \(timeoutSeconds) seconds")
        }
    }
    return result.outcome
}

private let trustEvaluationQueue = DispatchQueue(label: "RDPKit.certificateTrust", attributes: .concurrent)

/// A trust evaluation handed to another thread; `outcome` is read after it ran.
private final class RDPTrustEvaluation: @unchecked Sendable {
    private let trust: SecTrust
    private let lock = NSLock()
    private var evaluated: (trusted: Bool, detail: String?) = (false, nil)

    init(_ trust: SecTrust) {
        self.trust = trust
    }

    func run() {
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        let detail = error.flatMap { CFErrorCopyDescription($0) as String? }
        lock.withLock { evaluated = (trusted, detail) }
    }

    var outcome: (trusted: Bool, detail: String?) {
        lock.withLock { evaluated }
    }
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
