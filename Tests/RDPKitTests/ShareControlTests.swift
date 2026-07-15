import Foundation
@testable import RDPKit
import Testing

@Test func parsesServerDeactivateAllFromPostAutoDetectPacket() throws {
    let pdu = try #require(try RDPShareControlPDU.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x1C,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x04, 0x03, 0xEB, 0x70, 0x80, 0x0D,
        0x0D, 0x00, 0x16, 0x00, 0xED, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
    ])))

    #expect(pdu.channelID == 1003)
    #expect(pdu.totalLength == 13)
    #expect(pdu.pduType == 0x0016)
    #expect(pdu.type == 0x0006)
    #expect(pdu.protocolVersion == 0x0001)
    #expect(pdu.pduSource == 1005)
    #expect(pdu.typeName == "server-deactivate-all")
}

@Test func ignoresNonShareControlPackets() throws {
    #expect(try RDPShareControlPDU.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x19,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x04, 0x00, 0x00, 0x70, 0x80, 0x0A,
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00, 0x23, 0x00, 0x01, 0x10,
    ])) == nil)
}

@Test func shareControlIgnoresT128FlowPDU() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(0x8000)
    userData.appendLittleEndianUInt16(0x0016)
    userData.appendLittleEndianUInt16(1005)
    userData.appendUInt8(0)

    #expect(try RDPShareControlPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    )) == nil)
}

@Test func shareControlRejectsDeclaredLengthShorterThanHeader() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(5)
    userData.appendLittleEndianUInt16(0x0016)
    userData.appendLittleEndianUInt16(1005)

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPShareControlPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: userData
        ))
    }
}

@Test func shareControlRejectsDeclaredLengthShorterThanPacket() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(6)
    userData.appendLittleEndianUInt16(0x0016)
    userData.appendLittleEndianUInt16(1005)
    userData.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidShareControlHeader) {
        try RDPShareControlPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: userData
        ))
    }
}

@Test func shareDataRejectsDeclaredLengthShorterThanHeader() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(17)
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0x1F)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)

    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: userData
        ))
    }
}

@Test func shareDataRejectsDeclaredLengthShorterThanPacket() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(18)
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0x1F)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
            channelID: 1003,
            userData: userData
        ))
    }
}

@Test func shareDataIgnoresMalformedPacketOnDifferentChannel() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(18)
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0x1F)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0)

    let packet = mcsSendDataIndication(channelID: 1004, userData: userData)

    #expect(try RDPShareDataPDU.parseIfPresent(fromTPKT: packet, channelID: 1003) == nil)
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: packet, channelID: 1004)
    }
}

@Test func shareDataParsesDeclaredHeaderOnlyPDU() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(18)
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(0)
    userData.appendUInt8(0x24)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    )))

    #expect(pdu.typeName == "share-data-0x24")
    #expect(pdu.payload.isEmpty)
}

@Test func shareDataIgnoresT128FlowPDU() throws {
    var userData = Data()
    userData.appendLittleEndianUInt16(0x8000)
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(1005)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(1)
    userData.appendLittleEndianUInt16(4)
    userData.appendUInt8(0x1F)
    userData.appendUInt8(0)
    userData.appendLittleEndianUInt16(0)
    userData.appendLittleEndianUInt16(0x0001)
    userData.appendLittleEndianUInt16(1002)

    #expect(try RDPShareDataPDU.parseIfPresent(fromTPKT: mcsSendDataIndication(
        channelID: 1003,
        userData: userData
    )) == nil)
}

@Test func shareDataRejectsInvalidStreamIDs() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x28,
            streamID: 0x00,
            payload: Data(repeating: 0, count: 8)
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x1F,
            streamID: 0x03,
            payload: Data([0x01, 0x00, 0xEA, 0x03])
        ))
    }
    #expect(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x1F,
        streamID: 0x00,
        payload: Data([0x01, 0x00, 0xEA, 0x03])
    ))?.typeName == "server-synchronize")
}

@Test func shareDataRejectsCompressedPayloadWithoutBulkDecompression() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x02,
            compressedType: 0x20,
            compressedLength: 4,
            payload: Data([0x01, 0x02, 0x03, 0x04])
        ))
    }
}

@Test func shareDataRejectsCompressedLengthWithoutCompressionFlags() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x24,
            compressedLength: 1,
            payload: Data()
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x24,
            compressedType: 0x01,
            compressedLength: 1,
            payload: Data()
        ))
    }
}

@Test func shareDataRejectsInvalidCompressionTypeBits() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x24,
            compressedType: 0x04,
            payload: Data()
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x24,
            compressedType: 0x10,
            payload: Data()
        ))
    }
}

@Test func shareDataParsesSetErrorInfoPDU() throws {
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x2F,
        pduSource: 0,
        payload: Data([0x09, 0x00, 0x00, 0x00])
    )))

    #expect(pdu.typeName == "set-error-info")
    #expect(pdu.errorInfo == 0x0000_0009)
}

@Test func shareDataParsesMonitorLayoutPDU() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(1919)
    payload.appendLittleEndianUInt32(1079)
    payload.appendLittleEndianUInt32(1)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x37,
        pduSource: 0,
        payload: payload
    )))

    #expect(pdu.typeName == "monitor-layout")
    #expect(pdu.monitorLayoutMonitorCount == 1)
}

@Test func shareDataParsesAutoReconnectStatusPDU() throws {
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x32,
        pduSource: 0,
        payload: Data([0x00, 0x00, 0x00, 0x00])
    )))

    #expect(pdu.typeName == "auto-reconnect-status")
    #expect(pdu.autoReconnectStatus == 0)
}

@Test func shareDataParsesStatusInfoPDU() throws {
    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x36,
        pduSource: 0,
        payload: Data([0x01, 0x04, 0x00, 0x00])
    )))

    #expect(pdu.typeName == "status-info")
    #expect(pdu.statusInfo == 0x0000_0401)
}

@Test func shareDataParsesPlaySoundPDU() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(250)
    payload.appendLittleEndianUInt32(880)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x22,
        payload: payload
    )))

    #expect(pdu.typeName == "play-sound")
    #expect(pdu.playSound == RDPPlaySoundPDU(duration: 250, frequency: 880))
}

@Test func shareDataParsesSaveSessionInfoExtendedAutoReconnectPDU() throws {
    let randomBits = Data([
        0xA8, 0x02, 0xE7, 0x25,
        0xE2, 0x4C, 0x82, 0xB7,
        0x52, 0xA5, 0x53, 0x50,
        0x34, 0x98, 0xA1, 0xA8,
    ])
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0003)
    payload.appendLittleEndianUInt16(38)
    payload.appendLittleEndianUInt32(0x0000_0001)
    payload.appendLittleEndianUInt32(28)
    payload.appendLittleEndianUInt32(28)
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(2)
    payload.append(randomBits)
    payload.append(Data(repeating: 0, count: 570))

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x26,
        payload: payload
    )))

    #expect(pdu.typeName == "save-session-info")
    let saveSessionInfo = try #require(pdu.saveSessionInfo)
    #expect(saveSessionInfo.infoType == .logonExtendedInfo)
    #expect(saveSessionInfo.infoTypeRawValue == 0x0000_0003)
    #expect(saveSessionInfo.autoReconnectPacket == RDPServerAutoReconnectPacket(
        version: 1,
        logonID: 2,
        arcRandomBits: randomBits
    ))
}

@Test func shareDataParsesSaveSessionInfoLogonStringsWithTerminators() throws {
    let version1 = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x26,
        payload: saveSessionInfoLogonVersion1Payload(domain: "LAB", userName: "rdp-user")
    )))
    #expect(version1.saveSessionInfo?.infoType == .logon)

    let version2 = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x26,
        payload: saveSessionInfoLogonVersion2Payload(domain: "LAB", userName: "rdp-user")
    )))
    #expect(version2.saveSessionInfo?.infoType == .logonLong)
}

@Test func shareDataParsesSaveSessionInfoLogonVersion2WithTrailingPadding() throws {
    var payload = saveSessionInfoLogonVersion2Payload(domain: "WINDOWS-HOST", userName: "RDPUser")
    payload.append(Data(repeating: 0, count: 562))

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x26,
        payload: payload
    )))

    #expect(pdu.typeName == "save-session-info")
    #expect(pdu.saveSessionInfo?.infoType == .logonLong)
}

@Test func shareDataRejectsSaveSessionInfoLogonVersion2WithNonzeroTrailingPadding() throws {
    var payload = saveSessionInfoLogonVersion2Payload(domain: "WINDOWS-HOST", userName: "RDPUser")
    payload.append(Data(repeating: 0, count: 32))
    payload.append(0x01)

    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: payload
        ))
    }
}

@Test func shareDataRejectsSaveSessionInfoLogonStringsWithoutTerminators() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: saveSessionInfoLogonVersion1Payload(
                domain: "LAB",
                userName: "rdp-user",
                includeUserNameTerminator: false
            )
        ))
    }

    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: saveSessionInfoLogonVersion2Payload(
                domain: "LAB",
                userName: "rdp-user",
                includeDomainTerminator: false
            )
        ))
    }
}

@Test func shareDataParsesSetKeyboardIndicatorsPDU() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0x0006)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x29,
        payload: payload
    )))

    #expect(pdu.typeName == "set-keyboard-indicators")
    #expect(pdu.keyboardIndicatorUnitID == 0)
    #expect(pdu.keyboardIndicatorFlags == [.numLock, .capsLock])
}

@Test func shareDataParsesSetKeyboardIMEStatusPDU() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt32(0x0000_0001)
    payload.appendLittleEndianUInt32(0x0000_0019)

    let pdu = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x2D,
        payload: payload
    )))

    #expect(pdu.typeName == "set-keyboard-ime-status")
    #expect(pdu.keyboardIMEStatus == RDPKeyboardIMEStatus(
        unitID: 0,
        imeState: 0x0000_0001,
        imeConversionMode: 0x0000_0019
    ))
}

@Test func shareDataIgnoresControlGrantAndControlIDsForKnownActions() throws {
    let requestControl = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x14,
        payload: controlPayload(action: 0x0001, grantID: 1, controlID: 0)
    )))
    let grantedControl = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x14,
        payload: controlPayload(action: 0x0002, grantID: 1006, controlID: 1003)
    )))
    let cooperate = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
        type: 0x14,
        payload: controlPayload(action: 0x0004, grantID: 0, controlID: 1)
    )))

    #expect(requestControl.typeName == "control-request-control")
    #expect(grantedControl.typeName == "control-granted-control")
    #expect(cooperate.typeName == "control-cooperate")
}

@Test func shareDataRejectsMalformedFixedFinalizationPayloads() throws {
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(type: 0x1F, payload: Data([0x01, 0x00])))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x1F,
            payload: Data([0x02, 0x00, 0xEA, 0x03])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(type: 0x14, payload: Data(repeating: 0, count: 6)))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x14,
            payload: controlPayload(action: 0x1000, grantID: 0, controlID: 0)
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(type: 0x28, payload: Data(repeating: 0, count: 10)))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x2F,
            pduSource: 0,
            payload: Data([0x09, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x2F,
            payload: Data([0x09, 0x00, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x32,
            pduSource: 0,
            payload: Data([0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x32,
            pduSource: 0,
            payload: Data([0x01, 0x00, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x32,
            payload: Data([0x00, 0x00, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x36,
            pduSource: 0,
            payload: Data([0x01, 0x04])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x36,
            payload: Data([0x01, 0x04, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x22,
            payload: Data(repeating: 0, count: 6)
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: Data()
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: Data([0x02, 0x00, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        var payload = Data()
        payload.appendLittleEndianUInt32(0x0000_0003)
        payload.appendLittleEndianUInt16(38)
        payload.appendLittleEndianUInt32(0x0000_0001)
        payload.appendLittleEndianUInt32(28)
        payload.appendLittleEndianUInt32(24)
        payload.appendLittleEndianUInt32(1)
        payload.appendLittleEndianUInt32(2)
        payload.append(Data(repeating: 0, count: 16))
        _ = try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x26,
            payload: payload
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x29,
            payload: Data([0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x2D,
            payload: Data(repeating: 0, count: 8)
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x37,
            pduSource: 0,
            payload: Data([0x01, 0x00, 0x00])
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        var payload = Data()
        payload.appendLittleEndianUInt32(2)
        payload.append(Data(repeating: 0, count: 20))
        _ = try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x37,
            pduSource: 0,
            payload: payload
        ))
    }
    #expect(throws: RDPDecodeError.invalidShareDataHeader) {
        var payload = Data()
        payload.appendLittleEndianUInt32(1)
        payload.append(Data(repeating: 0, count: 20))
        _ = try RDPShareDataPDU.parseIfPresent(fromTPKT: shareDataPacket(
            type: 0x37,
            payload: payload
        ))
    }
}

private func mcsSendDataIndication(channelID: UInt16, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(1005 - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(0x70)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

private func shareDataPacket(
    type: UInt8,
    pduSource: UInt16 = 1005,
    streamID: UInt8 = 1,
    compressedType: UInt8 = 0,
    compressedLength: UInt16 = 0,
    payload: Data
) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(18 + payload.count))
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(pduSource)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(streamID)
    userData.appendLittleEndianUInt16(UInt16(payload.count + 4))
    userData.appendUInt8(type)
    userData.appendUInt8(compressedType)
    userData.appendLittleEndianUInt16(compressedLength)
    userData.append(payload)
    return mcsSendDataIndication(channelID: 1003, userData: userData)
}

private func controlPayload(action: UInt16, grantID: UInt16, controlID: UInt32) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(action)
    payload.appendLittleEndianUInt16(grantID)
    payload.appendLittleEndianUInt32(controlID)
    return payload
}

private func saveSessionInfoLogonVersion1Payload(
    domain: String,
    userName: String,
    includeDomainTerminator: Bool = true,
    includeUserNameTerminator: Bool = true
) -> Data {
    let domainBytes = utf16LE(domain, nullTerminated: includeDomainTerminator)
    let userNameBytes = utf16LE(userName, nullTerminated: includeUserNameTerminator)
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0000)
    payload.appendLittleEndianUInt32(UInt32(domainBytes.count))
    payload.append(padded(domainBytes, to: 52))
    payload.appendLittleEndianUInt32(UInt32(userNameBytes.count))
    payload.append(padded(userNameBytes, to: 512))
    payload.appendLittleEndianUInt32(2)
    return payload
}

private func saveSessionInfoLogonVersion2Payload(
    domain: String,
    userName: String,
    includeDomainTerminator: Bool = true,
    includeUserNameTerminator: Bool = true
) -> Data {
    let domainBytes = utf16LE(domain, nullTerminated: includeDomainTerminator)
    let userNameBytes = utf16LE(userName, nullTerminated: includeUserNameTerminator)
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0001)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt32(18)
    payload.appendLittleEndianUInt32(2)
    payload.appendLittleEndianUInt32(UInt32(domainBytes.count))
    payload.appendLittleEndianUInt32(UInt32(userNameBytes.count))
    payload.append(Data(repeating: 0, count: 558))
    payload.append(domainBytes)
    payload.append(userNameBytes)
    return payload
}

private func padded(_ data: Data, to byteCount: Int) -> Data {
    var paddedData = data
    paddedData.append(Data(repeating: 0, count: byteCount - data.count))
    return paddedData
}

private func utf16LE(_ value: String, nullTerminated: Bool) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    if nullTerminated {
        data.appendLittleEndianUInt16(0)
    }
    return data
}
