import RDPKit
import RDPKitAppKit
import SwiftUI

/// The rates are those of the 5 s up to `date`, so they fall once traffic stops.
func compactViewerMetricsSummary(
    metrics: RDPRenderMetrics,
    framePacing: RDPFramePacingState,
    at date: Date
) -> String? {
    let parts = RDPDiagnosticText.viewerMetrics(
        metrics,
        displayLinkFramesPerSecond: framePacing.displayLinkFramesPerSecond,
        at: date
    )
    return parts.isEmpty ? nil : parts.joined(separator: " - ")
}

private struct PerformanceMetricsView: View {
    var metrics: RDPRenderMetrics
    var rollingFramesPerSecond: Double?
    var rollingWireMegabitsPerSecond: Double?
    var averageWireMegabitsPerSecond: Double?
    var framePacing: RDPFramePacingState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 8) {
                DiagnosticRow("Presentation Clock", framePacing.clockState)
                DiagnosticRow("Display", framePacing.screenName)
                DiagnosticRow("Display Max", RDPDiagnosticText.hertz(framePacing.maximumRefreshRate))
                DiagnosticRow("Display Link", RDPDiagnosticText.framesPerSecond(framePacing.displayLinkFramesPerSecond))
                DiagnosticRow("Refresh Range", RDPDiagnosticText.refreshRange(framePacing))
                DiagnosticRow("Wire RX", RDPDiagnosticText.megabitsPerSecond(rollingWireMegabitsPerSecond))
                DiagnosticRow("Wire RX Average", RDPDiagnosticText.megabitsPerSecond(averageWireMegabitsPerSecond))
                DiagnosticRow("Wire RX Total", RDPDiagnosticText.bytes(metrics.wireByteCount))
                DiagnosticRow("First Frame Latency", RDPDiagnosticText.milliseconds(metrics.firstFrameLatencyMilliseconds))
                DiagnosticRow("Rolling FPS", RDPDiagnosticText.framesPerSecond(rollingFramesPerSecond))
                DiagnosticRow("Average FPS", RDPDiagnosticText.framesPerSecond(metrics.averageFramesPerSecond))
                DiagnosticRow("Decode Last", RDPDiagnosticText.milliseconds(metrics.lastDecodeMilliseconds))
                DiagnosticRow("Decode Average", RDPDiagnosticText.milliseconds(metrics.averageDecodeMilliseconds))
                DiagnosticRow("Decode Max", RDPDiagnosticText.milliseconds(metrics.maxDecodeMilliseconds))
                DiagnosticRow(
                    "Sample Prep",
                    RDPDiagnosticText.timing(last: metrics.lastSamplePreparationMilliseconds, average: metrics.averageSamplePreparationMilliseconds)
                )
                DiagnosticRow(
                    "VideoToolbox",
                    RDPDiagnosticText.timing(last: metrics.lastVideoToolboxMilliseconds, average: metrics.averageVideoToolboxMilliseconds)
                )
                DiagnosticRow("Hardware Decoder", RDPDiagnosticText.yesNo(metrics.usesHardwareAcceleration, missing: "unknown"))
                DiagnosticRow("Pixel Format", RDPDiagnosticText.pixelFormat(metrics.decodedPixelFormat))
                DiagnosticRow(
                    "Image Convert",
                    RDPDiagnosticText.timing(last: metrics.lastImageConversionMilliseconds, average: metrics.averageImageConversionMilliseconds)
                )
                DiagnosticRow("Decoded Frames", "\(metrics.decodedFrameCount)")
                DiagnosticRow("Decoded Bytes", RDPDiagnosticText.bytes(metrics.decodedByteCount))
                DiagnosticRow("Skipped Presentation Frames", "\(metrics.skippedPresentationFrameCount)")
                DiagnosticRow("Decode Failures", "\(metrics.failedDecodeCount)")
                if let lastDecodeError = metrics.lastDecodeError {
                    DiagnosticRow("Last Decode Error", lastDecodeError)
                }
            }
        }
    }
}

struct RemoteSessionDiagnosticsSnapshot: Equatable {
    var title = "Remote Desktop"
    var report: RDPConnectionReport?
    var previewFrame: RDPFrameMetadata?
    var previewFrameCount = 0
    /// Frames handed to the display; frames the display-link buffer replaced are not counted.
    var presentedFrameCount = 0
    var previewDecodeError: String?
    var serverLayout: RDPServerLayout?
    var renderMetrics = RDPRenderMetrics()
    /// `renderMetrics`' rates when the snapshot was taken: they change with time once traffic
    /// stops, which records nothing new in `renderMetrics`.
    var rollingFramesPerSecond: Double?
    var rollingWireMegabitsPerSecond: Double?
    var averageWireMegabitsPerSecond: Double?
    var framePacing = RDPFramePacingState()
    var sessionEndReason: RDPSessionEndReason?
    var serverCertificateInfo: RDPServerCertificateInfo?
    var viewerPixelSize: RDPViewerPixelSize?
    var requestedDesktopSize = "unknown"
    var inputReady = false
    var displayControlReady = false
    var clipboardReady = false
    var clipboardSharingEnabled = false
    var audioPlaybackEnabled = false
    var certificateTrustedByApp = false
    var certificateTrustMessage: String?
    /// The server's certificate refused ECDHE, so the connection uses RSA key exchange.
    var legacyRSAKeyExchange = false
    /// The user allowed this connection CredSSP below version 5.
    var legacyCredSSP = false
    var formError: String?
    var isConnecting = false
}

@MainActor
final class RemoteSessionDiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot = RemoteSessionDiagnosticsSnapshot()

    func updateSnapshot(_ nextSnapshot: RemoteSessionDiagnosticsSnapshot) {
        guard snapshot != nextSnapshot else {
            return
        }
        snapshot = nextSnapshot
    }
}

struct RemoteSessionDiagnosticsWindowContent: View {
    @ObservedObject var model: RemoteSessionDiagnosticsModel

    var body: some View {
        let snapshot = model.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: snapshot.title)
                        .font(.title2)
                    Text(verbatim: statusLine(snapshot))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let formError = snapshot.formError {
                    InlineNotice(title: "Input", message: formError, systemImage: "exclamationmark.triangle.fill")
                }

                if let previewDecodeError = snapshot.previewDecodeError {
                    InlineNotice(
                        title: "VideoToolbox",
                        message: previewDecodeError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if snapshot.renderMetrics.hasActivity || snapshot.isConnecting {
                    PerformanceMetricsView(
                        metrics: snapshot.renderMetrics,
                        rollingFramesPerSecond: snapshot.rollingFramesPerSecond,
                        rollingWireMegabitsPerSecond: snapshot.rollingWireMegabitsPerSecond,
                        averageWireMegabitsPerSecond: snapshot.averageWireMegabitsPerSecond,
                        framePacing: snapshot.framePacing
                    )
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                    DiagnosticRow("Target", snapshot.report?.target ?? snapshot.title)
                    DiagnosticRow("Status", statusText(snapshot))
                    DiagnosticRow("Connect Attempt", connectAttempt(snapshot.report))
                    DiagnosticRow("Stage", snapshot.report?.stage ?? "not started")
                    DiagnosticRow("Disconnect Reason", disconnectReason(snapshot))
                    DiagnosticRow("Warnings", RDPDiagnosticText.warnings(snapshot.report?.warnings))
                    DiagnosticRow("Requested Desktop", snapshot.requestedDesktopSize)
                    DiagnosticRow("Viewer Size", snapshot.viewerPixelSize?.label ?? "unknown")
                    DiagnosticRow("Requested Protocols", snapshot.report?.requestedProtocols.joined(separator: ", ") ?? "none")
                    DiagnosticRow("Selected Protocols", snapshot.report?.selectedProtocols?.joined(separator: ", ") ?? "none")
                    DiagnosticRow("TLS", snapshot.report?.tlsProtocol ?? "not negotiated")
                    DiagnosticRow(
                        "Key Exchange",
                        snapshot.legacyRSAKeyExchange
                            ? "RSA only, no forward secrecy: the server's certificate refused ECDHE (KEY_USAGE_BIT_INCORRECT)"
                            : "default"
                    )
                    DiagnosticRow(
                        "CredSSP",
                        snapshot.legacyCredSSP
                            ? "versions below 5 allowed, as you agreed: CVE-2018-0886 encryption oracle"
                            : "version 5 or later"
                    )
                    DiagnosticRow("Certificate", certificateState(snapshot))
                    DiagnosticRow("MCS", snapshot.report?.mcsConnectResult ?? "not exchanged")
                    DiagnosticRow("I/O Channel", RDPDiagnosticText.number(snapshot.report?.mcsIOChannelID))
                    DiagnosticRow("Message Channel", RDPDiagnosticText.number(snapshot.report?.mcsMessageChannelID))
                    DiagnosticRow("Static Channels", RDPDiagnosticText.channels(snapshot.report?.mcsStaticChannels))
                    DiagnosticRow("Attach User", snapshot.report?.mcsAttachUserResult ?? "not requested")
                    DiagnosticRow("User Channel", RDPDiagnosticText.number(snapshot.report?.mcsUserChannelID))
                    DiagnosticRow("Joined", RDPDiagnosticText.channels(snapshot.report?.mcsJoinedChannels))
                    DiagnosticRow("Client Info", RDPDiagnosticText.clientInfo(of: snapshot.report))
                    DiagnosticRow("Credentials Sent", RDPDiagnosticText.yesNo(snapshot.report?.rdpClientInfoCredentialsIncluded))
                    DiagnosticRow("Client Info Bytes", RDPDiagnosticText.byteCount(snapshot.report?.rdpClientInfoRequestBytes))
                    DiagnosticRow("Auto-Detect", snapshot.report?.rdpAutoDetectRequestType ?? "not requested")
                    DiagnosticRow("Auto-Detect Seq", RDPDiagnosticText.number(snapshot.report?.rdpAutoDetectSequenceNumber))
                    DiagnosticRow("Post Auto-Detect", snapshot.report?.rdpPostAutoDetectResponseType ?? "none")
                    DiagnosticRow("Licensing", snapshot.report?.rdpLicensingResponseType ?? "not observed")
                    DiagnosticRow("License Code", RDPDiagnosticText.hex(snapshot.report?.rdpLicensingErrorCode))
                    DiagnosticRow("Post Licensing", snapshot.report?.rdpPostLicensingResponseType ?? "none")
                    DiagnosticRow("Demand Share", RDPDiagnosticText.hex(snapshot.report?.rdpDemandActiveShareID))
                    DiagnosticRow("Demand Caps", RDPDiagnosticText.capabilitySets(snapshot.report?.rdpDemandActiveCapabilitySets))
                    DiagnosticRow("Confirm Caps", RDPDiagnosticText.capabilitySets(snapshot.report?.rdpConfirmActiveCapabilitySets))
                    DiagnosticRow("Post Confirm", snapshot.report?.rdpPostConfirmActiveResponseType ?? "none")
                    DiagnosticRow("Finalization", RDPDiagnosticText.list(snapshot.report?.rdpFinalizationResponseTypes))
                    DiagnosticRow("Dynamic Channel", RDPDiagnosticText.list(snapshot.report?.rdpDynamicChannelRequestTypes))
                    DiagnosticRow("Graphics Channel", snapshot.report?.rdpGraphicsChannelName ?? "not opened")
                    DiagnosticRow("Graphics Channel ID", RDPDiagnosticText.number(snapshot.report?.rdpGraphicsChannelID))
                    DiagnosticRow("Graphics Response", snapshot.report?.rdpGraphicsResponseType ?? "none")
                    DiagnosticRow("Graphics Profile", snapshot.report?.rdpGraphicsCapabilityProfile.rawValue ?? "not requested")
                    DiagnosticRow("Graphics", RDPDiagnosticText.graphicsCapability(of: snapshot.report))
                    DiagnosticRow("Graphics Path", RDPGraphicsPathDescription.describe(report: snapshot.report))
                    DiagnosticRow("Graphics Updates", RDPDiagnosticText.graphicsUpdates(snapshot.report?.rdpGraphicsUpdateMessages))
                    DiagnosticRow("Graphics Failure", RDPDiagnosticText.graphicsFailure(of: snapshot.report))
                    DiagnosticRow("Update Packets", RDPDiagnosticText.number(snapshot.report?.rdpGraphicsUpdateResponseCount))
                    DiagnosticRow("Presented Frames", "\(snapshot.presentedFrameCount)")
                    DiagnosticRow("Input", snapshot.inputReady ? "ready" : "not ready")
                    DiagnosticRow("Display Control", snapshot.displayControlReady ? "ready" : "not ready")
                    DiagnosticRow("Display Channel ID", RDPDiagnosticText.number(snapshot.report?.rdpDisplayControlChannelID))
                    DiagnosticRow("Display Caps", RDPDiagnosticText.displayControlCapabilities(snapshot.report?.rdpDisplayControlCaps))
                    DiagnosticRow("Audio", snapshot.audioPlaybackEnabled ? "requested" : "off")
                    DiagnosticRow("Audio Channel ID", RDPDiagnosticText.number(snapshot.report?.rdpAudioChannelID))
                    DiagnosticRow("Audio Messages", RDPDiagnosticText.messageTypes(snapshot.report?.rdpAudioMessages?.map(\.typeName)))
                    DiagnosticRow("Clipboard", clipboardState(snapshot))
                    DiagnosticRow("Clipboard Channel ID", RDPDiagnosticText.number(snapshot.report?.rdpClipboardChannelID))
                    DiagnosticRow("Clipboard Messages", RDPDiagnosticText.messageTypes(snapshot.report?.rdpClipboardMessages?.map(\.typeName)))
                    DiagnosticRow(
                        "First Frame",
                        RDPDiagnosticText.frame(
                            snapshot.previewFrame
                                ?? snapshot.report?.rdpGraphicsFirstFrame.map(RDPFrameMetadata.init)
                        )
                    )
                    DiagnosticRow("Server Layout", serverLayout(snapshot.serverLayout))
                    DiagnosticRow("Frame Acks", RDPDiagnosticText.number(snapshot.report?.rdpGraphicsFrameAcknowledgeCount))
                    DiagnosticRow("Next", snapshot.report?.nextStage ?? "none")
                }

                if let report = snapshot.report {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Negotiation")
                            .font(.headline)
                        MonospaceBlock(title: "Request", value: report.requestHex)
                        if let responseHex = report.responseHex {
                            MonospaceBlock(title: "Response", value: responseHex)
                        }
                        if let certificateSHA256 = report.certificateSHA256 {
                            MonospaceBlock(title: "Certificate SHA-256", value: certificateSHA256)
                        }
                        if let mcsConnectInitialHex = report.mcsConnectInitialHex {
                            MonospaceBlock(title: "MCS Connect Initial", value: mcsConnectInitialHex)
                        }
                        if let mcsConnectResponseHex = report.mcsConnectResponseHex {
                            MonospaceBlock(title: "MCS Connect Response", value: mcsConnectResponseHex)
                        }
                        if let mcsErectDomainRequestHex = report.mcsErectDomainRequestHex {
                            MonospaceBlock(title: "MCS Erect Domain Request", value: mcsErectDomainRequestHex)
                        }
                        if let mcsAttachUserRequestHex = report.mcsAttachUserRequestHex {
                            MonospaceBlock(title: "MCS Attach User Request", value: mcsAttachUserRequestHex)
                        }
                        if let mcsAttachUserConfirmHex = report.mcsAttachUserConfirmHex {
                            MonospaceBlock(title: "MCS Attach User Confirm", value: mcsAttachUserConfirmHex)
                        }
                        if let mcsJoinedChannels = report.mcsJoinedChannels {
                            ForEach(mcsJoinedChannels.indices, id: \.self) { index in
                                let channel = mcsJoinedChannels[index]
                                MonospaceBlock(
                                    title: "MCS Join \(channel.name)",
                                    value: "\(channel.requestHex)\n\(channel.confirmHex)"
                                )
                            }
                        }
                        if let rdpClientInfoResponseHex = report.rdpClientInfoResponseHex {
                            MonospaceBlock(title: "RDP Client Info Response", value: rdpClientInfoResponseHex)
                        }
                        if let rdpAutoDetectResponseHex = report.rdpAutoDetectResponseHex {
                            MonospaceBlock(title: "RDP Auto-Detect Response", value: rdpAutoDetectResponseHex)
                        }
                        if let rdpPostAutoDetectResponseHex = report.rdpPostAutoDetectResponseHex {
                            MonospaceBlock(title: "RDP Post Auto-Detect Response", value: rdpPostAutoDetectResponseHex)
                        }
                        if let rdpPostLicensingResponseHex = report.rdpPostLicensingResponseHex {
                            MonospaceBlock(title: "RDP Post Licensing Response", value: rdpPostLicensingResponseHex)
                        }
                        if let rdpConfirmActiveRequestHex = report.rdpConfirmActiveRequestHex {
                            MonospaceBlock(title: "RDP Confirm Active Request", value: rdpConfirmActiveRequestHex)
                        }
                        if let rdpPostConfirmActiveResponseHex = report.rdpPostConfirmActiveResponseHex {
                            MonospaceBlock(title: "RDP Post Confirm Active Response", value: rdpPostConfirmActiveResponseHex)
                        }
                        if let rdpClientSynchronizeRequestHex = report.rdpClientSynchronizeRequestHex {
                            MonospaceBlock(title: "RDP Client Synchronize Request", value: rdpClientSynchronizeRequestHex)
                        }
                        if let rdpClientControlCooperateRequestHex = report.rdpClientControlCooperateRequestHex {
                            MonospaceBlock(
                                title: "RDP Client Control Cooperate Request",
                                value: rdpClientControlCooperateRequestHex
                            )
                        }
                        if let rdpClientControlRequestHex = report.rdpClientControlRequestHex {
                            MonospaceBlock(title: "RDP Client Control Request", value: rdpClientControlRequestHex)
                        }
                        if let rdpClientFontListRequestHex = report.rdpClientFontListRequestHex {
                            MonospaceBlock(title: "RDP Client Font List Request", value: rdpClientFontListRequestHex)
                        }
                        if let rdpFinalizationResponseHexes = report.rdpFinalizationResponseHexes {
                            ForEach(rdpFinalizationResponseHexes.indices, id: \.self) { index in
                                let type = report.rdpFinalizationResponseTypes?[safe: index] ?? "response"
                                MonospaceBlock(
                                    title: "RDP Finalization \(index + 1) \(type)",
                                    value: rdpFinalizationResponseHexes[index]
                                )
                            }
                        }
                        if let rdpDynamicChannelCapabilitiesResponseHex = report.rdpDynamicChannelCapabilitiesResponseHex {
                            MonospaceBlock(
                                title: "DRDYNVC Capabilities Response",
                                value: rdpDynamicChannelCapabilitiesResponseHex
                            )
                        }
                        if let rdpGraphicsChannelCreateResponseHex = report.rdpGraphicsChannelCreateResponseHex {
                            MonospaceBlock(
                                title: "RDPGFX Channel Create Response",
                                value: rdpGraphicsChannelCreateResponseHex
                            )
                        }
                        if let rdpDisplayControlChannelCreateResponseHex = report
                            .rdpDisplayControlChannelCreateResponseHex
                        {
                            MonospaceBlock(
                                title: "Display Control Channel Create Response",
                                value: rdpDisplayControlChannelCreateResponseHex
                            )
                        }
                        if let rdpGraphicsCapsAdvertiseHex = report.rdpGraphicsCapsAdvertiseHex {
                            MonospaceBlock(title: "RDPGFX Caps Advertise", value: rdpGraphicsCapsAdvertiseHex)
                        }
                        if let rdpDisplayControlCapsHex = report.rdpDisplayControlCapsHex {
                            MonospaceBlock(title: "Display Control Caps", value: rdpDisplayControlCapsHex)
                        }
                        if let rdpGraphicsResponseHex = report.rdpGraphicsResponseHex {
                            MonospaceBlock(title: "RDPGFX Response", value: rdpGraphicsResponseHex)
                        }
                        if let rdpGraphicsFrameAcknowledgeHexes = report.rdpGraphicsFrameAcknowledgeHexes {
                            ForEach(rdpGraphicsFrameAcknowledgeHexes.indices, id: \.self) { index in
                                MonospaceBlock(
                                    title: "RDPGFX Frame Acknowledge \(index + 1)",
                                    value: rdpGraphicsFrameAcknowledgeHexes[index]
                                )
                            }
                        }
                        if let rdpGraphicsUpdateResponseHexes = report.rdpGraphicsUpdateResponseHexes {
                            ForEach(rdpGraphicsUpdateResponseHexes.indices, id: \.self) { index in
                                let title = report.rdpGraphicsUpdateMessages?[safe: index].map {
                                    "RDPGFX Update \(index + 1) \($0.typeName)"
                                } ?? "RDPGFX Update \(index + 1)"
                                MonospaceBlock(
                                    title: title,
                                    value: rdpGraphicsUpdateResponseHexes[index]
                                )
                            }
                        }
                        if let failurePayloadHex = report.rdpGraphicsFailureUpdatePayloadHex {
                            MonospaceBlock(title: "RDPGFX Failure Payload", value: failurePayloadHex)
                        }
                        if let failureResponseHex = report.rdpGraphicsFailureUpdateResponseHex {
                            MonospaceBlock(title: "RDPGFX Failure Response", value: failureResponseHex)
                        }
                        if let rdpDynamicChannelRequestHexes = report.rdpDynamicChannelRequestHexes {
                            // The hex list holds the first drdynvc packets; the type list is not index-aligned with it.
                            ForEach(rdpDynamicChannelRequestHexes.indices, id: \.self) { index in
                                MonospaceBlock(
                                    title: "DRDYNVC \(index + 1)",
                                    value: rdpDynamicChannelRequestHexes[index]
                                )
                            }
                        }
                        if let error = report.error {
                            MonospaceBlock(title: "Error", value: error)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Stats for Nerds")
    }

    private func statusLine(_ snapshot: RemoteSessionDiagnosticsSnapshot) -> String {
        [
            statusText(snapshot),
            snapshot.report?.stage ?? "not started",
            RDPDiagnosticText.framesPerSecond(snapshot.rollingFramesPerSecond),
            RDPDiagnosticText.megabitsPerSecond(snapshot.rollingWireMegabitsPerSecond),
        ].joined(separator: " - ")
    }

    private func statusText(_ snapshot: RemoteSessionDiagnosticsSnapshot) -> String {
        if snapshot.isConnecting {
            if snapshot.previewFrameCount > 0 {
                return "Receiving"
            }
            return snapshot.report?.nextConnectAttemptDate == nil ? "Connecting" : "Waiting to retry"
        }
        if let sessionEndReason = snapshot.sessionEndReason {
            return sessionEndReason.statusText
        }
        return snapshot.report?.status ?? "Not Connected"
    }

    private func disconnectReason(_ snapshot: RemoteSessionDiagnosticsSnapshot) -> String {
        if let sessionEndReason = snapshot.sessionEndReason {
            return sessionEndReason.diagnosticValue
        }
        if let error = snapshot.report?.error {
            return error
        }
        return "none"
    }

    private func certificateState(_ snapshot: RemoteSessionDiagnosticsSnapshot) -> String {
        if snapshot.certificateTrustedByApp {
            return "trusted for this host"
        }
        if let message = snapshot.certificateTrustMessage {
            return message
        }
        guard let trusted = snapshot.report?.certificateTrusted ?? snapshot.serverCertificateInfo?.trusted else {
            return "not available"
        }
        return trusted ? "trusted" : "unrecognized"
    }

    /// Which try connects, and while waiting to try again, when the next one starts.
    private func connectAttempt(_ report: RDPConnectionReport?) -> String {
        guard let attempt = report?.connectAttempt else {
            return "not attempted"
        }
        guard let next = report?.nextConnectAttemptDate else {
            return "\(attempt)"
        }
        return "\(attempt) failed, next in \(String(format: "%.0f s", max(next.timeIntervalSinceNow, 0)))"
    }

    /// The server's monitors as of the last frame, its ResetGraphics count, and what RDPKit
    /// found wrong with the layout.
    private func serverLayout(_ layout: RDPServerLayout?) -> String {
        guard let layout else {
            return "none"
        }
        let monitors = layout.monitors.isEmpty
            ? "no monitors listed"
            : layout.monitors.map { monitor in
                let rect = monitor.rect
                return "\(rect.width)x\(rect.height) at \(rect.left),\(rect.top)\(monitor.isPrimary ? " primary" : "")"
            }.joined(separator: "; ")
        let issues: [(RDPRemoteMonitorLayoutIssues, String)] = [
            (.clipped, "clipped"),
            (.overlapping, "overlapping"),
            (.noPrimary, "no primary"),
            (.multiplePrimaries, "several primaries"),
            (.uncoveredOutput, "uncovered output"),
        ]
        let found = issues.filter { layout.monitorLayoutIssues.contains($0.0) }.map(\.1)
        let issueText = found.isEmpty ? "" : ", \(found.joined(separator: ", "))"
        return "\(monitors), reset \(layout.graphicsResetCount)\(issueText)"
    }

    private func clipboardState(_ snapshot: RemoteSessionDiagnosticsSnapshot) -> String {
        guard snapshot.clipboardSharingEnabled else {
            return "disabled"
        }
        return snapshot.clipboardReady ? "ready" : "not ready"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct DiagnosticRow: View {
    private var title: String
    private var value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .textSelection(.enabled)
        }
    }
}

struct InlineNotice: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MonospaceBlock: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
