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

    let credentials = RDPCredentials(username: "aneesiqbal", password: "aneesiqbal")
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
            clipboardEnabled: false
        )
    )

    #expect(report.status == "success")
    #expect(report.error == nil)
    // The client reconnected after the redirect (two server-side connections).
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.width == 1280)
    #expect(report.rdpGraphicsFirstFrame?.height == 720)
    #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
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
