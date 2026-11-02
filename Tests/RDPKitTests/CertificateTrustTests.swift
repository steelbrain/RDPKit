import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
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

/// The trust evaluation gets every certificate the server presented, not only
/// the leaf, so a server's intermediates count.
@Test func tlsHandshakeReturnsThePresentedChain() throws {
    var tls = try MockKRDPTLS.configuration()
    tls.certificateChain += tls.certificateChain
    let context = try NIOSSLContext(configuration: tls)
    let server = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer { server.close(promise: nil) }

    let transport = try RDPTransport.connect(
        host: "127.0.0.1",
        port: UInt16(try #require(server.localAddress?.port)),
        timeoutSeconds: 10,
        callbacks: RDPSessionCallbacks()
    )
    defer { transport.close() }
    let certificates = try transport.startTLS(serverHostname: nil).certificates

    #expect(certificates.count == 2)
    let info = try inspectPeerCertificates(
        certificates,
        host: "127.0.0.1",
        hideCertificateWarnings: false,
        timeoutSeconds: 10,
        callbacks: RDPSessionCallbacks()
    )
    #expect(info.host == "127.0.0.1")
    #expect(info.trusted == false)
    #expect(info.warnings.map(\.code) == ["unrecognized-certificate"])
}

@Test func cancellationStopsTheTrustEvaluation() throws {
    let certificates = try MockKRDPTLS.configuration().certificateChain.compactMap {
        if case let .certificate(certificate) = $0 { certificate } else { nil }
    }
    let cancellation = RDPConnectionCancellation()
    cancellation.cancel()

    #expect(throws: RDPConnectionError.self) {
        try inspectPeerCertificates(
            certificates,
            host: "127.0.0.1",
            hideCertificateWarnings: false,
            timeoutSeconds: 10,
            callbacks: RDPSessionCallbacks(cancellation: cancellation)
        )
    }
}

/// Busy threads at the caller's QoS hold every CPU, as a test run's or an
/// app's decoding work can: the evaluation still runs instead of waiting for
/// a thread until its deadline and reporting the certificate untrusted.
@Test func trustEvaluationRunsWhileBusyThreadsHoldEveryCPU() throws {
    let certificates = try MockKRDPTLS.configuration().certificateChain.compactMap {
        if case let .certificate(certificate) = $0 { certificate } else { nil }
    }
    let stop = Locked(false)
    let spinners = DispatchGroup()
    for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount {
        DispatchQueue.global(qos: .userInitiated).async(group: spinners) {
            // Spin, checking the lock only once a millisecond so no spinner blocks on it.
            while !stop.value {
                let end = DispatchTime.now() + .milliseconds(1)
                while DispatchTime.now() < end {}
            }
        }
    }
    defer {
        stop.withLock { $0 = true }
        spinners.wait()
    }

    let info = try inspectPeerCertificates(
        certificates,
        host: "127.0.0.1",
        hideCertificateWarnings: false,
        timeoutSeconds: 3,
        callbacks: RDPSessionCallbacks()
    )
    #expect(info.warnings.map(\.message).allSatisfy { !$0.contains("did not finish") })
}

/// A storage identifier reads back as its key, and a string that is not one as nil.
@Test func aCertificateTrustKeyReadsBackFromItsStorageIdentifier() throws {
    let key = try #require(RDPServerCertificateTrustKey(host: " Desktop.Example ", port: 3390, sha256: "AB"))
    #expect(RDPServerCertificateTrustKey(storageIdentifier: key.storageIdentifier) == key)
    for identifier in ["", "desktop.example", "desktop.example\u{1f}3390", "desktop.example\u{1f}port\u{1f}ab",
                       "desktop.example\u{1f}3390\u{1f}ab\u{1f}more", "\u{1f}3390\u{1f}ab", "desktop.example\u{1f}70000\u{1f}ab"] {
        #expect(RDPServerCertificateTrustKey(storageIdentifier: identifier) == nil)
    }
}

private func certificate(_ sha256: String?, host: String = "desktop.example", trusted: Bool = false) -> RDPServerCertificateInfo {
    RDPServerCertificateInfo(trusted: trusted, sha256: sha256, warnings: [], host: host)
}

/// A certificate the system does not trust from a host and port the user trusted another for
/// has changed; one without a fingerprint cannot be the trusted one.
@Test func aDifferentCertificateFromATrustedHostIsChanged() throws {
    var certificates = RDPTrustedServerCertificates()
    #expect(certificates.isChanged(certificate("aa"), port: 3389) == false)

    try certificates.trust(#require(RDPServerCertificateTrustKey(host: "Desktop.Example", port: 3389, sha256: "AA")))

    #expect(certificates.isChanged(certificate("aa"), port: 3389) == false)
    #expect(certificates.isChanged(certificate("bb"), port: 3389))
    #expect(certificates.isChanged(certificate(nil), port: 3389))
    #expect(certificates.isChanged(certificate("bb", trusted: true), port: 3389) == false)
    #expect(certificates.isChanged(certificate("bb"), port: 3390) == false)
    #expect(certificates.isChanged(certificate("bb", host: "other.example"), port: 3389) == false)
}

/// Trusting a certificate replaces the one trusted for its host and port only; removing it
/// leaves the others, and identifiers that are not a key's stay as they were.
@Test func trustingANewCertificateForAHostReplacesTheOldOne() throws {
    var certificates = RDPTrustedServerCertificates(storageIdentifiers: ["not a key"])
    try certificates.trust(#require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))
    try certificates.trust(#require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3390, sha256: "aa")))

    let replacement = try #require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "bb"))
    certificates.trust(replacement)

    #expect(certificates.isChanged(certificate("aa"), port: 3389))
    #expect(certificates.isChanged(certificate("bb"), port: 3389) == false)
    #expect(certificates.isTrusted(host: "desktop.example", port: 3390, sha256: "aa"))
    #expect(certificates.storageIdentifiers.count == 3)
    certificates.removeTrust(replacement)
    #expect(certificates.contains(replacement) == false)
    #expect(certificates.isTrusted(host: "desktop.example", port: 3390, sha256: "aa"))
    #expect(certificates.storageIdentifiers.contains("not a key"))
}

/// A certificate nobody trusts is refused until the user trusts it, unless untrusted ones are
/// accepted; one that replaced a trusted certificate is refused always.
@Test func aCertificateNobodyTrustsIsRefusedUntilTheUserTrustsIt() throws {
    var certificates = RDPTrustedServerCertificates()
    #expect(certificates.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false) == .untrusted)
    #expect(certificates.refusal(of: certificate(nil), port: 3389, acceptsUntrusted: false) == .untrusted)
    #expect(certificates.refusal(of: certificate("aa", trusted: true), port: 3389, acceptsUntrusted: false) == nil)
    #expect(certificates.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: true) == nil)

    try certificates.trust(#require(RDPServerCertificateTrustKey(host: "desktop.example", port: 3389, sha256: "aa")))

    #expect(certificates.refusal(of: certificate("aa"), port: 3389, acceptsUntrusted: false) == nil)
    #expect(certificates.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: false) == .changed)
    #expect(certificates.refusal(of: certificate("bb"), port: 3389, acceptsUntrusted: true) == .changed)
}

