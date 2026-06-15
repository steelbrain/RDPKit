import Foundation
@testable import RDPKit
import Testing

@Test func deviceRedirectionPDUParsesHeaderAndPayload() throws {
    let pdu = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
    ]))

    #expect(pdu.header.component == RDPDeviceRedirectionComponent.core)
    #expect(pdu.header.packetID == RDPDeviceRedirectionPacketID.serverAnnounce)
    #expect(pdu.payload == Data([0x01, 0x00]))
    #expect(pdu.typeName == "rdpdr-server-announce")
}

@Test func deviceRedirectionClientAnnounceReplyEchoesClientID() throws {
    let serverAnnounce = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
        0x0D, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    let announce = try #require(try RDPDeviceRedirectionVersionAndID.parse(from: serverAnnounce))

    #expect(announce.major == 1)
    #expect(announce.minor == 13)
    #expect(announce.clientID == 0x1234_5678)
    #expect(announce.clientAnnounceReplyEncoded().rdpHexString == """
    72 44 43 43 01 00 0c 00 78 56 34 12
    """)
}

@Test func deviceRedirectionClientNameEncodesUnicodeComputerName() {
    let encoded = RDPDeviceRedirectionClientNameRequest(computerName: "KRDPSWIFT").encoded()

    #expect(encoded.rdpHexString == """
    72 44 4e 43 01 00 00 00 00 00 00 00 14 00 00 00 \
    4b 00 52 00 44 00 50 00 53 00 57 00 49 00 46 00 54 00 00 00
    """)
}

@Test func deviceRedirectionClientCapabilitiesEncodeGeneralNoDeviceSet() {
    let encoded = RDPDeviceRedirectionClientCapabilities(
        minorVersion: RDPDeviceRedirectionVersion.minorRDP6
    ).encoded()

    #expect(encoded.rdpHexString == """
    72 44 50 43 01 00 00 00 01 00 2c 00 02 00 00 00 \
    00 00 00 00 00 00 00 00 01 00 0c 00 ff 3f 00 00 \
    00 00 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """)
}

@Test func deviceRedirectionEmptyDeviceListAnnounceEncodesZeroDevices() {
    #expect(RDPDeviceRedirectionDeviceListAnnounce().encoded().rdpHexString == """
    72 44 41 44 00 00 00 00
    """)
}
