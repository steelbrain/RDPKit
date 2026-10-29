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
