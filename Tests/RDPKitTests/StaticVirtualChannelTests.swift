import Foundation
@testable import RDPKit
import Testing

@Test func staticVirtualChannelWrapsSinglePayloadWithChannelHeader() {
    let pdu = RDPStaticVirtualChannelPDU(payload: Data([0x50, 0x00, 0x02, 0x00]))

    #expect(pdu.encodedUserData().rdpHexString == "04 00 00 00 03 00 00 00 50 00 02 00")
    #expect(pdu.isComplete)
}

@Test func staticVirtualChannelCanRequestShowProtocolFraming() {
    let pdu = RDPStaticVirtualChannelPDU(
        payload: Data([0x07, 0x00, 0x00, 0x00]),
        flags: RDPStaticVirtualChannelFlags.first
            | RDPStaticVirtualChannelFlags.last
            | RDPStaticVirtualChannelFlags.showProtocol
    )

    #expect(pdu.encodedUserData().rdpHexString == "04 00 00 00 13 00 00 00 07 00 00 00")
    #expect(pdu.isComplete)
}

@Test func staticVirtualChannelParsesFromMCSDataIndication() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x1A,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x06, 0x03, 0xEC, 0x70, 0x0C,
        0x04, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0x50, 0x00, 0x02, 0x00,
    ])

    let pdu = try #require(try RDPStaticVirtualChannelPDU.parseIfPresent(
        fromTPKT: packet,
        channelID: 1004
    ))

    #expect(pdu.totalLength == 4)
    #expect(pdu.flags == 0x0000_0003)
    #expect(pdu.payload == Data([0x50, 0x00, 0x02, 0x00]))
    #expect(pdu.isComplete)
}
