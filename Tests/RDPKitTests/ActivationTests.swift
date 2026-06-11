import Foundation
@testable import RDPKit
import Testing

@Test func parsesDemandActivePacket() throws {
    let demandActive = try #require(try RDPDemandActivePDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 3d 02 f0 80 68 00 05 03 eb 70 2f
    2f 00 11 00 ee 03 ee 03 01 00 04 00 19 00 52 44 50 00
    03 00 00 00 01 00 04 00 1c 00 0c 00 52 00 00 00 00 00 00 00 1d 00 05 00 00
    00 00 00 00
    """)))

    #expect(demandActive.channelID == 1003)
    #expect(demandActive.pduSource == 1006)
    #expect(demandActive.shareID == 0x0001_03EE)
    #expect(demandActive.sourceDescriptorText == "RDP\u{0}")
    #expect(demandActive.capabilitySets.count == 3)
    #expect(demandActive.capabilitySets.map(\.name).contains("surface-commands"))
    #expect(demandActive.capabilitySets.map(\.name).contains("bitmap-codecs"))
    #expect(demandActive.sessionID == 0)
}

@Test func confirmActiveUsesDemandShareAndAdvertisesGraphicsFriendlyCapabilities() {
    let confirmActive = RDPClientConfirmActivePDU(
        shareID: 0x0001_03EE,
        desktopWidth: 1440,
        desktopHeight: 900
    )
    let packet = confirmActive.encodedTPKT(userChannelID: 1006, ioChannelID: 1003)

    #expect(packet.prefix(31) == Data([
        0x03, 0x00, 0x00, 0xE6,
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x05, 0x03, 0xEB, 0x70, 0x80, 0xD7,
        0xD5, 0x00, 0x13, 0x00, 0xEE, 0x03,
        0xEE, 0x03, 0x01, 0x00,
        0xEA, 0x03, 0x09, 0x00, 0xBE, 0x00,
    ]))
    #expect(confirmActive.capabilitySets.map(\.name) == [
        "general",
        "bitmap",
        "input",
        "font",
        "virtual-channel",
        "multifragment-update",
        "large-pointer",
        "surface-commands",
    ])
    #expect(packet.containsSubsequence(Data([
        0x02, 0x00, 0x1C, 0x00,
        0x20, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00,
        0xA0, 0x05, 0x84, 0x03,
    ])))
}

@Test func parsesServerSynchronizeShareData() throws {
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 25 02 f0 80 68 00 05 03 eb 70 80 16 16 00 17 00 ee 03 ee 03 01
    00 00 01 04 00 1f 00 00 00 01 00 ee 03
    """)))

    #expect(shareData.channelID == 1003)
    #expect(shareData.shareID == 0x0001_03EE)
    #expect(shareData.pduSource == 1006)
    #expect(shareData.pduType2 == 0x1F)
    #expect(shareData.typeName == "server-synchronize")
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}
