import Foundation
import NIOEmbedded
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

@Test func deviceRedirectionPDURejectsInvalidSharedHeaderValues() {
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        _ = try RDPDeviceRedirectionPDU.parse(from: Data([
            0xFF, 0xFF,
            0x6E, 0x49,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        _ = try RDPDeviceRedirectionPDU.parse(from: Data([
            0x72, 0x44,
            0xFF, 0xFF,
        ]))
    }
}

@Test func deviceRedirectionPDUValidatesPacketIDsAgainstComponent() throws {
    let printerPacket = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x52, 0x50,
        0x43, 0x50,
    ]))

    #expect(printerPacket.header.component == RDPDeviceRedirectionComponent.printer)
    #expect(printerPacket.header.packetID == RDPDeviceRedirectionPacketID.printerCacheData)

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        _ = try RDPDeviceRedirectionPDU.parse(from: Data([
            0x52, 0x50,
            0x6E, 0x49,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        _ = try RDPDeviceRedirectionPDU.parse(from: Data([
            0x72, 0x44,
            0x43, 0x50,
        ]))
    }
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

@Test func deviceRedirectionVersionAndIDRejectsMalformedPackets() throws {
    let trailingData = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
        0x0C, 0x00,
        0x78, 0x56, 0x34, 0x12,
        0x00,
    ]))
    let invalidMajor = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x02, 0x00,
        0x0C, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    let invalidMinor = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
        0x03, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPDeviceRedirectionVersionAndID.parse(from: trailingData)
    }
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPDeviceRedirectionVersionAndID.parse(from: invalidMajor)
    }
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try RDPDeviceRedirectionVersionAndID.parse(from: invalidMinor)
    }
}

@Test func deviceRedirectionClientAnnounceReplyGeneratesClientIDForLegacyServers() throws {
    let serverAnnounce = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
        0x05, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    let announce = try #require(try RDPDeviceRedirectionVersionAndID.parse(from: serverAnnounce))

    #expect(announce.clientAnnounceReplyEncoded(clientIDGenerator: { 0xAABB_CCDD }).rdpHexString == """
    72 44 43 43 01 00 0c 00 dd cc bb aa
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
    00 00 00 00 00 00 00 00 01 00 0c 00 ff ff 00 00 \
    00 00 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """)
}

@Test func deviceRedirectionServerCapabilitiesParseSpecExample() throws {
    let pdu = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x50, 0x53, 0x05, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x2C, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x0C, 0x00, 0xFF, 0xFF, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
    ]))

    let capabilities = try #require(try RDPDeviceRedirectionServerCapabilities.parse(from: pdu))

    #expect(capabilities.capabilities == [
        .init(type: 0x0001, version: 2),
        .init(type: 0x0002, version: 1),
        .init(type: 0x0003, version: 1),
        .init(type: 0x0004, version: 2),
        .init(type: 0x0005, version: 1),
    ])
}

@Test func deviceRedirectionServerCapabilitiesAcceptEmptyPayload() throws {
    let pdu = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x50, 0x53,
    ]))

    let capabilities = try #require(try RDPDeviceRedirectionServerCapabilities.parse(from: pdu))

    #expect(capabilities.capabilities.isEmpty)
}

@Test func deviceRedirectionServerCapabilitiesRejectMalformedPayloads() throws {
    let unknownCapability = try serverCapabilityPDU(payload: Data([
        0x01, 0x00, 0x00, 0x00,
        0x99, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ]))
    let countMismatch = try serverCapabilityPDU(payload: Data([
        0x00, 0x00, 0x00, 0x00,
        0x00,
    ]))
    let shortCapability = try serverCapabilityPDU(payload: Data([
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x07, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ]))
    let invalidGeneralVersion = try serverCapabilityPDU(payload: generalCapabilityPayload(version: 3))
    let invalidGeneralMinor = try serverCapabilityPDU(payload: generalCapabilityPayload(minorVersion: 3))
    let invalidReservedIOCode2 = try serverCapabilityPDU(payload: generalCapabilityPayload(ioCode2: 1))
    let invalidReservedExtraFlags2 = try serverCapabilityPDU(payload: generalCapabilityPayload(extraFlags2: 1))

    for pdu in [
        unknownCapability,
        countMismatch,
        shortCapability,
        invalidGeneralVersion,
        invalidGeneralMinor,
        invalidReservedIOCode2,
        invalidReservedExtraFlags2,
    ] {
        #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
            _ = try RDPDeviceRedirectionServerCapabilities.parse(from: pdu)
        }
    }
}

@Test func deviceRedirectionEmptyDeviceListAnnounceEncodesZeroDevices() {
    #expect(RDPDeviceRedirectionDeviceListAnnounce().encoded().rdpHexString == """
    72 44 41 44 00 00 00 00
    """)
}

@Test func deviceRedirectionSessionValidatesConfirmedClientID() throws {
    let channel = EmbeddedChannel()
    let session = RDPDeviceRedirectionSession(
        userChannelID: 1006,
        staticChannelID: 1004,
        channel: channel,
        computerName: "RDPKIT"
    )
    let announce = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x6E, 0x49,
        0x01, 0x00, 0x0C, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    try session.receive(announce)

    let mismatchedConfirm = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x43, 0x43,
        0x01, 0x00, 0x0C, 0x00,
        0x79, 0x56, 0x34, 0x12,
    ]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try session.receive(mismatchedConfirm)
    }

    let matchingConfirm = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x43, 0x43,
        0x01, 0x00, 0x0C, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    try session.receive(matchingConfirm)
    _ = try channel.finish()
}

@Test func deviceRedirectionSessionRejectsMalformedUserLoggedOnPDU() throws {
    let channel = EmbeddedChannel()
    let session = RDPDeviceRedirectionSession(
        userChannelID: 1006,
        staticChannelID: 1004,
        channel: channel,
        computerName: "RDPKIT"
    )
    let malformed = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x4C, 0x55, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try session.receive(malformed)
    }
    _ = try channel.finish()
}

private func serverCapabilityPDU(payload: Data) throws -> RDPDeviceRedirectionPDU {
    try RDPDeviceRedirectionPDU.parse(from: RDPDeviceRedirectionPDU(
        header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.serverCapability),
        payload: payload
    ).encoded())
}

private func generalCapabilityPayload(
    version: UInt32 = 2,
    minorVersion: UInt16 = RDPDeviceRedirectionVersion.minorRDP6,
    ioCode2: UInt32 = 0,
    extraFlags2: UInt32 = 0
) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt16(0x0001)
    data.appendLittleEndianUInt16(44)
    data.appendLittleEndianUInt32(version)
    data.appendLittleEndianUInt32(0)
    data.appendLittleEndianUInt32(0)
    data.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
    data.appendLittleEndianUInt16(minorVersion)
    data.appendLittleEndianUInt32(0x0000_FFFF)
    data.appendLittleEndianUInt32(ioCode2)
    data.appendLittleEndianUInt32(0x0000_0007)
    data.appendLittleEndianUInt32(0)
    data.appendLittleEndianUInt32(extraFlags2)
    data.appendLittleEndianUInt32(0)
    return data
}
