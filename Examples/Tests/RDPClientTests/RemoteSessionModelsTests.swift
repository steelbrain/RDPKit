import Foundation
@testable import RDPClient
import RDPKit
import Testing

@Test func successfulRemoteSessionEndUsesCleanDisconnectMessage() {
    let report = RDPConnectionReport(
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
    let report = RDPConnectionReport(
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
    let report = RDPConnectionReport(
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
    let report = RDPConnectionReport(
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
    let report = RDPConnectionReport(
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

@Test func legacyConnectionProfileDecodesWithDefaultOptions() throws {
    let json = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","host":"server","port":3389,"username":"user",
    "domain":"","desktopWidth":1920,"desktopHeight":1080,"hideCertificateWarnings":false,
    "timeoutSeconds":10,"rememberPassword":true,"updatedAt":0}
    """
    let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))

    #expect(profile.graphicsCapabilityProfile == .automatic)
    #expect(profile.clipboardSharingEnabled)
    #expect(profile.audioPlaybackEnabled == false)
    #expect(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile)) == profile)
}

@Test func framePacingStateNormalizesDisplayLinkTiming() {
    let state = RDPFramePacingState(
        screenName: "Studio Display",
        backingScaleFactor: 2,
        maximumFramesPerSecond: nil,
        minimumRefreshInterval: 1.0 / 120.0,
        maximumRefreshInterval: 1.0 / 48.0,
        displayUpdateGranularity: 0,
        displayLinkDuration: 0.0167,
        hasDisplayLink: true,
        isDisplayLinkPaused: false
    )

    #expect(state.displayLinkDuration == 1.0 / 60.0)
    #expect(state.displayLinkFramesPerSecond == 60)
    #expect(state.maximumRefreshRate == 120)
    #expect(state.clockState == "window display link")
}

@Test func framePacingStateMarksUpdatedDisplayLinkActive() {
    let state = RDPFramePacingState().updatingDisplayLinkDuration(1.0 / 120.0)

    #expect(state.hasDisplayLink)
    #expect(state.isDisplayLinkPaused == false)
    #expect(state.displayLinkFramesPerSecond == 120)
    #expect(state.clockState == "window display link")
}

@Test func keyframeRequestsArePacedAndStopUntilVideoDecodesAgain() {
    var throttle = RDPKeyframeRequestThrottle()
    let start = Date()
    func requests(atIntervals intervals: [Double]) -> [Bool] {
        intervals.map { throttle.shouldRequest(at: start.addingTimeInterval($0 * RDPKeyframeRequestThrottle.minimumInterval)) }
    }

    #expect(requests(atIntervals: [0, 0.5, 1, 2, 3]) == [true, false, true, true, false])

    throttle.recordDecodedVideo()

    #expect(requests(atIntervals: [4]) == [true])
}
