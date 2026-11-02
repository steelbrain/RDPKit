import Foundation
import RDPKit
import Testing

/// Connect without the old CredSSP; refused for it, ask; agreed to, connect once with it.
@Test func legacyCredSSPIsAllowedOnlyForTheConnectionTheUserAgreedTo() throws {
    let serverA = try RDPConnectionTarget(host: "a.example", port: 3389)
    let serverB = try RDPConnectionTarget(host: "b.example", port: 3389)
    var consent = RDPLegacyCredSSPConsent()

    #expect(consent.connect(to: serverA) == false)
    consent.connectionEnded(serverA, failure: .tls, redirectionDepth: 0)
    #expect(consent.offer == nil)
    #expect(consent.allow() == false)
    #expect(consent.connect(to: serverA) == false)

    consent.connectionEnded(serverA, failure: .legacyCredSSPVersion(version: 3), redirectionDepth: 0)
    #expect(consent.offer == RDPLegacyCredSSPConsent.Offer(target: serverA, version: 3))
    #expect(consent.allowedTarget == nil)
    #expect(consent.allow() == true)
    // Agreeing takes the offer, so it is not made again while the connection starts.
    #expect(consent.offer == nil)
    #expect(consent.allowedTarget == serverA)
    #expect(consent.allow() == false)
    #expect(consent.connect(to: serverA) == true)
    #expect(consent.allowedTarget == nil)
    #expect(consent.offer == nil)
    // The next connection, to the same server too, refuses it again.
    #expect(consent.connect(to: serverA) == false)

    // Connecting without agreeing forgets the offer.
    consent.connectionEnded(serverA, failure: .legacyCredSSPVersion(version: 2), redirectionDepth: 0)
    #expect(consent.connect(to: serverA) == false)
    #expect(consent.offer == nil)

    // An agreement is for the server it was given for.
    consent.connectionEnded(serverA, failure: .legacyCredSSPVersion(version: 2), redirectionDepth: 0)
    #expect(consent.allow() == true)
    #expect(consent.connect(to: serverB) == false)
    #expect(consent.connect(to: serverA) == false)

    // A redirection target is not the server typed in, so it is not offered.
    consent.connectionEnded(serverA, failure: .legacyCredSSPVersion(version: 2), redirectionDepth: 1)
    #expect(consent.offer == nil)

    // A report says how the connection ended.
    var report = RDPConnectionReport(
        status: "failure",
        stage: "credssp",
        target: "a.example:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        warnings: []
    )
    report.failure = .legacyCredSSPVersion(version: 4)
    report.redirectionDepth = 1
    consent.connectionEnded(serverA, report: report)
    #expect(consent.offer == nil)
    report.redirectionDepth = 0
    consent.connectionEnded(serverA, report: report)
    #expect(consent.offer == RDPLegacyCredSSPConsent.Offer(target: serverA, version: 4))
}

/// A report names the server it was refused for, the configured one when no redirection led
/// elsewhere; a reset forgets an offer and an agreement.
@Test func legacyCredSSPConsentTakesTheServerFromTheReportAndResets() throws {
    var report = RDPConnectionReport(
        status: "failure",
        stage: "credssp",
        target: "a.example:3390",
        targetHost: "a.example",
        targetPort: 3390,
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        warnings: []
    )
    report.failure = .legacyCredSSPVersion(version: 3)
    let server = try RDPConnectionTarget(host: "a.example", port: 3390)
    var consent = RDPLegacyCredSSPConsent()
    consent.connectionEnded(report: report)
    #expect(consent.offer == RDPLegacyCredSSPConsent.Offer(target: server, version: 3))

    consent.reset()
    #expect(consent.offer == nil)
    consent.connectionEnded(report: report)
    let allowed = consent.allow()
    #expect(allowed)
    consent.reset()
    #expect(consent.allowedTarget == nil)
    #expect(consent.connect(to: server) == false)

    // A report without a host to name offers nothing.
    report.targetHost = " "
    consent.connectionEnded(report: report)
    #expect(consent.offer == nil)
}
