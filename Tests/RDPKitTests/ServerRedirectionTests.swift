import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerRedirectionWithLoadBalanceCookie() throws {
    let cookie = Data("Cookie: mststs=1183689379\r\n".utf8)
    let username = utf16LE("rdp-user")
    let netbios = utf16LE("ANEES-MSI-LAPTOP")
    var userData = Data()
    let redirectionLength = UInt16(12 + 4 + cookie.count + 4 + username.count + 4 + netbios.count)
    let totalLength = UInt16(8 + Int(redirectionLength))
    userData.appendLittleEndianUInt16(totalLength)
    userData.appendLittleEndianUInt16(0x000A)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(0x0400)
    userData.appendLittleEndianUInt16(redirectionLength)
    userData.appendLittleEndianUInt32(4)
    userData.appendLittleEndianUInt32(
        RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
            | RDPServerRedirectionPDU.Flags.username.rawValue
            | RDPServerRedirectionPDU.Flags.targetNetBIOSName.rawValue
    )
    userData.appendLittleEndianUInt32(UInt32(cookie.count))
    userData.append(cookie)
    userData.appendLittleEndianUInt32(UInt32(username.count))
    userData.append(username)
    userData.appendLittleEndianUInt32(UInt32(netbios.count))
    userData.append(netbios)

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    )))

    #expect(pdu.channelID == 1003)
    #expect(pdu.redirectionPacketFlags == 0x0400)
    #expect(pdu.redirectionLength == redirectionLength)
    #expect(pdu.sessionID == 4)
    #expect(pdu.flags.contains(.loadBalanceInfo))
    #expect(pdu.routingToken == cookie)
    #expect(pdu.username == "rdp-user")
    #expect(pdu.targetNetBIOSName == "ANEES-MSI-LAPTOP")
    #expect(pdu.targetHost == "ANEES-MSI-LAPTOP")
}

@Test func parsesServerRedirectionTargetAndCredentialFields() throws {
    let netAddress = utf16LE("192.0.2.10")
    let username = utf16LE("rdp-user")
    let domain = utf16LE("WORKGROUP")
    let password = utf16LE("hunter2")
    let fqdn = utf16LE("desktop.example.test")

    var fields = Data()
    fields.append(lengthPrefixed(netAddress))
    fields.append(lengthPrefixed(username))
    fields.append(lengthPrefixed(domain))
    fields.append(lengthPrefixed(password))
    fields.append(lengthPrefixed(fqdn))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.targetNetAddress.rawValue
            | RDPServerRedirectionPDU.Flags.username.rawValue
            | RDPServerRedirectionPDU.Flags.domain.rawValue
            | RDPServerRedirectionPDU.Flags.password.rawValue
            | RDPServerRedirectionPDU.Flags.targetFQDN.rawValue,
        fields: fields
    )))

    #expect(pdu.targetNetAddress == "192.0.2.10")
    #expect(pdu.username == "rdp-user")
    #expect(pdu.domain == "WORKGROUP")
    #expect(pdu.password == "hunter2")
    #expect(pdu.targetFQDN == "desktop.example.test")
    // targetHost prefers the FQDN over the raw net address.
    #expect(pdu.targetHost == "desktop.example.test")
}

@Test func doesNotUseLoadBalanceInfoAsRoutingTokenWhenTargetAddressIsPresent() throws {
    let cookie = Data("Cookie: mststs=load-balanced\r\n".utf8)
    let netAddress = utf16LE("192.0.2.10")
    var fields = Data()
    fields.append(lengthPrefixed(netAddress))
    fields.append(lengthPrefixed(cookie))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.targetNetAddress.rawValue
            | RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        fields: fields
    )))

    #expect(pdu.loadBalanceInfo == cookie)
    #expect(pdu.routingToken == nil)
    #expect(pdu.targetHost == "192.0.2.10")
}

@Test func parsesServerRedirectionTargetNetAddresses() throws {
    let netAddress = utf16LE("2001:db8::1")
    let netbios = utf16LE("RDSHOST")
    var fields = Data()
    fields.append(lengthPrefixed(netAddress))
    fields.append(lengthPrefixed(netbios))
    fields.append(lengthPrefixed(targetNetAddresses([
        utf16LE("2001:db8::1"),
        utf16LE("192.0.2.10"),
    ])))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.targetNetAddress.rawValue
            | RDPServerRedirectionPDU.Flags.targetNetBIOSName.rawValue
            | RDPServerRedirectionPDU.Flags.targetNetAddresses.rawValue,
        fields: fields
    )))

    #expect(pdu.targetNetAddress == "2001:db8::1")
    #expect(pdu.targetNetBIOSName == "RDSHOST")
    #expect(pdu.targetNetAddresses == ["2001:db8::1", "192.0.2.10"])
    #expect(pdu.targetHost == "2001:db8::1")
}

@Test func parsesServerRedirectionTargetNetAddressesAfterRDSTLSFields() throws {
    let tsvURL = utf16LE("tsv://collection")
    let guid = Data("UkRQS2l0LXJlZGlyZWN0LWd1aWQ=".utf8)
    let certificate = Data("UkRQS2l0LWNlcnQ=".utf8)
    var fields = Data()
    fields.append(lengthPrefixed(tsvURL))
    fields.append(lengthPrefixed(guid))
    fields.append(lengthPrefixed(certificate))
    fields.append(lengthPrefixed(targetNetAddresses([
        utf16LE("2001:db8::1"),
        utf16LE("192.0.2.10"),
    ])))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.tsvURL.rawValue
            | RDPServerRedirectionPDU.Flags.redirectionGuid.rawValue
            | RDPServerRedirectionPDU.Flags.targetCertificate.rawValue
            | RDPServerRedirectionPDU.Flags.targetNetAddresses.rawValue,
        fields: fields
    )))

    #expect(pdu.tsvURL == "tsv://collection")
    #expect(pdu.redirectionGuid == guid)
    #expect(pdu.targetCertificate == certificate)
    #expect(pdu.targetNetAddresses == ["2001:db8::1", "192.0.2.10"])
    #expect(pdu.targetHost == "2001:db8::1")
}

@Test func parsesEnhancedServerRedirectionWithFullWidthSessionID() throws {
    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        sessionID: 0x1234_5678,
        flags: RDPServerRedirectionPDU.Flags.targetFQDN.rawValue,
        fields: lengthPrefixed(utf16LE("desktop.example.test"))
    )))

    #expect(pdu.pduSource == 0)
    #expect(pdu.redirectionPacketFlags == 0x0400)
    #expect(pdu.sessionID == 0x1234_5678)
    #expect(pdu.targetFQDN == "desktop.example.test")
}

@Test func parsesGnomeEnhancedRedirectionWithVersionOneShareHeader() throws {
    var packet = redirectionUserData(
        sessionID: 4,
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        fields: lengthPrefixed(Data("Cookie: mststs=load-balanced\r\n".utf8))
    )
    packet.replaceSubrange(2 ..< 4, with: Data([0x1A, 0x00]))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: packet
    )))

    // MS-RDPBCGR specifies PDUVersion zero for this PDU, but
    // gnome-remote-desktop has been observed sending the Share Control version
    // one nibble. Keep following the routing token when the packet body is
    // otherwise valid.
    #expect(pdu.routingToken == Data("Cookie: mststs=load-balanced\r\n".utf8))
}

@Test func parsesGnomeRedirectionWithOverstatedEmbeddedLength() throws {
    let cookie = Data("Cookie: mststs=load-balanced\r\n".utf8)
    var packet = redirectionUserData(
        sessionID: 4,
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        fields: lengthPrefixed(cookie)
    )
    let overstatedLength = UInt16(Int(packet[10]) | Int(packet[11]) << 8) + 2
    packet.replaceSubrange(10 ..< 12, with: Data([
        UInt8(overstatedLength & 0x00FF),
        UInt8(overstatedLength >> 8),
    ]))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: packet
    )))

    #expect(pdu.redirectionLength == overstatedLength)
    #expect(pdu.routingToken == cookie)
}

@Test func rejectsServerRedirectionWithUnderstatedEmbeddedLength() throws {
    var packet = redirectionUserData(
        sessionID: 4,
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        fields: lengthPrefixed(Data("Cookie: mststs=load-balanced\r\n".utf8))
    )
    let understatedLength = UInt16(Int(packet[10]) | Int(packet[11]) << 8) - 2
    packet.replaceSubrange(10 ..< 12, with: Data([
        UInt8(understatedLength & 0x00FF),
        UInt8(understatedLength >> 8),
    ]))

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: packet
        ))
    }
}

@Test func rejectsEnhancedServerRedirectionWithUnexpectedShareVersion() throws {
    var packet = redirectionUserData(
        sessionID: 4,
        flags: 0,
        fields: Data()
    )
    packet.replaceSubrange(2 ..< 4, with: Data([0x2A, 0x00]))

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: packet
        ))
    }
}

@Test func rejectsServerRedirectionWithoutRedirectionPacketMarker() throws {
    var packet = redirectionUserData(
        sessionID: 4,
        flags: 0,
        fields: Data()
    )
    packet.replaceSubrange(8 ..< 10, with: Data([0x00, 0x00]))

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: packet
        ))
    }
}

@Test func parsesLengthPrefixedRedirectionGuidAndCertificate() throws {
    let cookie = Data("Cookie: mststs=42\r\n".utf8)
    let guid = Data((0 ..< 16).map { UInt8($0) })
    let certificate = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])

    var fields = Data()
    fields.append(lengthPrefixed(cookie))
    fields.append(lengthPrefixed(guid))
    fields.append(lengthPrefixed(certificate))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
            | RDPServerRedirectionPDU.Flags.redirectionGuid.rawValue
            | RDPServerRedirectionPDU.Flags.targetCertificate.rawValue,
        fields: fields
    )))

    // The GUID is length-prefixed on the wire; parsing it as a fixed 16 bytes
    // would misalign and corrupt the certificate that follows.
    #expect(pdu.routingToken == cookie)
    #expect(pdu.redirectionGuid == guid)
    #expect(pdu.targetCertificate == certificate)
}

@Test func parsesGnomeStyleRedirectionWithModifierFlags() throws {
    // Mirrors the flag set sent by gnome-remote-desktop on its load-balancing
    // redirection: a routing token plus credentials, with the PK-encrypted,
    // redirection-GUID, and target-certificate flags. These occupy the high
    // bits (0x4000/0x8000/0x10000); a wrong bit assignment makes them read as
    // unknown flags, dropping the routing token so the redirect is not followed.
    let cookie = Data("Cookie: msts=lb\r\n".utf8)
    let username = utf16LE("rdp-user")
    let encryptedPassword = Data([0x30, 0x82, 0x01, 0x0A, 0x00, 0xFF])
    let guid = Data((0 ..< 16).map { UInt8($0) })
    let certificate = Data([0x01, 0x02, 0x03, 0x04])

    let flags = RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
        | RDPServerRedirectionPDU.Flags.username.rawValue
        | RDPServerRedirectionPDU.Flags.password.rawValue
        | RDPServerRedirectionPDU.Flags.passwordIsPKEncrypted.rawValue
        | RDPServerRedirectionPDU.Flags.redirectionGuid.rawValue
        | RDPServerRedirectionPDU.Flags.targetCertificate.rawValue
    #expect(flags == 0x0001_C016)

    var fields = Data()
    fields.append(lengthPrefixed(cookie))
    fields.append(lengthPrefixed(username))
    fields.append(lengthPrefixed(encryptedPassword))
    fields.append(lengthPrefixed(guid))
    fields.append(lengthPrefixed(certificate))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: flags,
        fields: fields
    )))

    #expect(pdu.routingToken == cookie)
    #expect(pdu.username == "rdp-user")
    #expect(pdu.password == nil)
    #expect(pdu.encryptedPassword == encryptedPassword)
    #expect(pdu.redirectionGuid == guid)
    #expect(pdu.targetCertificate == certificate)
}

@Test func doesNotParseOptionalFieldsWhenUnknownFlagIsSet() throws {
    let cookie = Data("Cookie: mststs=42\r\n".utf8)
    let unknownFlag: UInt32 = 0x0000_0400

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue | unknownFlag,
        fields: lengthPrefixed(cookie)
    )))

    // An unrecognized flag makes the field layout ambiguous, so we must not
    // extract a routing token (and therefore must not follow the redirection).
    #expect(pdu.flags.contains(.loadBalanceInfo))
    #expect(pdu.routingToken == nil)
}

@Test func rejectsTargetNetAddressesWithTrailingBytes() {
    var addresses = targetNetAddresses([utf16LE("192.0.2.10")])
    addresses.append(0xFF)

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
            flags: RDPServerRedirectionPDU.Flags.targetNetAddresses.rawValue,
            fields: lengthPrefixed(addresses)
        ))
    }
}

@Test func rejectsTargetNetAddressesWhenCountExceedsEntries() {
    var addresses = Data()
    addresses.appendLittleEndianUInt32(2)
    addresses.append(lengthPrefixed(utf16LE("192.0.2.10")))

    #expect(throws: RDPDecodeError.truncated(needed: 4, remaining: 0)) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
            flags: RDPServerRedirectionPDU.Flags.targetNetAddresses.rawValue,
            fields: lengthPrefixed(addresses)
        ))
    }
}

@Test func ignoresNonRedirectionShareControlPacket() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(6)
    userData.appendLittleEndianUInt16(0x0016)
    userData.appendLittleEndianUInt16(1005)

    #expect(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    )) == nil)
}

private func redirectionIndication(
    channelID: UInt16 = 1003,
    sessionID: UInt32 = 4,
    flags: UInt32,
    fields: Data
) -> Data {
    mcsSendDataIndication(
        channelID: channelID,
        userData: redirectionUserData(sessionID: sessionID, flags: flags, fields: fields)
    )
}

private func redirectionUserData(
    sessionID: UInt32,
    flags: UInt32,
    fields: Data
) -> Data {
    let redirectionLength = UInt16(12 + fields.count)
    let totalLength = UInt16(8 + Int(redirectionLength))
    var userData = Data()
    userData.appendLittleEndianUInt16(totalLength)
    userData.appendLittleEndianUInt16(0x000A)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(0x0400)
    userData.appendLittleEndianUInt16(redirectionLength)
    userData.appendLittleEndianUInt32(sessionID)
    userData.appendLittleEndianUInt32(flags)
    userData.append(fields)
    return userData
}

private func lengthPrefixed(_ data: Data) -> Data {
    var out = Data()
    out.appendLittleEndianUInt32(UInt32(data.count))
    out.append(data)
    return out
}

private func targetNetAddresses(_ addresses: [Data]) -> Data {
    var out = Data()
    out.appendLittleEndianUInt32(UInt32(addresses.count))
    for address in addresses {
        out.append(lengthPrefixed(address))
    }
    return out
}

private func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(1007 - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

private func utf16LE(_ string: String) -> Data {
    var data = Data()
    for codeUnit in string.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.appendLittleEndianUInt16(0)
    return data
}
