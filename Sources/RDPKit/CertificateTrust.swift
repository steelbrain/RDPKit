import Foundation

public struct RDPServerCertificateTrustKey: Equatable, Hashable, Sendable {
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

    public var storageIdentifier: String {
        [
            host,
            String(port),
            sha256,
        ].joined(separator: "\u{1f}")
    }
}
