import Foundation
@testable import RDPClient
import RDPKit
import Testing

private func makeStore() throws -> TrustedCertificateStore {
    let suiteName = "RDPClientTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return TrustedCertificateStore(defaults: defaults)
}

private func certificate(_ sha256: String?, host: String = "desktop.example", trusted: Bool = false) -> RDPServerCertificateInfo {
    RDPServerCertificateInfo(trusted: trusted, sha256: sha256, warnings: [], host: host)
}

@Test func aDifferentCertificateFromATrustedHostIsChanged() throws {
    let store = try makeStore()
    #expect(store.isChanged(certificate("aa"), port: 3389) == false)

    store.trust(try #require(RDPServerCertificateTrustKey(host: "Desktop.Example", port: 3389, sha256: "AA")))

    #expect(store.isChanged(certificate("aa"), port: 3389) == false)
    #expect(store.isChanged(certificate("bb"), port: 3389))
    #expect(store.isChanged(certificate(nil), port: 3389))
    #expect(store.isChanged(certificate("bb", trusted: true), port: 3389) == false)
    #expect(store.isChanged(certificate("bb"), port: 3390) == false)
    #expect(store.isChanged(certificate("bb", host: "other.example"), port: 3389) == false)
}

@Test func trustingANewCertificateForAHostReplacesTheOldOne() throws {
    let store = try makeStore()
    store.trust(try #require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))
    store.trust(try #require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3390, sha256: "aa")))

    store.trust(try #require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "bb")))

    #expect(store.isChanged(certificate("aa"), port: 3389))
    #expect(store.isChanged(certificate("bb"), port: 3389) == false)
    #expect(store.isTrusted(host: "desktop.example", port: 3390, sha256: "aa"))
}

@Test func aCertificateNobodyTrustsIsRefusedUntilTheUserTrustsIt() throws {
    let store = try makeStore()
    #expect(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false) == .untrusted)
    #expect(store.refusal(of: certificate(nil), port: 3389, acceptsUntrusted: false) == .untrusted)
    #expect(store.refusal(of: certificate("aa", trusted: true), port: 3389, acceptsUntrusted: false) == nil)
    // Accept untrusted certificates lets an untrusted certificate through.
    #expect(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: true) == nil)

    store.trust(try #require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))

    #expect(store.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false) == nil)
    #expect(store.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: false) == .changed)
    // ...but never a certificate that replaced one the user trusted.
    #expect(store.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: true) == .changed)
}
