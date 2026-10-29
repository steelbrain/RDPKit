import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerRedirectionWithLoadBalanceCookie() throws {
    let cookie = Data("Cookie: mststs=1183689379\r\n".utf8)
    let username = utf16LENullTerminated("rdp-user")
    let netbios = utf16LENullTerminated("ANEES-MSI-LAPTOP")
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
    #expect(pdu.sessionID == 4)
    #expect(pdu.flags.contains(.loadBalanceInfo))
    #expect(pdu.routingToken == cookie)
    #expect(pdu.username == "rdp-user")
    #expect(pdu.targetNetBIOSName == "ANEES-MSI-LAPTOP")
    #expect(pdu.targetHost == "ANEES-MSI-LAPTOP")
}

@Test func parsesServerRedirectionTargetAndCredentialFields() throws {
    let netAddress = utf16LENullTerminated("192.0.2.10")
    let username = utf16LENullTerminated("rdp-user")
    let domain = utf16LENullTerminated("WORKGROUP")
    let password = utf16LENullTerminated("hunter2")
    let fqdn = utf16LENullTerminated("desktop.example.test")

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
    let netAddress = utf16LENullTerminated("192.0.2.10")
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
    let netAddress = utf16LENullTerminated("2001:db8::1")
    let netbios = utf16LENullTerminated("RDSHOST")
    var fields = Data()
    fields.append(lengthPrefixed(netAddress))
    fields.append(lengthPrefixed(netbios))
    fields.append(lengthPrefixed(targetNetAddresses([
        utf16LENullTerminated("2001:db8::1"),
        utf16LENullTerminated("192.0.2.10"),
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
    let tsvURL = utf16LENullTerminated("tsv://collection")
    let guid = Data("UkRQS2l0LXJlZGlyZWN0LWd1aWQ=".utf8)
    let certificate = Data("UkRQS2l0LWNlcnQ=".utf8)
    var fields = Data()
    fields.append(lengthPrefixed(tsvURL))
    fields.append(lengthPrefixed(guid))
    fields.append(lengthPrefixed(certificate))
    fields.append(lengthPrefixed(targetNetAddresses([
        utf16LENullTerminated("2001:db8::1"),
        utf16LENullTerminated("192.0.2.10"),
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
        fields: lengthPrefixed(utf16LENullTerminated("desktop.example.test"))
    )))

    #expect(pdu.sessionID == 0x1234_5678)
    #expect(pdu.targetFQDN == "desktop.example.test")
}

@Test func parsesCapturedGnomeRedirection() throws {
    // Fixtures/gnome-negotiation-transcript.json, sequence 58: TS_PROTOCOL_VERSION 1 in
    // the Share Control header and a redirection Length overstated by 2.
    let packet = try #require(Data(rdpHexString: """
    03 00 00 42 02 f0 80 68 00 05 03 eb 70 34 34 00 1a 00 00 00 00 00 00 04 2e 00 00 00
    04 00 02 00 00 00 1c 00 00 00 43 6f 6f 6b 69 65 3a 20 6d 73 74 73 3d 6c 6f 61 64 2d
    62 61 6c 61 6e 63 65 64 0d 0a
    """))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: packet, channelID: 1003))
    #expect(pdu.routingToken == Data("Cookie: msts=load-balanced\r\n".utf8))
    #expect(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: packet, channelID: 1004) == nil)
}

@Test func acceptsServerRedirectionWithVersionZeroAndVersionOneShareHeaders() throws {
    // Version 0 is the [MS-RDPBCGR] 2.2.13.3.1 form Windows sends; version 1 is GRD's.
    for pduType: [UInt8] in [[0x0A, 0x00], [0x1A, 0x00]] {
        var packet = redirectionUserData(
            sessionID: 4,
            flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
            fields: lengthPrefixed(Data("Cookie: mststs=load-balanced\r\n".utf8))
        )
        packet.replaceSubrange(2 ..< 4, with: Data(pduType))

        let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: packet
        )))
        #expect(pdu.routingToken == Data("Cookie: mststs=load-balanced\r\n".utf8))
    }
}

@Test func parsesWindowsServerRedirectionWithTrailingPadOctet() throws {
    // Shaped like the [MS-RDPBCGR] 4.6 Windows capture: version 0 header, a
    // load-balance cookie, user name, domain, binary password cookie and FQDN,
    // then the optional pad1Octet counted only in the Share Control length.
    let cookie = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    var fields = lengthPrefixed(Data("Cookie: msts=3640205228.15629.0000\r\n".utf8))
    fields.append(lengthPrefixed(utf16LENullTerminated("AdminUser\u{0}")))
    fields.append(lengthPrefixed(utf16LENullTerminated("NTDEV\u{0}")))
    fields.append(lengthPrefixed(cookie))
    fields.append(lengthPrefixed(utf16LENullTerminated("server2.example.test\u{0}")))
    let flags: RDPServerRedirectionPDU.Flags = [.loadBalanceInfo, .username, .domain, .password, .targetFQDN]
    var packet = redirectionUserData(sessionID: 2, flags: flags.rawValue, fields: fields)
    packet.append(0)
    let totalLength = UInt16(packet.count)
    packet.replaceSubrange(0 ..< 2, with: Data([UInt8(totalLength & 0xFF), UInt8(totalLength >> 8)]))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: packet
    )))
    #expect(pdu.sessionID == 2)
    #expect(pdu.username == "AdminUser")
    #expect(pdu.domain == "NTDEV")
    #expect(pdu.passwordCookie == cookie)
    #expect(pdu.targetFQDN == "server2.example.test")
    #expect(pdu.routingToken == Data("Cookie: msts=3640205228.15629.0000\r\n".utf8))
}

@Test func keepsBinaryRedirectionPasswordCookieVerbatim() throws {
    let cookie = Data([0x01, 0x00, 0x00, 0x00, 0xD8, 0x00, 0xFF, 0xFE, 0x00, 0x00, 0x41])

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: RDPServerRedirectionPDU.Flags.password.rawValue,
        fields: lengthPrefixed(cookie)
    )))

    #expect(pdu.passwordCookie == cookie)
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
    let username = utf16LENullTerminated("rdp-user")
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
    #expect(pdu.passwordCookie == encryptedPassword)
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
    var addresses = targetNetAddresses([utf16LENullTerminated("192.0.2.10")])
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
    addresses.append(lengthPrefixed(utf16LENullTerminated("192.0.2.10")))

    #expect(throws: RDPDecodeError.truncated(needed: 4, remaining: 0)) {
        try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
            flags: RDPServerRedirectionPDU.Flags.targetNetAddresses.rawValue,
            fields: lengthPrefixed(addresses)
        ))
    }
}

@Test func doesNotUseLoadBalanceInfoThatCannotFitInConnectionRequest() throws {
    // A longer token used to trip the X.224 length precondition when reconnecting.
    let fitting = Data(repeating: 0x41, count: 238) + Data("\r\n".utf8)
    let oversized = Data(repeating: 0x41, count: 239) + Data("\r\n".utf8)

    for (cookie, expected) in [(fitting, fitting), (oversized, nil)] {
        let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
            flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
            fields: lengthPrefixed(cookie)
        )))
        #expect(pdu.loadBalanceInfo == cookie)
        #expect(pdu.routingToken == expected)
    }
    let packet = X224ConnectionRequest(routingToken: fitting).encodedTPKT()
    #expect(packet.count == 4 + 255)
    #expect(packet[4] == 254)
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

/// LB_NOREDIRECT marks the PDU informational: nothing to reconnect to
/// ([MS-RDPBCGR] 2.2.13.1).
@Test func informationalRedirectionNamesNoReconnectTarget() {
    let configuration = RDPConnectionConfiguration(host: "broker.example")
    var redirection = RDPServerRedirectionPDU(channelID: 1003, sessionID: 7, flags: [.loadBalanceInfo, .noRedirect])
    redirection.loadBalanceInfo = Data("Cookie: msts=1\r\n".utf8)
    #expect(configuration.redirected(by: redirection) == nil)

    redirection.flags.remove(.noRedirect)
    #expect(configuration.redirected(by: redirection)?.redirectionRoutingToken == redirection.loadBalanceInfo)
}

/// A redirection that names only the user keeps the domain the configured
/// "DOMAIN\user" named; one that names "DOMAIN\user" itself is split too.
@Test func redirectionKeepsTheDomainOfADomainQualifiedUsername() throws {
    let configuration = RDPConnectionConfiguration(
        host: "broker.example",
        credentials: RDPCredentials(username: "CORP\\alice", password: "secret")
    )
    var redirection = RDPServerRedirectionPDU(channelID: 1003, sessionID: 7, flags: [.loadBalanceInfo, .username])
    redirection.loadBalanceInfo = Data("Cookie: msts=1\r\n".utf8)
    redirection.username = "alice"
    let sameDomain = try #require(configuration.redirected(by: redirection)?.credentials)
    redirection.username = "LAB\\bob"
    let otherDomain = try #require(RDPConnectionConfiguration(host: "broker.example", credentials: RDPCredentials(
        username: "alice",
        password: "secret"
    )).redirected(by: redirection)?.credentials)

    #expect([sameDomain.username, sameDomain.domain] == ["alice", "CORP"])
    #expect([otherDomain.username, otherDomain.domain] == ["bob", "LAB"])
}

// TPKT entry point for tests; the client parses the indication routed from
// the I/O channel.
extension RDPServerRedirectionPDU {
    static func parseIfPresent(fromTPKT packet: Data, channelID: UInt16? = nil) throws -> RDPServerRedirectionPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet),
              channelID.map({ indication.channelID == $0 }) ?? true
        else {
            return nil
        }
        return try parseIfPresent(from: indication)
    }
}
