@testable import RDPClient
import RDPKit
import Testing

@Test func successfulRemoteSessionEndUsesCleanDisconnectMessage() {
    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        warnings: []
    )
    let reason = RDPSessionEndReason(report: report)

    #expect(reason.kind == RDPSessionEndReason.Kind.ended)
    #expect(reason.statusText == "Disconnected")
    #expect(reason.message == "Remote session disconnected.")
    #expect(reason.diagnosticValue == "Disconnected: Remote session disconnected.")
}

@Test func remoteSessionEndBeforeGraphicsChannelDescribesMissingRDPGFX() {
    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        warnings: [],
        nextStage: "rdp-session-ended"
    )
    let reason = RDPSessionEndReason(report: report)

    #expect(reason.kind == RDPSessionEndReason.Kind.ended)
    #expect(reason.statusText == "Disconnected")
    #expect(reason.message == "Remote session ended before opening the RDPGFX dynamic channel.")
}

@Test func remoteSessionEndBeforeGraphicsChannelIncludesTerminationReason() {
    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        rdpRemoteTerminationDisconnectReason: 3,
        rdpRemoteTerminationDisconnectReasonName: "rn-user-requested",
        warnings: [],
        nextStage: "rdp-session-ended"
    )
    let reason = RDPSessionEndReason(report: report)

    #expect(reason.kind == RDPSessionEndReason.Kind.ended)
    #expect(reason.statusText == "Disconnected")
    #expect(reason.message == "Remote session ended before opening the RDPGFX dynamic channel (rn-user-requested).")
}

@Test func remoteSessionEndBeforeFrameDescribesMissingGraphicsFrame() {
    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        rdpGraphicsChannelName: "Microsoft::Windows::RDS::Graphics",
        rdpGraphicsFrames: [],
        warnings: [],
        nextStage: "rdp-session-ended"
    )
    let reason = RDPSessionEndReason(report: report)

    #expect(reason.kind == RDPSessionEndReason.Kind.ended)
    #expect(reason.statusText == "Disconnected")
    #expect(reason.message == "Remote session ended before producing a graphics frame.")
}

@Test func remoteSessionEndBeforeFrameIncludesTerminationReason() {
    let report = RDPPreflightReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        rdpGraphicsChannelName: "Microsoft::Windows::RDS::Graphics",
        rdpGraphicsFrames: [],
        rdpRemoteTerminationErrorInfo: 0x0000_000C,
        rdpRemoteTerminationErrorInfoName: "ERRINFO_LOGOFF_BY_USER",
        warnings: [],
        nextStage: "rdp-session-ended"
    )
    let reason = RDPSessionEndReason(report: report)

    #expect(reason.kind == RDPSessionEndReason.Kind.ended)
    #expect(reason.statusText == "Disconnected")
    #expect(reason.message == "Remote session ended before producing a graphics frame (ERRINFO_LOGOFF_BY_USER).")
}
