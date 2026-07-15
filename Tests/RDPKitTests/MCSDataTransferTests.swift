import Foundation
@testable import RDPKit
import Testing

@Test func sendDataRequestEncodesMaximumUserDataLength() {
    let userData = Data(repeating: 0xAA, count: MCSSendDataRequestPDU.maximumUserDataByteCount)
    let packet = MCSSendDataRequestPDU(
        initiator: 1007,
        channelID: 1003,
        userData: userData
    ).encodedTPKT()

    #expect(Data(packet.dropFirst(4).prefix(10)) == Data([
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x06, 0x03, 0xEB, 0x70, 0xBF,
    ]))
    #expect(packet[14] == 0xFF)
}

@Test func sendDataRequestUsesSingleBytePERLengthAtBoundary() {
    let packet = MCSSendDataRequestPDU(
        initiator: 1007,
        channelID: 1003,
        userData: Data(repeating: 0xAA, count: 0x7F)
    ).encodedTPKT()

    #expect(packet[13] == 0x7F)
}

@Test func sendDataRequestUsesTwoBytePERLengthAboveBoundary() {
    let packet = MCSSendDataRequestPDU(
        initiator: 1007,
        channelID: 1003,
        userData: Data(repeating: 0xAA, count: 0x80)
    ).encodedTPKT()

    #expect(packet[13] == 0x80)
    #expect(packet[14] == 0x80)
}

@Test func parsesMCSSendDataIndicationPayload() throws {
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: Data([0x01, 0x02, 0x03])
    ))

    #expect(indication.initiator == 1007)
    #expect(indication.channelID == 1003)
    #expect(indication.userData == Data([0x01, 0x02, 0x03]))
}

@Test func parsesMCSSendDataIndicationWithTwoBytePERLength() throws {
    let userData = Data(repeating: 0xCC, count: 0x80)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    ))

    #expect(indication.userData == userData)
}

@Test func parsesMCSSendDataIndicationWithLowPriorityBeginEndSegmentation() throws {
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        flags: 0xF0,
        userData: Data([0x01, 0x02, 0x03])
    ))

    #expect(indication.initiator == 1007)
    #expect(indication.channelID == 1003)
    #expect(indication.userData == Data([0x01, 0x02, 0x03]))
}

@Test func rejectsMCSSendDataIndicationWithoutCompleteSegmentation() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        flags: 0x40,
        userData: Data([0x01, 0x02, 0x03])
    )

    #expect(throws: RDPDecodeError.invalidMCSSendDataIndication) {
        try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
    }
}

@Test func rejectsMCSSendDataIndicationWithNonzeroFlagPadding() throws {
    let packet = mcsSendDataIndication(
        channelID: 1003,
        flags: 0x71,
        userData: Data([0x01, 0x02, 0x03])
    )

    #expect(throws: RDPDecodeError.invalidMCSSendDataIndication) {
        try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
    }
}

@Test func rejectsMCSSendDataIndicationWithTruncatedHeader() throws {
    let packet = X224DataTPDU.wrap(Data([
        0x68,
        0x00, 0x06,
        0x03,
    ]))

    #expect(throws: RDPDecodeError.invalidMCSSendDataIndication) {
        try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
    }
}

@Test func rejectsMCSSendDataIndicationWithUnsupportedPERLengthForm() throws {
    let packet = X224DataTPDU.wrap(Data([
        0x68,
        0x00, 0x06,
        0x03, 0xEB,
        0x70,
        0xC0,
    ]))

    #expect(throws: RDPDecodeError.invalidBERLength) {
        try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
    }
}

@Test func rejectsMCSSendDataIndicationWithTrailingBytes() throws {
    let packet = X224DataTPDU.wrap(Data([
        0x68,
        0x00, 0x06,
        0x03, 0xEB,
        0x70,
        0x03,
        0x01, 0x02, 0x03,
        0x04,
    ]))

    #expect(throws: RDPDecodeError.invalidMCSSendDataIndication) {
        try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
    }
}

private func mcsSendDataIndication(
    channelID: UInt16,
    flags: UInt8 = 0x70,
    userData: Data
) -> Data {
    var payload = Data()
    payload.appendUInt8(0x68)
    payload.appendBigEndianUInt16(6)
    payload.appendBigEndianUInt16(channelID)
    payload.appendUInt8(flags)
    payload.appendPERLength(userData.count)
    payload.append(userData)
    return X224DataTPDU.wrap(payload)
}
