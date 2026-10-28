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

    // KRdp runs auto-detect after activation (events 31, 38, 43, 44): RTT
    // requests get RTT responses, and the continuous Bandwidth Measure Stop
    // gets results counting the session traffic since the Start
    // ([MS-RDPBCGR] 1.3.9, 2.2.14.2).
    let responses = server.clientPackets.packets.compactMap(autoDetectResponse)
    #expect(responses.filter { $0.type == 0x0000 }.map(\.sequenceNumber) == [0x0023, 0x0001, 0x0002])
    let bandwidth = try #require(responses.first { $0.type == 0x000B })
    #expect(bandwidth.sequenceNumber == 0)
    #expect(bandwidth.byteCount > 0)
}

/// The client's auto-detect response in `packet` (security header
/// SEC_AUTODETECT_RSP, [MS-RDPBCGR] 2.2.14.4), if it holds one.
private func autoDetectResponse(
    _ packet: Data
) -> (sequenceNumber: UInt16, type: UInt16, byteCount: UInt32)? {
    let bytes = [UInt8](packet)
    // TPKT (4), X.224 Data (3), Send Data Request header (6), PER length (1).
    guard bytes.count >= 24, bytes[7] == 0x64,
          bytes[14 ..< 18] == [0x00, 0x20, 0x00, 0x00], bytes[19] == 0x01
    else {
        return nil
    }
    func uint(_ offset: Int, _ count: Int) -> UInt32 {
        (0 ..< count).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    let type = UInt16(uint(22, 2))
    let byteCount = type == 0x000B && bytes.count >= 32 ? uint(28, 4) : 0
    return (UInt16(uint(20, 2)), type, byteCount)
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
