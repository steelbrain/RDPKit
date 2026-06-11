@testable import RDPKit
import Testing

@Test func serverCertificateTrustKeyNormalizesStorageIdentity() {
    let key = RDPServerCertificateTrustKey(
        host: "  EXAMPLE.COM  ",
        port: 3389,
        sha256: "  AA:BB:CC  "
    )

    #expect(key?.host == "example.com")
    #expect(key?.port == 3389)
    #expect(key?.sha256 == "aa:bb:cc")
    #expect(key?.storageIdentifier == "example.com\u{1f}3389\u{1f}aa:bb:cc")
}

@Test func serverCertificateTrustKeyRejectsMissingIdentityParts() {
    #expect(RDPServerCertificateTrustKey(host: "", port: 3389, sha256: "aa") == nil)
    #expect(RDPServerCertificateTrustKey(host: "example.com", port: 3389, sha256: nil) == nil)
    #expect(RDPServerCertificateTrustKey(host: "example.com", port: 3389, sha256: "  ") == nil)
}
