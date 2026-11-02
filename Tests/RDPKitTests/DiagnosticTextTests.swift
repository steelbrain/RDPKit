import Foundation
@testable import RDPKit
import Testing

private func report() -> RDPConnectionReport {
    RDPConnectionReport(
        status: "success",
        stage: "rdp-graphics-dynamic-channel",
        target: "127.0.0.1:3389",
        passwordConfigured: true,
        requestedProtocols: ["tls", "credssp"],
        requestHex: "",
        warnings: []
    )
}

/// Units keep two decimals below one and one above, and a missing value reads "none".
@Test func diagnosticTextFormatsUnits() {
    #expect(RDPDiagnosticText.milliseconds(0.256) == "0.26 ms")
    #expect(RDPDiagnosticText.milliseconds(12.34) == "12.3 ms")
    #expect(RDPDiagnosticText.milliseconds(nil) == "none")
    #expect(RDPDiagnosticText.timing(last: 2, average: nil) == "last 2.0 ms, avg none")
    #expect(RDPDiagnosticText.refreshInterval(1.0 / 120) == "8.3 ms")
    #expect(RDPDiagnosticText.framesPerSecond(59.94) == "59.9 fps")
    #expect(RDPDiagnosticText.hertz(120) == "120 Hz")
    #expect(RDPDiagnosticText.hertz(59.94) == "59.9 Hz")
    #expect(RDPDiagnosticText.megabitsPerSecond(0.5) == "0.50 Mbps")
    #expect(RDPDiagnosticText.megabitsPerSecond(12.25) == "12.2 Mbps")
    #expect(RDPDiagnosticText.megabitsPerSecond(nil) == "none")
    #expect(RDPDiagnosticText.bytes(2_000_000) == ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file))
    #expect(RDPDiagnosticText.byteCount(120) == "120 bytes")
    #expect(RDPDiagnosticText.yesNo(true) == "yes")
    #expect(RDPDiagnosticText.yesNo(nil, missing: "unknown") == "unknown")
    #expect(RDPDiagnosticText.number(UInt16(1004)) == "1004")
    #expect(RDPDiagnosticText.number(UInt32?.none) == "none")
    #expect(RDPDiagnosticText.hex(0x1_0002) == "0x00010002")
    // A Core Video four-character code, and one that is not printable.
    #expect(RDPDiagnosticText.pixelFormat(0x3432_3076) == "420v (0x34323076)")
    #expect(RDPDiagnosticText.pixelFormat(0x0000_0020) == "0x00000020")
    #expect(RDPDiagnosticText.pixelFormat(nil) == "unknown")
}

/// A report's negotiation reads as names, IDs and hex codes.
@Test func diagnosticTextSummarizesNegotiation() {
    var report = report()
    #expect(RDPDiagnosticText.graphicsCapability(of: report) == "none")
    report.rdpGraphicsSelectedCapabilityVersion = 0x000A_0600
    report.rdpGraphicsSelectedCapabilityFlags = 0x10
    #expect(RDPDiagnosticText.graphicsCapability(of: report) == "0x000a0600 flags=0x00000010")
    report.rdpGraphicsSelectedCapabilityFlags = nil
    #expect(RDPDiagnosticText.graphicsCapability(of: report) == "0x000a0600")

    #expect(RDPDiagnosticText.channels([
        RDPStaticVirtualChannelAssignment(name: "rdpdr", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1005),
    ]) == "rdpdr=1004, cliprdr=1005")
    #expect(RDPDiagnosticText.channels([RDPStaticVirtualChannelAssignment]()) == "none")
    #expect(RDPDiagnosticText.list(nil) == "not attempted")
    #expect(RDPDiagnosticText.list(["synchronize", "control"]) == "synchronize, control")
    #expect(RDPDiagnosticText.messageTypes(["a", "b", "c", "d", "e"]) == "a, b, c, d")
    #expect(RDPDiagnosticText.messageTypes([]) == "not observed")
    #expect(RDPDiagnosticText.displayControlCapabilities(RDPDisplayControlCapabilities(
        maxNumMonitors: 16,
        maxMonitorAreaFactorA: 8192,
        maxMonitorAreaFactorB: 8192
    )) == "max monitors 16, area 8192x8192")
    #expect(RDPDiagnosticText.warnings([
        RDPConnectionWarning(code: "a", message: "first"),
        RDPConnectionWarning(code: "b", message: "second"),
    ]) == "a: first\nb: second")
    #expect(RDPDiagnosticText.warnings([]) == "none")

    report.redirectionDepth = 2
    #expect(RDPDiagnosticText.connectionTarget(of: report) == "127.0.0.1:3389, after 2 server redirections")
    #expect(RDPDiagnosticText.remoteTermination(RDPRemoteTermination(errorInfo: 0x0000_000B))
        == "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER (user)")
}

/// The failure row says which of the update's PDUs failed and which one its summaries start
/// at: around the failing PDU, not at the update's first, in an update of more than 64.
@Test func diagnosticTextSaysWhereAGraphicsFailuresSummariesStart() {
    var report = report()
    #expect(RDPDiagnosticText.graphicsFailure(of: report) == "none")
    report.rdpGraphicsFailureUpdatePayloadHex = "00"
    report.rdpGraphicsFailureUpdateMessageIndex = 80
    report.rdpGraphicsFailureUpdateFirstMessageIndex = 48
    report.rdpGraphicsFailureUpdateMessageCount = 161
    #expect(RDPDiagnosticText.graphicsFailure(of: report) == "message 80 of 161, summaries from 48")

    var message = RDPGFXMessageSummary(typeName: "wire-to-surface-1")
    message.surfaceID = 1
    message.width = 64
    message.height = 32
    message.codecName = "caprogressive"
    message.progressiveRegionTileCount = 4
    message.progressiveTileFirstCount = 0
    message.progressiveTileUpgradeCount = 2
    report.rdpGraphicsFailureUpdateMessages = [message]
    #expect(RDPDiagnosticText.graphicsFailure(of: report)
        == "message 80 of 161, summaries from 48: wire-to-surface-1 s1 64x32 caprogressive tiles 4 upgrade 2")
    // Counts of none are left out.
    message.progressiveTileFirstCount = 3
    message.progressiveTileUpgradeCount = 0
    #expect(RDPDiagnosticText.graphicsUpdates([message]) == "wire-to-surface-1 s1 64x32 caprogressive tiles 4 first 3")

    // An update that did not decode into PDUs failed in transport.
    report.rdpGraphicsFailureUpdateMessageIndex = nil
    report.rdpGraphicsFailureUpdateFirstMessageIndex = nil
    report.rdpGraphicsFailureUpdateMessageCount = nil
    report.rdpGraphicsFailureUpdateMessages = nil
    #expect(RDPDiagnosticText.graphicsFailure(of: report) == "transport")
}

/// The performance line has only what was measured, the display link's rate last.
@Test func diagnosticTextListsTheViewerMetricsThereAre() {
    let metrics = RDPRenderMetrics()
    #expect(RDPDiagnosticText.viewerMetrics(metrics, displayLinkFramesPerSecond: nil, at: Date()).isEmpty)
    #expect(RDPDiagnosticText.viewerMetrics(metrics, displayLinkFramesPerSecond: 120, at: Date()) == ["120 Hz"])
}
