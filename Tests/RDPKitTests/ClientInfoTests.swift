import Foundation
@testable import RDPKit
import Testing

@Test func mcsSendDataRequestUsesShortPERLength() {
    let request = MCSSendDataRequestPDU(
        initiator: 1007,
        channelID: 1003,
        userData: Data(repeating: 0xAA, count: 0x1E)
    )

    #expect(request.encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x2C,
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x06, 0x03, 0xEB, 0x70, 0x1E,
    ] + Array(repeating: 0xAA, count: 0x1E)))
}

@Test func mcsSendDataRequestUsesTwoBytePERLength() {
    let request = MCSSendDataRequestPDU(
        initiator: 1005,
        channelID: 1003,
        userData: Data(repeating: 0xBB, count: 0x019C)
    )
    let packet = request.encodedTPKT()

    #expect(Data(packet.prefix(15)) == Data([
        0x03, 0x00, 0x01, 0xAB,
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x04, 0x03, 0xEB, 0x70, 0x81, 0x9C,
    ]))
}

@Test func clientInfoEncodesCredentialsInsideSecurityHeader() throws {
    let credentials = RDPCredentials(username: "rdp-user", domain: "LAB", password: "secret")
    let clientInfo = RDPClientInfoPDU(credentials: credentials)
    let pduData = try clientInfo.encodedPDUData()

    #expect(Data(pduData.prefix(22)) == Data([
        0x40, 0x00, 0x00, 0x00,
        0x09, 0x04, 0x00, 0x00,
        0x5B, 0x41, 0x0A, 0x00,
        0x06, 0x00,
        0x10, 0x00,
        0x0C, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ]))
    #expect(pduData.range(of: utf16LENullTerminated("LAB")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("rdp-user")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("secret")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("0.0.0.0")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("KRDPSwift")) != nil)
}

@Test func clientInfoTPKTUsesUserChannelAsInitiatorAndIOChannelAsTarget() throws {
    let credentials = RDPCredentials(username: "rdp-user", domain: nil, password: "secret")
    let packet = try RDPClientInfoPDU(credentials: credentials)
        .encodedTPKT(userChannelID: 1005, ioChannelID: 1003)

    let declaredLength = Int(packet[2]) << 8 | Int(packet[3])
    #expect(packet.count == declaredLength)
    #expect(Data(packet.dropFirst(4).prefix(9)) == Data([
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x04, 0x03, 0xEB, 0x70,
    ]))
}

@Test func clientInfoWithoutCredentialsDoesNotSetAutologon() throws {
    let pduData = try RDPClientInfoPDU(credentials: nil).encodedPDUData()
    let flags = UInt32(pduData[8])
        | UInt32(pduData[9]) << 8
        | UInt32(pduData[10]) << 16
        | UInt32(pduData[11]) << 24

    #expect(flags == 0x000A_4153)
}

@Test func clientInfoUsesBasicSecurityHeaderForEnhancedSecurity() throws {
    let pduData = try RDPClientInfoPDU(credentials: nil).encodedPDUData()
    let securityFlags = littleEndianUInt16(in: pduData, at: 0)

    #expect(securityFlags & 0x0040 != 0)
    #expect(securityFlags & 0x0008 == 0)
    #expect(littleEndianUInt16(in: pduData, at: 2) == 0)
}

@Test func clientInfoDoesNotAdvertiseBulkCompressionWithoutDecoderSupport() throws {
    let pduData = try RDPClientInfoPDU(credentials: nil).encodedPDUData()
    let flags = UInt32(pduData[8])
        | UInt32(pduData[9]) << 8
        | UInt32(pduData[10]) << 16
        | UInt32(pduData[11]) << 24

    #expect(flags & 0x0000_0080 == 0)
    #expect(flags & 0x0000_1E00 == 0)
}

@Test func clientInfoDoesNotSetReservedInfoPacketFlags() throws {
    let pduData = try RDPClientInfoPDU(credentials: nil).encodedPDUData()
    let flags = UInt32(pduData[8])
        | UInt32(pduData[9]) << 8
        | UInt32(pduData[10]) << 16
        | UInt32(pduData[11]) << 24

    #expect(flags & 0x0080_0000 == 0)
    #expect(flags & 0xF000_0000 == 0)
}

@Test func clientInfoAllowsAudioPlaybackWhenRequested() throws {
    let pduData = try RDPClientInfoPDU(
        credentials: nil,
        audioPlaybackEnabled: true
    ).encodedPDUData()
    let flags = UInt32(pduData[8])
        | UInt32(pduData[9]) << 8
        | UInt32(pduData[10]) << 16
        | UInt32(pduData[11]) << 24

    #expect(flags == 0x0002_4153)
}

@Test func clientInfoUsesIPv6AddressFamilyForIPv6ClientAddress() throws {
    let pduData = try RDPClientInfoPDU(
        credentials: nil,
        clientAddress: "2001:db8::7"
    ).encodedPDUData()
    let extendedInfoOffset = try clientInfoExtendedInfoOffset(in: pduData)

    #expect(littleEndianUInt16(in: pduData, at: extendedInfoOffset) == 0x0017)
    #expect(pduData.range(of: utf16LENullTerminated("2001:db8::7")) != nil)
}

@Test func clientInfoIncludesCanonicalExtendedInfoTail() throws {
    let pduData = try RDPClientInfoPDU(credentials: nil).encodedPDUData()
    let tailOffset = try clientInfoExtendedTailOffset(in: pduData)

    // MS-RDPBCGR 2.2.1.11.1.1.1 Extended Info: clientTimeZone (172) +
    // clientSessionId (4) + performanceFlags (4) + cbAutoReconnectCookie (2).
    #expect(Data(pduData[tailOffset ..< tailOffset + 172]) == Data(repeating: 0, count: 172))
    #expect(littleEndianUInt32(in: pduData, at: tailOffset + 172) == 0)
    #expect(littleEndianUInt32(in: pduData, at: tailOffset + 176) == 0)
    #expect(littleEndianUInt16(in: pduData, at: tailOffset + 180) == 0)
    #expect(pduData.count == tailOffset + 182)
}

@Test func clientInfoAcceptsMaximumLengthIPv6Address() throws {
    let address = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
    let pduData = try RDPClientInfoPDU(
        credentials: nil,
        clientAddress: address
    ).encodedPDUData()
    let extendedInfoOffset = try clientInfoExtendedInfoOffset(in: pduData)

    #expect(littleEndianUInt16(in: pduData, at: extendedInfoOffset) == 0x0017)
    #expect(littleEndianUInt16(in: pduData, at: extendedInfoOffset + 2) == 80)
    #expect(pduData.range(of: utf16LENullTerminated(address)) != nil)
}

@Test func clientInfoAcceptsMaximumLengthStandardUnicodeFields() throws {
    let domain = String(repeating: "d", count: 255)
    let username = String(repeating: "u", count: 255)
    let clientDirectory = String(repeating: "c", count: 255)
    let pduData = try RDPClientInfoPDU(
        credentials: RDPCredentials(username: username, domain: domain, password: ""),
        clientDirectory: clientDirectory
    ).encodedPDUData()

    #expect(pduData.range(of: utf16LENullTerminated(domain)) != nil)
    #expect(pduData.range(of: utf16LENullTerminated(username)) != nil)
    #expect(pduData.range(of: utf16LENullTerminated(clientDirectory)) != nil)
}

@Test func clientInfoRejectsOverlongUnicodeFields() {
    let password = String(repeating: "x", count: 256)
    let credentials = RDPCredentials(username: "rdp-user", domain: nil, password: password)

    #expect(throws: RDPClientInfoEncodingError.fieldTooLong(
        name: "password",
        maxBytesIncludingNull: 512,
        actualBytesIncludingNull: 514
    )) {
        try RDPClientInfoPDU(credentials: credentials).encodedPDUData()
    }
}

@Test func clientInfoRejectsOverlongClientAddress() {
    #expect(throws: RDPClientInfoEncodingError.fieldTooLong(
        name: "clientAddress",
        maxBytesIncludingNull: 80,
        actualBytesIncludingNull: 82
    )) {
        try RDPClientInfoPDU(
            credentials: nil,
            clientAddress: String(repeating: "x", count: 40)
        ).encodedPDUData()
    }
}

@Test func clientInfoRejectsOverlongClientDirectory() {
    #expect(throws: RDPClientInfoEncodingError.fieldTooLong(
        name: "clientDirectory",
        maxBytesIncludingNull: 512,
        actualBytesIncludingNull: 514
    )) {
        try RDPClientInfoPDU(
            credentials: nil,
            clientDirectory: String(repeating: "x", count: 256)
        ).encodedPDUData()
    }
}

private func utf16LENullTerminated(_ value: String) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.appendLittleEndianUInt16(0)
    return data
}

private func clientInfoExtendedInfoOffset(in pduData: Data) throws -> Int {
    var offset = 22
    for lengthOffset in stride(from: 12, through: 20, by: 2) {
        offset += Int(littleEndianUInt16(in: pduData, at: lengthOffset)) + 2
    }
    return offset
}

private func clientInfoExtendedTailOffset(in pduData: Data) throws -> Int {
    let extendedInfoOffset = try clientInfoExtendedInfoOffset(in: pduData)
    let clientAddressLength = Int(littleEndianUInt16(in: pduData, at: extendedInfoOffset + 2))
    let clientDirectoryLengthOffset = extendedInfoOffset + 4 + clientAddressLength
    let clientDirectoryLength = Int(littleEndianUInt16(in: pduData, at: clientDirectoryLengthOffset))
    return clientDirectoryLengthOffset + 2 + clientDirectoryLength
}

private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}
