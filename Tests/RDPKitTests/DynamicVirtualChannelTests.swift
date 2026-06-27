import Foundation
@testable import RDPKit
import Testing

@Test func parsesDynamicVirtualChannelCapabilitiesRequest() throws {
    let request = try #require(try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
        from: Data([0x50, 0x00, 0x03, 0x00])
    ))

    #expect(request.version == 3)
    #expect(request.priorityChargeData.isEmpty)
    #expect(request.typeName == "dynvc-capabilities-request")
}

@Test func parsesDynamicVirtualChannelCompressedCommandHeader() throws {
    let header = try RDPDynamicVirtualChannelHeader(byte: 0x71)

    #expect(header.channelIDLength == 1)
    #expect(header.sp == 0)
    #expect(header.command == .dataCompressed)
    #expect(header.command.typeName == "dynvc-data-compressed")
}

@Test func encodesDynamicVirtualChannelCapabilitiesResponse() {
    let response = RDPDynamicVirtualChannelCapabilitiesResponse(version: 2)

    #expect(response.encoded().rdpHexString == "50 00 02 00")
}

@Test func parsesDynamicVirtualChannelCreateRequest() throws {
    let name = Array(RDPGFXChannel.name.utf8)
    let payload = Data([0x14, 0x07] + name + [0x00])

    let request = try #require(try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: payload))

    #expect(request.channelID == 7)
    #expect(request.priority == 1)
    #expect(request.channelName == RDPGFXChannel.name)
    #expect(request.typeName == "dynvc-create-request")
}

@Test func encodesDynamicVirtualChannelCreateResponse() {
    let response = RDPDynamicVirtualChannelCreateResponse(channelID: 300)

    #expect(response.encoded().rdpHexString == "11 2c 01 00 00 00 00")
}

@Test func encodesDynamicVirtualChannelDataPDU() {
    let pdu = RDPDynamicVirtualChannelDataPDU(
        channelID: 7,
        payload: Data([0x12, 0x00])
    )

    #expect(pdu.encoded().rdpHexString == "30 07 12 00")
}

@Test func parsesDynamicVirtualChannelDataFirstPDU() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
        from: Data([0x24, 0x01, 0x40, 0x06, 0xE0, 0x04])
    ))

    #expect(pdu.channelID == 1)
    #expect(pdu.totalLength == 1600)
    #expect(pdu.payload == Data([0xE0, 0x04]))
}

@Test func parsesDynamicVirtualChannelDataPDU() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(
        from: Data([0x31, 0x2C, 0x01, 0x12, 0x00])
    ))

    #expect(pdu.channelID == 300)
    #expect(pdu.payload == Data([0x12, 0x00]))
}
