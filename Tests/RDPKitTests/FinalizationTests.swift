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

@Test func finalizationTrackerCompletesOnlyOnFontMap() throws {
    var tracker = RDPConnectionFinalizationTracker()
    try tracker.observe(serverShareData(pduType2: 0x1F, payload: Data([0x01, 0x00, 0xEA, 0x03])))
    try tracker.observe(serverShareData(pduType2: 0x14, payload: controlPayload(action: 0x0004)))
    try tracker.observe(serverShareData(pduType2: 0x14, payload: controlPayload(action: 0x0002)))
    #expect(tracker.receivedServerSynchronize)
    #expect(tracker.receivedControlCooperate)
    #expect(tracker.receivedControlGranted)
    #expect(tracker.isComplete == false)
    try tracker.observe(serverShareData(pduType2: 0x28, payload: Data([0, 0, 0, 0, 3, 0, 4, 0])))
    #expect(tracker.isComplete == true)
}

@Test func finalizationTrackerIgnoresOptionalInterveningPDUs() throws {
    var tracker = RDPConnectionFinalizationTracker()
    try tracker.observe(serverShareData(pduType2: 0x2F, payload: Data([0x09, 0x00, 0x00, 0x00])))
    try tracker.observe(serverShareData(pduType2: 0x37, payload: Data([0, 0, 0, 0])))
    try tracker.observe(serverShareData(pduType2: 0x14, payload: controlPayload(action: 0x0001)))
    #expect(tracker == RDPConnectionFinalizationTracker())
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

private func serverShareData(pduType2: UInt8, payload: Data) throws -> RDPShareDataPDU {
    let userData = rdpShareDataPDUData(shareID: 0x0001_03EE, pduSource: 1006, pduType2: pduType2, payload: payload)
    var indication = Data([0x68, 0x00, 0x05, 0x03, 0xEB, 0x70])
    indication.appendPERLength(userData.count)
    indication.append(userData)
    return try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: X224DataTPDU.wrap(indication)))
}

private func controlPayload(action: UInt16) -> Data {
    RDPClientControlPDU(shareID: 0, action: action).encodedPDUData(userChannelID: 0).suffix(8)
}
