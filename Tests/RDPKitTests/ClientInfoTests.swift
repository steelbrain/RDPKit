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
    let credentials = RDPCredentials(username: "aneesi", domain: "LAB", password: "secret")
    let clientInfo = RDPClientInfoPDU(credentials: credentials)
    let pduData = try clientInfo.encodedPDUData()

    #expect(Data(pduData.prefix(22)) == Data([
        0x40, 0x00, 0x00, 0x00,
        0x09, 0x04, 0x00, 0x00,
        0x5B, 0x41, 0x00, 0x00,
        0x06, 0x00,
        0x0C, 0x00,
        0x0C, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ]))
    #expect(pduData.range(of: utf16LENullTerminated("LAB")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("aneesi")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("secret")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("0.0.0.0")) != nil)
    #expect(pduData.range(of: utf16LENullTerminated("KRDPSwift")) != nil)
}

@Test func clientInfoTPKTUsesUserChannelAsInitiatorAndIOChannelAsTarget() throws {
    let credentials = RDPCredentials(username: "aneesi", domain: nil, password: "secret")
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

    #expect(flags == 0x0000_4153)
}

@Test func clientInfoRejectsOverlongUnicodeFields() {
    let password = String(repeating: "x", count: 256)
    let credentials = RDPCredentials(username: "aneesi", domain: nil, password: password)

    #expect(throws: RDPClientInfoEncodingError.fieldTooLong(
        name: "password",
        maxBytesIncludingNull: 512,
        actualBytesIncludingNull: 514
    )) {
        try RDPClientInfoPDU(credentials: credentials).encodedPDUData()
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
