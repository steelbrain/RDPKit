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
