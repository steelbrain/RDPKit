import Foundation
@testable import RDPKit
import Testing

@Test func clientSynchronizePDUUsesServerChannelTarget() {
    // Default targetUser is fixed server channel ID 0x03EA (MS-RDPBCGR 3.2.1.6).
    let packet = RDPClientSynchronizePDU(shareID: 0x0001_03EE)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet == hexData("""
    03 00 00 24 02 f0 80 64 00 05 03 eb 70 16
    16 00 17 00 ee 03 ee 03 01 00 00 01 08 00 1f 00 00 00 01 00 ea 03
    """))
    #expect(RDPServerChannelID.fixed == 1002)
}

@Test func clientSynchronizePDUCanTargetDemandActiveSource() {
    // After Demand Active processing, targetUser SHOULD be the stored
    // pduSource (MS-RDPBCGR 3.2.5.3.13.1 / 3.2.5.3.14).
    let packet = RDPClientSynchronizePDU(shareID: 0x0001_03EE, targetUser: 1007)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet.suffix(4) == hexData("01 00 ef 03"))
}

@Test func clientControlPDUsEncodeCooperateAndRequestControl() {
    let cooperate = RDPClientControlPDU.cooperate(shareID: 0x0001_03EE)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)
    let requestControl = RDPClientControlPDU.requestControl(shareID: 0x0001_03EE)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(cooperate == hexData("""
    03 00 00 28 02 f0 80 64 00 05 03 eb 70 1a
    1a 00 17 00 ee 03 ee 03 01 00 00 01 0c 00 14 00 00 00
    04 00 00 00 00 00 00 00
    """))
    #expect(requestControl.suffix(8) == hexData("01 00 00 00 00 00 00 00"))
}

@Test func clientFontListPDUAdvertisesEmptyFontList() {
    let packet = RDPClientFontListPDU(shareID: 0x0001_03EE)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet == hexData("""
    03 00 00 28 02 f0 80 64 00 05 03 eb 70 1a
    1a 00 17 00 ee 03 ee 03 01 00 00 01 0c 00 27 00 00 00
    00 00 00 00 03 00 32 00
    """))
}

@Test func clientFrameAcknowledgePDUUsesFrameAcknowledgeShareDataType() {
    let packet = RDPClientFrameAcknowledgePDU(
        shareID: 0x0001_03EE,
        frameID: 42
    )
    .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet == hexData("""
    03 00 00 24 02 f0 80 64 00 05 03 eb 70 16
    16 00 17 00 ee 03 ee 03 01 00 00 01 08 00 38 00 00 00 2a 00 00 00
    """))
}

@Test func parsesServerControlGrantedControl() throws {
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 28 02 f0 80 68 00 01 03 eb 70 1a
    1a 00 17 00 ea 03 ee 03 01 00 00 02 0c 00 14 00 00 00
    02 00 ee 03 ea 03 00 00
    """)))

    #expect(shareData.typeName == "control-granted-control")
    #expect(shareData.controlAction == 0x0002)
    #expect(shareData.payload == hexData("02 00 ee 03 ea 03 00 00"))
}

@Test func parsesServerFontMap() throws {
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 28 02 f0 80 68 00 01 03 eb 70 1a
    1a 00 17 00 ea 03 ee 03 01 00 00 01 0c 00 28 00 00 00
    00 00 00 00 03 00 04 00
    """)))

    #expect(shareData.typeName == "font-map")
    #expect(shareData.payload == hexData("00 00 00 00 03 00 04 00"))
}

@Test func finalizationTrackerCompletesOnlyOnFontMap() {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "server-synchronize")
    tracker.observe(typeName: "control-cooperate")
    tracker.observe(typeName: "control-granted-control")
    #expect(tracker.isComplete == false)
    tracker.observe(typeName: "font-map")
    #expect(tracker.isComplete == true)
}

@Test func finalizationTrackerAcceptsCooperateBeforeSynchronizeOrdering() {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "control-cooperate")
    tracker.observe(typeName: "server-synchronize")
    tracker.observe(typeName: "control-granted-control")
    tracker.observe(typeName: "font-map")

    #expect(tracker.receivedControlCooperate)
    #expect(tracker.receivedServerSynchronize)
    #expect(tracker.isComplete)
    #expect(tracker.observedTypeNames.prefix(2) == ["control-cooperate", "server-synchronize"])
}

@Test func finalizationTrackerIgnoresOptionalInterveningPDUs() {
    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(typeName: "save-session-info")
    tracker.observe(typeName: "monitor-layout")
    tracker.observe(typeName: "set-error-info")
    #expect(tracker.isComplete == false)
    #expect(RDPConnectionFinalizationTracker.isOptionalInterveningShareDataType("save-session-info"))
    #expect(RDPConnectionFinalizationTracker.isOptionalInterveningShareDataType("monitor-layout"))
    #expect(RDPConnectionFinalizationTracker.isConnectionFinalizationShareDataType("server-synchronize"))
    #expect(RDPConnectionFinalizationTracker.isConnectionFinalizationShareDataType("font-map"))
    tracker.observe(typeName: "server-synchronize")
    tracker.observe(typeName: "control-cooperate")
    tracker.observe(typeName: "font-map")
    #expect(tracker.isComplete)
}

@Test func finalizationTrackerObservesParsedShareDataPDUs() throws {
    let synchronize = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 24 02 f0 80 68 00 01 03 eb 70 16
    16 00 17 00 ea 03 ee 03 01 00 00 01 08 00 1f 00 00 00
    01 00 ea 03
    """)))
    let fontMap = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 28 02 f0 80 68 00 01 03 eb 70 1a
    1a 00 17 00 ea 03 ee 03 01 00 00 01 0c 00 28 00 00 00
    00 00 00 00 03 00 04 00
    """)))

    var tracker = RDPConnectionFinalizationTracker()
    tracker.observe(synchronize)
    #expect(tracker.isComplete == false)
    tracker.observe(fontMap)
    #expect(tracker.receivedServerSynchronize)
    #expect(tracker.receivedFontMap)
    #expect(tracker.isComplete)
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
