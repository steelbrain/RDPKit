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

    #expect(packet.prefix(4) == Data([
        0x03, 0x00,
        UInt8(packet.count >> 8),
        UInt8(packet.count & 0xFF),
    ]))
    #expect(packet.containsSubsequence(Data([
        0xEE, 0x03, 0x01, 0x00,
        0xEA, 0x03, 0x09, 0x00,
    ])))
    #expect(confirmActive.capabilitySets.map(\.name) == [
        "general",
        "bitmap",
        "order",
        "bitmap-cache",
        "pointer",
        "input",
        "font",
        "brush",
        "glyph-cache",
        "offscreen-cache",
        "virtual-channel",
        "sound",
        "multifragment-update",
        "large-pointer",
        "surface-commands",
        "bitmap-codecs",
        "frame-acknowledge",
    ])
    #expect(packet.containsSubsequence(Data([
        0x02, 0x00, 0x1C, 0x00,
        0x20, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00,
        0xA0, 0x05, 0x84, 0x03,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x08, 0x00, 0x0A, 0x00,
        0x01, 0x00, 0x20, 0x00,
        0x20, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x01, 0x00, 0x18, 0x00,
        0x06, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x04, 0x04,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1A, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x80, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1B, 0x00, 0x06, 0x00,
        0x03, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1C, 0x00, 0x0C, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1D, 0x00, 0x5F, 0x00,
        0x02,
        0x12, 0x2F, 0x77, 0x76,
        0x72, 0xBD,
        0x63, 0x44,
        0xAF, 0xB3, 0xB7, 0x3C, 0x9C, 0x6F, 0x78, 0x86,
        0x03,
        0x31, 0x00,
        0x31, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x25, 0x00, 0x00, 0x00,
        0xC0, 0xCB,
        0x08, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0xC1, 0xCB,
        0x1D, 0x00, 0x00, 0x00,
        0x01,
        0xC0, 0xCF,
        0x02, 0x00,
        0x08, 0x00,
        0x00, 0x01,
        0x40, 0x00,
        0x00,
        0x01,
        0x01,
        0x01,
        0x00, 0x01,
        0x40, 0x00,
        0x02,
        0x01,
        0x01,
        0x04,
        0xB9, 0x1B, 0x8D, 0xCA,
        0x0F, 0x00,
        0x4F, 0x15,
        0x58, 0x9F, 0xAE, 0x2D, 0x1A, 0x87, 0xE2, 0xD6,
        0x01,
        0x03, 0x00,
        0x01,
        0x01,
        0x03,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1E, 0x00, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
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
