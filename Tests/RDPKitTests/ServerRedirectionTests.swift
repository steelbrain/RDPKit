import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerRedirectionWithLoadBalanceCookie() throws {
    let cookie = Data("Cookie: mststs=1183689379\r\n".utf8)
    let username = utf16LE("aneesiqbal")
    let netbios = utf16LE("ANEES-MSI-LAPTOP")
    var userData = Data()
    let redirectionLength = UInt16(4 + 2 + 2 + 2 + 4 + 4 + cookie.count + 4 + username.count + 4 + netbios.count)
    let totalLength = UInt16(6 + Int(redirectionLength))
    userData.appendLittleEndianUInt16(totalLength)
    userData.appendLittleEndianUInt16(0x001A)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt32(0x0400_0000)
    userData.appendLittleEndianUInt16(redirectionLength)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(4)
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
    #expect(pdu.securityFlags == 0x0400_0000)
    #expect(pdu.redirectionLength == redirectionLength)
    #expect(pdu.sessionID == 4)
    #expect(pdu.flags.contains(.loadBalanceInfo))
    #expect(pdu.routingToken == cookie)
    #expect(pdu.username == "aneesiqbal")
    #expect(pdu.targetNetBIOSName == "ANEES-MSI-LAPTOP")
    #expect(pdu.targetHost == "ANEES-MSI-LAPTOP")
}

@Test func parsesServerRedirectionTargetAndCredentialFields() throws {
    let netAddress = utf16LE("192.0.2.10")
    let username = utf16LE("aneesiqbal")
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
    #expect(pdu.username == "aneesiqbal")
    #expect(pdu.domain == "WORKGROUP")
    #expect(pdu.password == "hunter2")
    #expect(pdu.targetFQDN == "desktop.example.test")
    // targetHost prefers the FQDN over the raw net address.
    #expect(pdu.targetHost == "desktop.example.test")
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
    let username = utf16LE("aneesiqbal")
    let password = utf16LE("aneesiqbal")
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
    fields.append(lengthPrefixed(password))
    fields.append(lengthPrefixed(guid))
    fields.append(lengthPrefixed(certificate))

    let pdu = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: redirectionIndication(
        flags: flags,
        fields: fields
    )))

    #expect(pdu.routingToken == cookie)
    #expect(pdu.username == "aneesiqbal")
    #expect(pdu.password == "aneesiqbal")
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
    sessionID: UInt16 = 4,
    flags: UInt32,
    fields: Data
) -> Data {
    let redirectionLength = UInt16(4 + 2 + 2 + 2 + 4 + fields.count)
    let totalLength = UInt16(6 + Int(redirectionLength))
    var userData = Data()
    userData.appendLittleEndianUInt16(totalLength)
    userData.appendLittleEndianUInt16(0x001A)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt32(0x0400_0000)
    userData.appendLittleEndianUInt16(redirectionLength)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(sessionID)
    userData.appendLittleEndianUInt32(flags)
    userData.append(fields)
    return mcsSendDataIndication(channelID: channelID, userData: userData)
}

private func lengthPrefixed(_ data: Data) -> Data {
    var out = Data()
    out.appendLittleEndianUInt32(UInt32(data.count))
    out.append(data)
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
