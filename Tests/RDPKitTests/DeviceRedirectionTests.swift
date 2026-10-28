import Foundation
import NIOCore
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

@Test func deviceRedirectionClientAnnounceReplyEchoesClientID() throws {
    let serverAnnounce = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44,
        0x6E, 0x49,
        0x01, 0x00,
        0x0D, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    let announce = try #require(try RDPDeviceRedirectionVersionAndID.parse(from: serverAnnounce))
    let clientID = announce.clientIDForReply { 0xAABB_CCDD }

    #expect(announce.major == 1)
    #expect(announce.minor == 13)
    #expect(clientID == 0x1234_5678)
    #expect(announce.clientAnnounceReplyEncoded(clientID: clientID).rdpHexString == """
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

    #expect(announce.clientIDForReply { 0xAABB_CCDD } == 0xAABB_CCDD)
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

@Test func deviceRedirectionEmptyDeviceListAnnounceEncodesZeroDevices() {
    #expect(RDPDeviceRedirectionDeviceListAnnounce().encoded().rdpHexString == """
    72 44 41 44 00 00 00 00
    """)
}

@Test func deviceRedirectionSessionFollowsInitializationSequence() throws {
    let (channel, session) = try connectedDeviceRedirectionSession()
    let packets: [[UInt8]] = [
        [0x72, 0x44, 0x6E, 0x49, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x50, 0x53],
        [0x72, 0x44, 0x43, 0x43, 0x01, 0x00, 0x0C, 0x00, 0x78, 0x56, 0x34, 0x12],
        [0x72, 0x44, 0x4C, 0x55],
    ]

    for packet in packets {
        try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
    }

    #expect(try sentDeviceRedirectionTypeNames(channel) == [
        "rdpdr-client-id-confirm",
        "rdpdr-client-name",
        "rdpdr-client-capability",
        "rdpdr-device-list-announce",
        "rdpdr-device-list-announce",
    ])
}

@Test func deviceRedirectionSessionAnswersServerCapabilitiesWithoutValidatingThem() throws {
    let (channel, session) = try connectedDeviceRedirectionSession()
    let capabilityRequests: [[UInt8]] = [
        [0x72, 0x44, 0x50, 0x53],
        [
            0x72, 0x44, 0x50, 0x53, 0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x2C, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x0D, 0x00, 0xFF, 0xFF, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x99, 0x00, 0x08, 0x00, 0x07, 0x00, 0x00, 0x00,
        ],
    ]

    for request in capabilityRequests {
        try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(request)))
    }

    #expect(try sentDeviceRedirectionTypeNames(channel) == [
        "rdpdr-client-capability",
        "rdpdr-client-capability",
    ])
}

@Test func deviceRedirectionSessionIgnoresUnknownPackets() throws {
    let (channel, session) = try connectedDeviceRedirectionSession()
    let packets: [[UInt8]] = [
        [0xFF, 0xFF, 0x6E, 0x49],
        [0x72, 0x44, 0xFF, 0xFF],
        [0x52, 0x50, 0x43, 0x50],
    ]

    for packet in packets {
        try session.receive(RDPDeviceRedirectionPDU.parse(from: Data(packet)))
    }

    #expect(try sentDeviceRedirectionTypeNames(channel).isEmpty)
}

@Test func deviceRedirectionSessionValidatesConfirmedClientID() throws {
    let (channel, session) = try connectedDeviceRedirectionSession()
    try session.receive(RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x6E, 0x49,
        0x01, 0x00, 0x0C, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ])))

    let mismatchedConfirm = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x43, 0x43,
        0x01, 0x00, 0x0C, 0x00,
        0x79, 0x56, 0x34, 0x12,
    ]))
    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try session.receive(mismatchedConfirm)
    }
    #expect(try sentDeviceRedirectionTypeNames(channel) == [
        "rdpdr-client-id-confirm",
        "rdpdr-client-name",
    ])
}

@Test func deviceRedirectionSessionRejectsMalformedUserLoggedOnPDU() throws {
    let (_, session) = try connectedDeviceRedirectionSession()
    let malformed = try RDPDeviceRedirectionPDU.parse(from: Data([
        0x72, 0x44, 0x4C, 0x55, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidStaticVirtualChannelPDU) {
        try session.receive(malformed)
    }
}

private func connectedDeviceRedirectionSession() throws -> (EmbeddedChannel, RDPDeviceRedirectionSession) {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPDeviceRedirectionSession(
        userChannelID: 1006,
        staticChannelID: 1004,
        channel: channel,
        computerName: "RDPKIT"
    )
    return (channel, session)
}

private func sentDeviceRedirectionTypeNames(_ channel: EmbeddedChannel) throws -> [String] {
    channel.embeddedEventLoop.run()
    var typeNames: [String] = []
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(Data(buffer.readBytes(length: buffer.readableBytes) ?? [])))
        _ = try cursor.readData(count: 6)
        let userData = try cursor.readData(count: cursor.readPERLength())
        let staticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: userData)
        try typeNames.append(RDPDeviceRedirectionPDU.parse(from: staticPDU.payload).typeName)
    }
    return typeNames
}
