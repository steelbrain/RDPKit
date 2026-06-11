import Foundation
@testable import RDPKit
import Testing

@Test func clientSynchronizePDUUsesServerChannelTarget() {
    let packet = RDPClientSynchronizePDU(shareID: 0x0001_03EE)
        .encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet == hexData("""
    03 00 00 24 02 f0 80 64 00 05 03 eb 70 16
    16 00 17 00 ee 03 ee 03 01 00 00 01 08 00 1f 00 00 00 01 00 ea 03
    """))
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

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}
