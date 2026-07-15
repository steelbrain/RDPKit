import Foundation
@testable import RDPKit
import Testing

@Suite(.serialized)
struct KRDPRegressionCoverageTests {
@Test func regression01ClientFinalizationWaitsForServerSynchronizeInKRDPFixture() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let confirmActiveIndex = try clientApplicationIndex(events, ordinal: 9)
    let serverSynchronizeIndex = try firstServerShareDataIndex(
        events,
        after: confirmActiveIndex,
        typeName: "server-synchronize"
    )
    let nextClientIndex = try firstClientApplicationIndex(events, after: confirmActiveIndex)

    #expect(serverSynchronizeIndex < nextClientIndex)
}

@Test func regression02ClientFinalizationWaitsForServerControlCooperateInKRDPFixture() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let confirmActiveIndex = try clientApplicationIndex(events, ordinal: 9)
    let controlCooperateIndex = try firstServerShareDataIndex(
        events,
        after: confirmActiveIndex,
        typeName: "control-cooperate"
    )
    let nextClientIndex = try firstClientApplicationIndex(events, after: confirmActiveIndex)

    #expect(controlCooperateIndex < nextClientIndex)
}

@Test func regression03KRDPFixtureHasSeparateServerSynchronizeAndControlCooperatePackets() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let confirmActiveIndex = try clientApplicationIndex(events, ordinal: 9)
    let synchronizeIndex = try firstServerShareDataIndex(events, after: confirmActiveIndex, typeName: "server-synchronize")
    let cooperateIndex = try firstServerShareDataIndex(events, after: confirmActiveIndex, typeName: "control-cooperate")

    #expect(synchronizeIndex != cooperateIndex)
    #expect(synchronizeIndex < cooperateIndex)
}

@Test func regression04BackToBackServerFinalizationPDUsAreRecordedBeforeClientFinalization() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let confirmActiveIndex = try clientApplicationIndex(events, ordinal: 9)
    let synchronizeIndex = try firstServerShareDataIndex(events, after: confirmActiveIndex, typeName: "server-synchronize")
    let cooperateIndex = try firstServerShareDataIndex(events, after: confirmActiveIndex, typeName: "control-cooperate")
    let nextClientIndex = try firstClientApplicationIndex(events, after: confirmActiveIndex)

    #expect(synchronizeIndex + 1 == cooperateIndex)
    #expect(cooperateIndex + 1 == nextClientIndex)
}

@Test func regression05MockKRDPCompletesWhenServerFinalizationPDUsArriveFirst() throws {
    let report = try runRegressionPreflight()

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("control-cooperate") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
}

@Test func regression06ServerControlCooperateBeforeSynchronizeCompletesViaShippedTracker() throws {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "control-cooperate")
    tracker.observe(typeName: "server-synchronize")
    tracker.observe(typeName: "control-granted-control")
    tracker.observe(typeName: "font-map")

    #expect(tracker.observedTypeNames.prefix(2) == ["control-cooperate", "server-synchronize"])
    #expect(tracker.isComplete)
    // Wire-level pin: reverse ordering still parses as Share Data from real TPKT bytes.
    let cooperate = try #require(try RDPShareDataPDU.parseIfPresent(
        fromTPKT: shareDataPacket(type: 0x14, payload: controlPayload(action: 0x0004))
    ))
    let synchronize = try #require(try RDPShareDataPDU.parseIfPresent(
        fromTPKT: shareDataPacket(type: 0x1F, payload: synchronizePayload(targetUser: 1006))
    ))
    #expect(cooperate.typeName == "control-cooperate")
    #expect(synchronize.typeName == "server-synchronize")
}

@Test func regression07SaveSessionInfoBeforeSynchronizeDoesNotCompleteFinalization() throws {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "save-session-info")
    tracker.observe(typeName: "server-synchronize")

    #expect(tracker.isComplete == false)
    #expect(RDPConnectionFinalizationTracker.isOptionalInterveningShareDataType("save-session-info"))
    #expect(RDPConnectionFinalizationTracker.isConnectionFinalizationShareDataType("server-synchronize"))
}

@Test func regression08MonitorLayoutBeforeSynchronizeDoesNotCompleteFinalization() throws {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "monitor-layout")
    tracker.observe(typeName: "server-synchronize")

    #expect(tracker.isComplete == false)
    #expect(RDPConnectionFinalizationTracker.isOptionalInterveningShareDataType("monitor-layout"))
}

@Test func regression09UnrelatedShareDataBeforeSynchronizeDoesNotCompleteFinalization() throws {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "set-error-info")
    tracker.observe(typeName: "server-synchronize")

    #expect(tracker.isComplete == false)
    #expect(RDPConnectionFinalizationTracker.isOptionalInterveningShareDataType("set-error-info"))
}

@Test func regression10PostConfirmResponseOrderMatchesKRDPFixture() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let confirmActiveIndex = try clientApplicationIndex(events, ordinal: 9)
    let responseTypes = try serverShareDataTypes(events, after: confirmActiveIndex, limit: 4)

    #expect(responseTypes == [
        "server-synchronize",
        "control-cooperate",
        "control-granted-control",
        "font-map",
    ])
}

@Test func regression11MinimalKRDPDemandActiveSelectsCompactConfirmActive() throws {
    let demandActive = try demandActiveWithBitmapCodecs(length: 5)

    #expect(demandActive.requestsMinimalBitmapCodecs)
}

@Test func regression12CompactConfirmActiveDeclaresSpecCorrectTotalLength() {
    let confirm = compactConfirmActive()
    let userData = confirm.encodedPDUData(userChannelID: 1006)
    #expect(Int(le16(userData, 0)) == userData.count)
    #expect(le16(userData, 10) == RDPServerChannelID.fixed)
}

@Test func regression12bCompactConfirmActiveIncludesMandatoryCapabilitySets() {
    let capabilityNames = Set(compactConfirmActive().capabilitySets.map(\.name))
    let mandatoryCapabilityNames: Set<String> = [
        "general",
        "bitmap",
        "order",
        "bitmap-cache",
        "pointer",
        "input",
        "brush",
        "glyph-cache",
        "offscreen-cache",
        "virtual-channel",
    ]

    #expect(mandatoryCapabilityNames.isSubset(of: capabilityNames))
}

@Test func regression13CompactConfirmActiveOmitsActivationCapability() {
    let capabilityNames = compactConfirmActive().capabilitySets.map(\.name)

    #expect(!capabilityNames.contains("activation"))
}

@Test func regression14CompactConfirmActiveOmitsControlCapability() {
    let capabilityNames = compactConfirmActive().capabilitySets.map(\.name)

    #expect(!capabilityNames.contains("control"))
}

@Test func regression15CompactConfirmActiveOmitsShareCapability() {
    let capabilityNames = compactConfirmActive().capabilitySets.map(\.name)

    #expect(!capabilityNames.contains("share"))
}

@Test func regression16ExtendedDemandActiveUsesFullConfirmActiveCapabilities() throws {
    let demandActive = try demandActiveWithBitmapCodecs(length: 12)
    let confirmActive = RDPClientConfirmActivePDU(
        shareID: demandActive.shareID,
        includeActivationControlShareCapabilities: !demandActive.requestsMinimalBitmapCodecs
    )

    #expect(confirmActive.capabilitySets.map(\.name).contains("activation"))
    #expect(confirmActive.capabilitySets.map(\.name).contains("control"))
    #expect(confirmActive.capabilitySets.map(\.name).contains("share"))
}

@Test func regression17FullConfirmActiveAdvertisesBitmapCodecs() {
    #expect(fullConfirmActive().capabilitySets.map(\.name).contains("bitmap-codecs"))
}

@Test func regression18FullConfirmActiveAdvertisesFrameAcknowledge() {
    #expect(fullConfirmActive().capabilitySets.map(\.name).contains("frame-acknowledge"))
}

@Test func regression19CompactConfirmActiveOmitsBitmapCodecsLikeTag010() {
    #expect(!compactConfirmActive().capabilitySets.map(\.name).contains("bitmap-codecs"))
}

@Test func regression20CompactConfirmActiveOmitsFrameAcknowledgeLikeTag010() {
    #expect(!compactConfirmActive().capabilitySets.map(\.name).contains("frame-acknowledge"))
}

@Test func regression21ConnectTimeRTTEmitsShortRTTResponse() {
    let request = RDPServerAutoDetectRequest(channelID: 1006, sequenceNumber: 0x23, requestType: 0x1001, payloadByteCount: 0)

    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func regression22ConnectTimeRTTResponsePacketLengthMatchesKRDPFixture() {
    let response = RDPServerAutoDetectRequest(
        channelID: 1006,
        sequenceNumber: 0x23,
        requestType: 0x1001,
        payloadByteCount: 0
    ).response()?.encodedTPKT(userChannelID: 1007, messageChannelID: 1006)

    #expect(response?.count == 24)
}

@Test func regression23ConnectTimeBandwidthStillEmitsNetworkCharacteristicsSync() {
    let request = RDPServerAutoDetectRequest(channelID: 1006, sequenceNumber: 0x23, requestType: 0x1014, payloadByteCount: 0)

    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.networkCharacteristicsSync)
}

@Test func regression24PostConnectRTTStillEmitsRTTResponse() {
    let request = RDPServerAutoDetectRequest(channelID: 1006, sequenceNumber: 0x23, requestType: 0x0001, payloadByteCount: 0)

    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func regression25NetworkCharacteristicsResultGetsCompatibilityRTTBarrier() {
    let request = RDPServerAutoDetectRequest(channelID: 1006, sequenceNumber: 0x23, requestType: 0x08C0, payloadByteCount: 0)

    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func regression26KRDPFixtureAutoDetectReachesDemandActiveAfterShortResponse() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let autoDetectResponseIndex = try clientApplicationIndex(events, ordinal: 8)
    let demandActive = try firstServerShareControlIndex(events, after: autoDetectResponseIndex, typeName: "server-demand-active")

    #expect(events[autoDetectResponseIndex].byteCount == 24)
    #expect(demandActive > autoDetectResponseIndex)
}

@Test func regression27GnomeFixtureAutoDetectReachesDemandActive() throws {
    let events = try loadRegressionTranscript("gnome-negotiation-transcript")
    let demandActiveIndex = try #require(events.firstIndex {
        guard $0.direction == .serverToClient,
              let bytes = $0.bytes,
              let pdu = try? RDPShareControlPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return pdu.typeName == "server-demand-active"
    })

    #expect(demandActiveIndex > 0)
}

@Test func regression28ConnectTimeRTTDoesNotContributeMeasuredBandwidthBytes() {
    let request = RDPServerAutoDetectRequest(channelID: 1006, sequenceNumber: 0x23, requestType: 0x1001, payloadByteCount: 64)

    #expect(request.measuredByteCountContribution == 0)
}

@Test func regression29MalformedAutoDetectPacketThrowsBeforeActivation() {
    var malformedUserData = Data()
    malformedUserData.appendLittleEndianUInt16(0x1000)
    malformedUserData.appendLittleEndianUInt16(0)
    malformedUserData.appendUInt8(0x09)
    malformedUserData.appendUInt8(0)
    malformedUserData.appendLittleEndianUInt16(0x0023)
    malformedUserData.appendLittleEndianUInt16(0x1001)
    let malformed = mcsSendDataIndicationTPKT(userData: malformedUserData)

    #expect(throws: RDPDecodeError.invalidAutoDetectRequest) {
        try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: malformed)
    }
}

@Test func regression30KRDPFixtureAutoDetectOrderingMatchesExpectedSequence() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")

    #expect(events[16].direction == .serverToClient)
    #expect(events[17].direction == .clientToServer)
    #expect(events[17].byteCount == 24)
    #expect(events[18].direction == .serverToClient)
    #expect(events[19].direction == .serverToClient)
}

@Test func regression31DeactivateBeforeRDPGFXFails() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .deactivateAfterFontMap)

    #expect(report.status == "failure")
    #expect(report.error == "server deactivated the session before opening RDPGFX dynamic channel")
}

@Test func regression32DirectUserRequestedBeforeRDPGFXFails() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .userRequestedDisconnectAfterFontMap)

    #expect(report.status == "failure")
    #expect(report.rdpRemoteTerminationDisconnectReasonName == "rn-user-requested")
}

@Test func regression33DeactivateThenUserRequestedBeforeRDPGFXFails() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .deactivateThenUserRequestedDisconnectAfterFontMap)

    #expect(report.status == "failure")
    #expect(report.error == "server ended the session with rn-user-requested before opening RDPGFX dynamic channel")
}

@Test func regression34LogoffByUserBeforeRDPGFXFailsWithoutGraphicsConfirmation() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .setErrorInfoLogoffThenDeactivateAfterFontMap)

    #expect(report.status == "failure")
    #expect(report.rdpGraphicsResponseType == nil)
}

@Test func regression35LogoffByUserAfterFirstFrameIsCleanSessionEnd() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .setErrorInfoLogoffBeforeFrame)
    defer { server.stop() }

    let report = RDPPreflightClient().run(configuration: regressionConfiguration(port: server.port))

    #expect(report.status == "success")
    #expect(report.nextStage == "rdp-session-ended")
}

@Test func regression36NonCleanERRINFOBeforeRDPGFXSurfacesERRINFOCode() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .setErrorInfoDeniedThenDeactivateAfterFontMap)

    #expect(report.error == "server ended the session with ERRINFO_0x00000007 before opening RDPGFX dynamic channel")
}

@Test func regression37NonCleanERRINFOBeforeGraphicsFrameFailsClearly() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .setErrorInfoDeniedThenDeactivateAfterFontMap)

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
}

@Test func regression38RemoteCloseAfterFontMapReportsGraphicsDynamicChannelStage() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .deactivateAfterFontMap)

    #expect(report.stage == "rdp-graphics-dynamic-channel")
}

@Test func regression39MissingFontMapReportsConnectionFinalizationStage() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .grantControlWithoutFontMap)

    #expect(report.stage == "rdp-connection-finalization")
    #expect(report.error == "server did not send Font Map during connection finalization")
}

@Test func regression40PreGraphicsRemoteTerminationHasNoNextStage() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .userRequestedDisconnectAfterFontMap)

    #expect(report.nextStage == nil)
}

@Test func regression41PreGraphicsDisconnectTranscriptShapeIsFailureMode() throws {
    let events = try loadRegressionTranscript("krdp-negotiation-transcript")
    let graphicsCreateRequestIndex = try clientApplicationIndex(events, ordinal: 14)

    #expect(events[graphicsCreateRequestIndex].byteCount == 26)
}

@Test func regression42MockDemandWithoutMinimalBitmapCodecsUsesFullConfirmActive() throws {
    let report = try runRegressionPreflight()

    // Mock demand omits minimal bitmap-codecs → full Confirm Active path.
    #expect(report.rdpConfirmActiveRequestHex.flatMap { Data(rdpHexString: $0)?.count } == 583)
}

@Test func regression54LiveKRDPStyleMinimalBitmapCodecsSelectsCompactConfirm() throws {
    let demandActive = try demandActiveWithBitmapCodecs(length: 5)
    let confirm = RDPClientConfirmActivePDU(
        shareID: demandActive.shareID,
        includeActivationControlShareCapabilities: !demandActive.requestsMinimalBitmapCodecs
    )
    #expect(demandActive.requestsMinimalBitmapCodecs)
    #expect(confirm.capabilitySets.count == 14)
    let userData = confirm.encodedPDUData(userChannelID: 1006)
    #expect(Int(le16(userData, 0)) == userData.count)
}

@Test func regression55SynchronizeTargetUsesDemandActiveSourceOrFixedServerChannelID() {
    // Spec dual-legal: fixed 0x03EA (3.2.1.6) or Demand Active pduSource (3.2.5.3.13.1).
    let fixed = RDPClientSynchronizePDU(shareID: 1, targetUser: RDPServerChannelID.fixed)
        .encodedPDUData(userChannelID: 1006)
    let fromDemand = RDPClientSynchronizePDU(shareID: 1, targetUser: 1007)
        .encodedPDUData(userChannelID: 1006)
    #expect(fixed.suffix(2) == Data([0xEA, 0x03]))
    #expect(fromDemand.suffix(2) == Data([0xEF, 0x03]))
}

private func le16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

@Test func regression43KRDPReplayReachesDRDYNVCCapabilitiesRequest() throws {
    let report = try replayRegressionTranscript("krdp-negotiation-transcript")

    #expect(report.rdpDynamicChannelCapabilitiesResponseHex != nil)
}

@Test func regression44KRDPReplayReachesGraphicsCreateRequest() throws {
    let report = try replayRegressionTranscript("krdp-negotiation-transcript")

    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsChannelCreateResponseHex != nil)
}

@Test func regression45KRDPReplayReachesRDPGFXCapsConfirm() throws {
    let report = try replayRegressionTranscript("krdp-negotiation-transcript")

    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
}

@Test func regression46KRDPReplayProducesFirstAVC420Frame() throws {
    let report = try replayRegressionTranscript("krdp-negotiation-transcript")

    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
}

@Test func regression47GnomeCAPROGRESSIVEReplayStillReachesFirstFrame() throws {
    let report = try replayRegressionTranscript("gnome-negotiation-transcript")

    #expect(report.status == "success")
    #expect(report.rdpGraphicsFirstFrame != nil)
}

@Test func regression48WindowsAuxiliaryDynamicChannelsPreserveActivationOrdering() throws {
    let report = try runRegressionPreflight(auxiliaryDynamicChannelBehavior: .windowsInputAndCursor)

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("control-cooperate") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
}

@Test func regression49ClipboardEnabledAndDisabledLayoutsPreserveActivationOrdering() throws {
    let disabled = try runRegressionPreflight(clipboardEnabled: false)
    let enabled = try runRegressionPreflight(clipboardEnabled: true)

    #expect(disabled.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(enabled.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(disabled.status == "success")
    #expect(enabled.status == "success")
}

@Test func regression51ControlCooperateBeforeSynchronizeMockCompletesWithShippedClient() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .controlCooperateBeforeSynchronize)

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.prefix(2) == ["control-cooperate", "server-synchronize"])
    #expect(report.rdpGraphicsFirstFrame != nil)
}

@Test func regression52WaitForClientSynchronizeBeforeServerSynchronizeCompletes() throws {
    let report = try runRegressionPreflight(finalizationBehavior: .waitForClientSynchronizeBeforeServerSynchronize)

    #expect(report.status == "success")
    #expect(report.rdpFinalizationResponseTypes?.contains("server-synchronize") == true)
    #expect(report.rdpFinalizationResponseTypes?.contains("font-map") == true)
    #expect(report.rdpGraphicsFirstFrame != nil)
}

@Test func regression53GnomeAndKRDPTranscriptReplaysSucceedTogether() throws {
    let krdp = try replayRegressionTranscript("krdp-negotiation-transcript")
    let gnome = try replayRegressionTranscript("gnome-negotiation-transcript")

    #expect(krdp.status == "success")
    #expect(gnome.status == "success")
    #expect(krdp.rdpGraphicsFirstFrame != nil)
    #expect(gnome.rdpGraphicsFirstFrame != nil)
    #expect(krdp.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(gnome.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
}

@Test func regression50WireTranscriptRedactsClientApplicationPayloadsButKeepsByteCounts() throws {
    let transcript = RDPWireTranscript()
    _ = try runRegressionPreflight(wireTranscript: transcript)
    let clientApplicationEvents = transcript.events.filter {
        $0.direction == .clientToServer && $0.layer == .application
    }

    #expect(!clientApplicationEvents.isEmpty)
    #expect(clientApplicationEvents.allSatisfy { $0.hex == nil && $0.byteCount > 0 })
}
}

private func runRegressionPreflight(
    finalizationBehavior: MockKRDPFinalizationBehavior = .grantBeforeFontList,
    auxiliaryDynamicChannelBehavior: MockKRDPAuxiliaryDynamicChannelBehavior = .none,
    clipboardEnabled: Bool = false,
    wireTranscript: RDPWireTranscript? = nil
) throws -> RDPPreflightReport {
    let server = try MockKRDPServer.start(
        finalizationBehavior: finalizationBehavior,
        auxiliaryDynamicChannelBehavior: auxiliaryDynamicChannelBehavior,
        remoteClipboardText: clipboardEnabled ? "clipboard" : nil
    )
    defer { server.stop() }

    return RDPPreflightClient().run(
        configuration: regressionConfiguration(port: server.port, clipboardEnabled: clipboardEnabled),
        wireTranscript: wireTranscript
    )
}

private func regressionConfiguration(port: UInt16, clipboardEnabled: Bool = false) -> RDPConnectionConfiguration {
    RDPConnectionConfiguration(
        host: "127.0.0.1",
        port: port,
        credentials: RDPCredentials(username: "rdp-user", password: "secret"),
        timeoutSeconds: 5,
        hideCertificateWarnings: true,
        graphicsFrameCaptureLimit: 1,
        desktopWidth: 1280,
        desktopHeight: 720,
        clipboardEnabled: clipboardEnabled,
        graphicsCapabilityProfile: .automatic
    )
}

private func replayRegressionTranscript(_ fixtureName: String) throws -> RDPPreflightReport {
    let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
    let server = try RDPTranscriptReplayServer.start(
        transcript: loadRegressionTranscript(fixtureName),
        credentials: credentials
    )
    defer { server.stop() }

    return RDPPreflightClient().run(
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
}

private func compactConfirmActive() -> RDPClientConfirmActivePDU {
    RDPClientConfirmActivePDU(
        shareID: 0x0001_03EE,
        includeActivationControlShareCapabilities: false
    )
}

private func compactConfirmActivePacket() -> Data {
    compactConfirmActive().encodedTPKT(userChannelID: 1006, ioChannelID: 1003)
}

private func fullConfirmActive() -> RDPClientConfirmActivePDU {
    RDPClientConfirmActivePDU(shareID: 0x0001_03EE)
}

private func demandActiveWithBitmapCodecs(length: UInt16) throws -> RDPDemandActivePDU {
    let bodyCount = max(0, Int(length) - 4)
    return try #require(try RDPDemandActivePDU.parseIfPresent(
        fromTPKT: demandActivePacket(capabilitySets: [
            capabilitySet(type: 0x001D, body: Data(repeating: 0, count: bodyCount)),
        ])
    ))
}

private func loadRegressionTranscript(_ name: String) throws -> [RDPWireEvent] {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try JSONDecoder().decode([RDPWireEvent].self, from: Data(contentsOf: url))
}

private func clientApplicationIndex(_ events: [RDPWireEvent], ordinal: Int) throws -> Int {
    let indexes = events.indices.filter {
        events[$0].direction == .clientToServer && events[$0].layer == .application
    }
    return try #require(indexes[safe: ordinal])
}

private func firstClientApplicationIndex(_ events: [RDPWireEvent], after index: Int) throws -> Int {
    try #require(events[(index + 1)...].firstIndex {
        $0.direction == .clientToServer && $0.layer == .application
    })
}

private func firstServerShareDataIndex(_ events: [RDPWireEvent], after index: Int, typeName: String) throws -> Int {
    try #require(events[(index + 1)...].firstIndex {
        guard $0.direction == .serverToClient,
              $0.layer == .application,
              let bytes = $0.bytes,
              let shareData = try? RDPShareDataPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return shareData.typeName == typeName
    })
}

private func firstServerShareControlIndex(_ events: [RDPWireEvent], after index: Int, typeName: String) throws -> Int {
    try #require(events[(index + 1)...].firstIndex {
        guard $0.direction == .serverToClient,
              $0.layer == .application,
              let bytes = $0.bytes,
              let shareControl = try? RDPShareControlPDU.parseIfPresent(fromTPKT: bytes)
        else {
            return false
        }
        return shareControl.typeName == typeName
    })
}

private func serverShareDataTypes(_ events: [RDPWireEvent], after index: Int, limit: Int) throws -> [String] {
    var types: [String] = []
    for event in events[(index + 1)...] where event.direction == .serverToClient && event.layer == .application {
        guard let bytes = event.bytes,
              let shareData = try RDPShareDataPDU.parseIfPresent(fromTPKT: bytes)
        else {
            continue
        }
        types.append(shareData.typeName)
        if types.count == limit {
            break
        }
    }
    return types
}

private func demandActivePacket(capabilitySets: [Data]) -> Data {
    let sourceDescriptor = Data("RDP\u{0}".utf8)
    let capabilityBytes = capabilitySets.reduce(into: Data()) { $0.append($1) }
    let combinedCapabilitiesLength = 4 + capabilityBytes.count
    let totalLength = 6 + 4 + 2 + 2 + sourceDescriptor.count + combinedCapabilitiesLength + 4

    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(totalLength))
    userData.appendLittleEndianUInt16(0x0011)
    userData.appendLittleEndianUInt16(1006)
    userData.appendLittleEndianUInt32(0x0001_03EE)
    userData.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
    userData.appendLittleEndianUInt16(UInt16(combinedCapabilitiesLength))
    userData.append(sourceDescriptor)
    userData.appendLittleEndianUInt16(UInt16(capabilitySets.count))
    userData.appendLittleEndianUInt16(0)
    userData.append(capabilityBytes)
    userData.appendLittleEndianUInt32(0)

    return mcsSendDataIndicationTPKT(userData: userData)
}

private func capabilitySet(type: UInt16, body: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt16(UInt16(body.count + 4))
    data.append(body)
    return data
}

private func shareDataPacket(type: UInt8, payload: Data) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(18 + payload.count))
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1006)
    userData.appendLittleEndianUInt32(0x0001_03EE)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(UInt16(8 + payload.count))
    userData.appendUInt8(type)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.append(payload)

    return mcsSendDataIndicationTPKT(userData: userData)
}

private func mcsSendDataIndicationTPKT(userData: Data, initiator: UInt16 = 1006, channelID: UInt16 = 1003) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(initiator - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

private func synchronizePayload(targetUser: UInt16) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(targetUser)
    return payload
}

private func controlPayload(action: UInt16) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(action)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(0)
    return payload
}

private func monitorLayoutPacket() -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(1279)
    payload.appendLittleEndianUInt32(719)
    payload.appendLittleEndianUInt32(1)
    return shareDataPacket(type: 0x37, payload: payload)
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
