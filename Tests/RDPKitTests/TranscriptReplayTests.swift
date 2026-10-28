import Foundation
@testable import RDPKit
import Testing

// Replays a real gnome-remote-desktop negotiation transcript captured off the
// wire (see RDPFirstFrameCapture --capture-transcript) against a local socket
// server. The replay terminates TLS and performs NLA live, then feeds the
// recorded server→client PDUs back in order — driving the real client through
// the entire negotiation, including GRD's routing-token redirect/reconnect,
// right up until the first video frame flows. This pins the client to GRD's
// actual choreography (the auto-detect round-count and redirect handling that
// the GNOME regressions broke) without needing the live host.
@Test func replaysGnomeNegotiationTranscriptThroughToFirstFrame() throws {
    let events = try loadTranscriptFixture("gnome-negotiation-transcript")

    // The capture spanned two TCP connections: GRD redirects on the first and
    // serves graphics on the reconnect.
    let segments = RDPTranscriptReplayServer.segment(events)
    #expect(segments.count == 2)

    let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
    let server = try RDPTranscriptReplayServer.start(transcript: events, credentials: credentials)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: credentials,
            timeoutSeconds: 10,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            graphicsCapabilityProfile: .avcThinClient
        )
    )

    #expect(report.status == "success")
    #expect(report.error == nil)
    // The client reconnected after the redirect (two server-side connections).
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.surfaceID == 0)
    #expect(report.rdpGraphicsFirstFrame?.width == 1280)
    #expect(report.rdpGraphicsFirstFrame?.height == 720)
    #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
}

@Test func replaysKrdpNegotiationTranscriptThroughToFirstFrame() throws {
    let events = try loadTranscriptFixture("krdp-negotiation-transcript")
    let segments = RDPTranscriptReplayServer.segment(events)
    #expect(segments.count == 1)

    let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
    let server = try RDPTranscriptReplayServer.start(transcript: events, credentials: credentials)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: credentials,
            timeoutSeconds: 10,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false,
            graphicsCapabilityProfile: .avcThinClient
        )
    )

    #expect(report.status == "success")
    #expect(report.error == nil)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.width == 3840)
    #expect(report.rdpGraphicsFirstFrame?.height == 2400)
    #expect(report.rdpGraphicsFirstFrame.map { Array($0.videoNalUnitTypes.prefix(3)) } == [7, 8, 6])
}

/// Every server PDU on the I/O channel of both captures, classified the way
/// the client does: licensing first while it is in progress, Share Control
/// after. GRD's Demand Active length (0x0196) has the SEC_LICENSE_PKT bit set.
@Test func classifiesEveryIOChannelServerPDUInBothCaptures() throws {
    for (name, expected) in [
        ("gnome-negotiation-transcript", [
            "license-error-valid-client", "server-demand-active", "server-synchronize", "control-cooperate",
            "control-granted-control", "font-map", "server-redirection",
            "license-error-valid-client", "server-demand-active", "server-synchronize", "control-cooperate",
            "control-granted-control", "font-map",
        ]),
        ("krdp-negotiation-transcript", [
            "license-error-valid-client", "server-demand-active", "server-synchronize", "control-cooperate",
            "control-granted-control", "font-map",
        ]),
    ] {
        var classified: [String] = []
        for segment in RDPTranscriptReplayServer.segment(try loadTranscriptFixture(name)) {
            var licensing = true
            for event in segment.appEvents where event.direction == .serverToClient {
                guard let bytes = event.bytes,
                      let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: bytes),
                      indication.channelID == 1003
                else {
                    continue
                }
                switch try RDPIOChannelPDU.parse(indication, licensing: licensing) {
                case let .license(license):
                    classified.append(license.typeName)
                    licensing = !(license.typeName == "license-error-valid-client")
                case let .shareControl(shareControl):
                    let shareData = try RDPShareDataPDU.parseIfPresent(from: indication)
                    classified.append(shareData?.typeName ?? shareControl.typeName)
                    licensing = false
                case nil:
                    classified.append("unclassified")
                }
            }
        }
        #expect(classified == expected, "\(name)")
    }
}

private func loadTranscriptFixture(_ name: String) throws -> [RDPWireEvent] {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([RDPWireEvent].self, from: data)
}
