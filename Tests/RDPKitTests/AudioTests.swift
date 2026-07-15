import Foundation
import NIOEmbedded
@testable import RDPKit
import Testing

@Test func audioPDUParsesHeaderAndPayload() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x07, 0x00, 0x04, 0x00,
        0x01, 0x02, 0x03, 0x04,
    ]))

    #expect(pdu.header.messageType == RDPAudioMessageType.formats)
    #expect(pdu.header.bodySize == 4)
    #expect(pdu.payload == Data([0x01, 0x02, 0x03, 0x04]))
    #expect(pdu.typeName == "audio-formats")
}

@Test func audioPDURejectsBodyLengthMismatch() {
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        _ = try RDPAudioPDU.parse(from: Data([
            0x07, 0x00, 0x04, 0x00,
            0x01, 0x02, 0x03,
        ]))
    }
}

@Test func audioFormatRoundTripsPCMFormat() throws {
    let encoded = RDPAudioFormat.pcmStereo48k16Bit.encoded()
    var cursor = ByteCursor(encoded)
    let parsed = try RDPAudioFormat.parse(from: &cursor)

    #expect(encoded == Data([
        0x01, 0x00,
        0x02, 0x00,
        0x80, 0xBB, 0x00, 0x00,
        0x00, 0xEE, 0x02, 0x00,
        0x04, 0x00,
        0x10, 0x00,
        0x00, 0x00,
    ]))
    #expect(parsed == .pcmStereo48k16Bit)
}

@Test func audioFormatRejectsOversizedExtraData() {
    let extraData = Data(count: RDPAudioFormat.maximumExtraDataByteCount + 1)

    #expect(throws: RDPAudioFormatValidationError.extraDataTooLarge(
        maximumByteCount: RDPAudioFormat.maximumExtraDataByteCount,
        actualByteCount: extraData.count
    )) {
        _ = try RDPAudioFormat(
            formatTag: RDPAudioFormatTag.pcm,
            channelCount: 2,
            samplesPerSecond: 48000,
            averageBytesPerSecond: 192_000,
            blockAlign: 4,
            bitsPerSample: 16,
            extraData: extraData
        )
    }
}

@Test func audioInputPDUParsesHeaderAndPayload() throws {
    let pdu = try RDPAudioInputPDU.parse(from: Data([
        0x01,
        0x02, 0x00, 0x00, 0x00,
    ]))

    #expect(pdu.messageType == RDPAudioInputMessageType.version)
    #expect(pdu.payload.rdpHexString == "02 00 00 00")
    #expect(pdu.typeName == "audio-input-version")
    #expect(pdu.encoded().rdpHexString == "01 02 00 00 00")
}

@Test func audioInputVersionParsesSpecExampleAndCapsClientVersion() throws {
    let serverPDU = try RDPAudioInputPDU.parse(from: Data([
        0x01,
        0x01, 0x00, 0x00, 0x00,
    ]))
    let version = try #require(try RDPAudioInputVersionPDU.parseIfPresent(from: serverPDU))

    #expect(version.version == 1)
    #expect(RDPAudioInputVersionPDU(serverVersion: 3).encoded().rdpHexString == "01 02 00 00 00")
}

@Test func audioInputVersionRejectsZeroVersion() throws {
    let pdu = try RDPAudioInputPDU.parse(from: Data([
        0x01,
        0x00, 0x00, 0x00, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputVersionPDU.parseIfPresent(from: pdu)
    }
}

@Test func audioInputFormatsParsesServerFormatsAndIgnoresExtraData() throws {
    var data = Data([0x02])
    data.appendLittleEndianUInt32(1)
    data.appendLittleEndianUInt32(0x8000_0000)
    data.append(RDPAudioFormat.pcmStereo48k16Bit.encoded())
    data.append(contentsOf: [0xAA, 0xBB])

    let pdu = try RDPAudioInputPDU.parse(from: data)
    let formats = try #require(try RDPAudioInputFormatsPDU.parseIfPresent(from: pdu))

    #expect(formats.cbSizeFormatsPacket == 0x8000_0000)
    #expect(formats.formats == [.pcmStereo48k16Bit])
    #expect(formats.extraData == Data([0xAA, 0xBB]))
}

@Test func audioInputFormatsEncodesClientSubsetSizeWithoutExtraData() {
    let formats = RDPAudioInputFormatsPDU(
        formats: [.pcmStereo48k16Bit],
        extraData: Data([0xAA, 0xBB])
    )

    #expect(formats.encoded().rdpHexString == (
        "02 01 00 00 00 1b 00 00 00 "
            + "01 00 02 00 80 bb 00 00 00 ee 02 00 04 00 10 00 00 00 aa bb"
    ))
}

@Test func audioInputFormatsRejectsImpossibleFormatCountBeforeAllocating() throws {
    let pdu = try RDPAudioInputPDU.parse(from: Data([
        0x02,
        0xFF, 0xFF, 0xFF, 0x7F,
        0x00, 0x00, 0x00, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputFormatsPDU.parseIfPresent(from: pdu)
    }
}

@Test func audioInputOpenParsesRequestedCaptureFormat() throws {
    var data = Data([0x03])
    data.appendLittleEndianUInt32(480)
    data.appendLittleEndianUInt32(0)
    data.append(RDPAudioFormat.pcmStereo48k16Bit.encoded())

    let pdu = try RDPAudioInputPDU.parse(from: data)
    let open = try #require(try RDPAudioInputOpenPDU.parseIfPresent(from: pdu))

    #expect(open.framesPerPacket == 480)
    #expect(open.initialFormat == 0)
    #expect(open.format == .pcmStereo48k16Bit)
}

@Test func audioInputOpenRejectsMalformedWaveFormatExtensible() throws {
    var data = Data([0x03])
    data.appendLittleEndianUInt32(480)
    data.appendLittleEndianUInt32(0)
    data.appendLittleEndianUInt16(RDPAudioFormatTag.extensible)
    data.appendLittleEndianUInt16(2)
    data.appendLittleEndianUInt32(48000)
    data.appendLittleEndianUInt32(192_000)
    data.appendLittleEndianUInt16(4)
    data.appendLittleEndianUInt16(16)
    data.appendLittleEndianUInt16(0)

    let pdu = try RDPAudioInputPDU.parse(from: data)

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputOpenPDU.parseIfPresent(from: pdu)
    }
}

@Test func audioInputOpenValidatesWaveFormatExtensibleFields() throws {
    func openPDU(validBits: UInt16, channelMask: UInt32, subformat: Data) throws -> RDPAudioInputPDU {
        var extraData = Data()
        extraData.appendLittleEndianUInt16(validBits)
        extraData.appendLittleEndianUInt32(channelMask)
        extraData.append(subformat)
        let format = try RDPAudioFormat(
            formatTag: RDPAudioFormatTag.extensible,
            channelCount: 2,
            samplesPerSecond: 48000,
            averageBytesPerSecond: 192_000,
            blockAlign: 4,
            bitsPerSample: 16,
            extraData: extraData
        )
        var data = Data([RDPAudioInputMessageType.open])
        data.appendLittleEndianUInt32(480)
        data.appendLittleEndianUInt32(0)
        data.append(format.encoded())
        return try RDPAudioInputPDU.parse(from: data)
    }

    let pcmSubformat = Data([
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x10, 0x00,
        0x80, 0x00,
        0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ])
    let valid = try openPDU(validBits: 16, channelMask: 0x3, subformat: pcmSubformat)
    #expect(try RDPAudioInputOpenPDU.parseIfPresent(from: valid)?.format.extraData.count == 22)

    let invalidValidBits = try openPDU(validBits: 17, channelMask: 0x3, subformat: pcmSubformat)
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputOpenPDU.parseIfPresent(from: invalidValidBits)
    }

    let invalidChannelMask = try openPDU(validBits: 16, channelMask: 0x0004_0000, subformat: pcmSubformat)
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputOpenPDU.parseIfPresent(from: invalidChannelMask)
    }

    var floatSubformat = pcmSubformat
    floatSubformat[0] = 0x03
    let invalidSubformat = try openPDU(validBits: 16, channelMask: 0x3, subformat: floatSubformat)
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioInputOpenPDU.parseIfPresent(from: invalidSubformat)
    }
}

@Test func audioInputResponsePDUsEncodeSpecShapes() {
    #expect(RDPAudioInputIncomingDataPDU().encoded().rdpHexString == "05")
    #expect(RDPAudioInputFormatChangePDU(newFormat: 2).encoded().rdpHexString == "07 02 00 00 00")
    #expect(RDPAudioInputOpenReplyPDU().encoded().rdpHexString == "04 05 40 00 80")
}

@Test func audioClientFormatsEncodePCMStaticChannelHandshake() throws {
    let formats = RDPAudioFormatsPDU.clientPCM(version: 6)
    let encoded = formats.encoded()
    let parsed = try #require(try RDPAudioFormatsPDU.parseIfPresent(from: RDPAudioPDU.parse(from: encoded)))

    #expect(encoded == Data([
        0x07, 0x00, 0x26, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x01, 0x00,
        0x00,
        0x06, 0x00,
        0x00,
        0x01, 0x00,
        0x02, 0x00,
        0x80, 0xBB, 0x00, 0x00,
        0x00, 0xEE, 0x02, 0x00,
        0x04, 0x00,
        0x10, 0x00,
        0x00, 0x00,
    ]))
    #expect(parsed.flags == RDPAudioCapabilityFlags.alive | RDPAudioCapabilityFlags.volume)
    #expect(parsed.volume == 0xFFFF_FFFF)
    #expect(parsed.datagramPort == 0)
    #expect(parsed.version == 6)
    #expect(parsed.formats == [.pcmStereo48k16Bit])
}

@Test func audioClientFormatsPreferExactPCMWhenServerOffersIt() throws {
    let pcmStereo44k = try RDPAudioFormat(
        formatTag: RDPAudioFormatTag.pcm,
        channelCount: 2,
        samplesPerSecond: 44100,
        averageBytesPerSecond: 176_400,
        blockAlign: 4,
        bitsPerSample: 16
    )

    #expect(RDPAudioFormatsPDU.compatibleClientFormats(
        from: [pcmStereo44k, .pcmStereo48k16Bit]
    ) == [.pcmStereo48k16Bit])
}

@Test func audioClientFormatsUseServerPCMWhenExactFormatIsMissing() throws {
    let pcmStereo44k = try RDPAudioFormat(
        formatTag: RDPAudioFormatTag.pcm,
        channelCount: 2,
        samplesPerSecond: 44100,
        averageBytesPerSecond: 176_400,
        blockAlign: 4,
        bitsPerSample: 16
    )

    #expect(RDPAudioFormatsPDU.compatibleClientFormats(from: [pcmStereo44k]) == [pcmStereo44k])
}

@Test func audioClientFormatsDoNotInventPCMWhenServerDoesNotOfferIt() throws {
    let compressedFormat = try RDPAudioFormat(
        formatTag: 0xA106,
        channelCount: 2,
        samplesPerSecond: 44100,
        averageBytesPerSecond: 24000,
        blockAlign: 4,
        bitsPerSample: 16
    )

    #expect(RDPAudioFormatsPDU.compatibleClientFormats(
        from: [compressedFormat]
    ) == [])
}

@Test func audioClientFormatsCanEncodeEmptyCompatibleFormatList() throws {
    let formats = RDPAudioFormatsPDU(
        flags: RDPAudioCapabilityFlags.alive | RDPAudioCapabilityFlags.volume,
        volume: 0xFFFF_FFFF,
        version: 6,
        formats: []
    )
    let encoded = formats.encoded()
    let parsed = try #require(try RDPAudioFormatsPDU.parseIfPresent(from: RDPAudioPDU.parse(from: encoded)))

    #expect(encoded == Data([
        0x07, 0x00, 0x14, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
        0x06, 0x00,
        0x00,
    ]))
    #expect(parsed.formats == [])
}

@Test func audioFormatsRejectImpossibleFormatCountBeforeAllocating() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x07, 0x00, 0x14, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x01, 0x00,
        0x00,
        0x06, 0x00,
        0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioFormatsPDU.parseIfPresent(from: pdu)
    }
}

@Test func audioQualityModeEncodesHighQuality() {
    #expect(RDPAudioQualityModePDU(qualityMode: RDPAudioQualityMode.high).encoded() == Data([
        0x0C, 0x00, 0x04, 0x00,
        0x02, 0x00,
        0x00, 0x00,
    ]))
}

@Test func audioSessionWrapsStaticAudioWithoutShowProtocolFlag() throws {
    let packet = RDPAudioSession.encodedPacket(
        RDPAudioQualityModePDU().encoded(),
        userChannelID: 1006,
        staticChannelID: 1004,
        dynamicChannelID: nil
    )
    let request = try clientSendDataRequest(from: packet)
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)

    #expect(request.channelID == 1004)
    #expect(pdu.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(pdu.payload == RDPAudioQualityModePDU().encoded())
}

@Test func audioSessionWrapsDynamicAudioWithCompleteFlags() throws {
    let audioPayload = RDPAudioQualityModePDU().encoded()
    let packet = RDPAudioSession.encodedPacket(
        audioPayload,
        userChannelID: 1006,
        staticChannelID: 1004,
        dynamicChannelID: 0x1122_3344
    )
    let request = try clientSendDataRequest(from: packet)
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData)
    let dynamicPDU = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: pdu.payload))

    #expect(request.channelID == 1004)
    #expect(pdu.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(dynamicPDU.channelID == 0x1122_3344)
    #expect(dynamicPDU.payload == audioPayload)
}

@Test func audioSessionFragmentsLargeDynamicAudioPayload() throws {
    let audioPayload = Data(repeating: 0xAB, count: 2_000)
    let packets = RDPAudioSession.encodedPackets(
        audioPayload,
        userChannelID: 1006,
        staticChannelID: 1004,
        dynamicChannelID: 7
    )
    let firstRequest = try clientSendDataRequest(from: packets[0])
    let secondRequest = try clientSendDataRequest(from: packets[1])
    let firstStaticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: firstRequest.userData)
    let secondStaticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: secondRequest.userData)
    let firstDynamicPDU = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
        from: firstStaticPDU.payload
    ))
    let secondDynamicPDU = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(
        from: secondStaticPDU.payload
    ))

    #expect(packets.count == 2)
    #expect(firstStaticPDU.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(secondStaticPDU.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(firstDynamicPDU.totalLength == 2_000)
    #expect(firstDynamicPDU.payload.count == 1_596)
    #expect(secondDynamicPDU.payload.count == 404)
}

@Test func audioTrainingConfirmEchoesServerTimestampAndPacketSize() throws {
    let serverTraining = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x08, 0x00,
        0x34, 0x12,
        0x0c, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ]))
    let training = try #require(try RDPAudioTrainingPDU.parseIfPresent(from: serverTraining))

    #expect(training.timestamp == 0x1234)
    #expect(training.packetSize == 12)
    #expect(training.confirmEncoded() == Data([
        0x06, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x0c, 0x00,
    ]))
}

@Test func audioTrainingAcceptsZeroPacketSizeWhenNoTrainingDataIsPresent() throws {
    let serverTraining = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x00, 0x00,
    ]))
    let training = try #require(try RDPAudioTrainingPDU.parseIfPresent(from: serverTraining))

    #expect(training.timestamp == 0x1234)
    #expect(training.packetSize == 0)
}

@Test func audioTrainingAcceptsNoDataProbeWithNonzeroPacketSize() throws {
    let serverTraining = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x08, 0x00,
    ]))
    let training = try #require(try RDPAudioTrainingPDU.parseIfPresent(from: serverTraining))

    #expect(training.timestamp == 0x1234)
    #expect(training.packetSize == 8)
}

@Test func audioTrainingAcceptsDataLengthPacketSizeConvention() throws {
    let serverTraining = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x08, 0x00,
        0x34, 0x12,
        0x04, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ]))
    let training = try #require(try RDPAudioTrainingPDU.parseIfPresent(from: serverTraining))

    #expect(training.timestamp == 0x1234)
    #expect(training.packetSize == 4)
}

@Test func audioTrainingRejectsPacketSizeInconsistentWithAcceptedLengthConventions() throws {
    let nonEmptyDataWithZeroPacketSize = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x08, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ]))
    let nonEmptyDataWithUnexpectedPacketSize = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x08, 0x00,
        0x34, 0x12,
        0x08, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioTrainingPDU.parseIfPresent(from: nonEmptyDataWithZeroPacketSize)
    }
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioTrainingPDU.parseIfPresent(from: nonEmptyDataWithUnexpectedPacketSize)
    }
}

@Test func audioWaveInfoUsesHeaderBodySizeForFollowingWaveData() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x02, 0x00, 0x10, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0x7A,
        0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04,
    ]))
    let waveInfo = try #require(try RDPAudioWaveInfoPDU.parseIfPresent(from: pdu))

    #expect(waveInfo.timestamp == 0x1234)
    #expect(waveInfo.formatNo == 0)
    #expect(waveInfo.blockNo == 0x7A)
    #expect(waveInfo.initialAudioData == Data([0x01, 0x02, 0x03, 0x04]))
    #expect(waveInfo.expectedWaveDataByteCount == 4)
}

@Test func audioWaveInfoRejectsTrailingBytesInFirstPacket() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x02, 0x00, 0x10, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0x7A,
        0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0x05,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioWaveInfoPDU.parseIfPresent(from: pdu)
    }
}

@Test func audioWaveDataSkipsPadAndReturnsRemainingAudioBytes() throws {
    let waveData = try RDPAudioWaveDataPDU.parse(from: Data([
        0x00, 0x00, 0x00, 0x00,
        0x05, 0x06, 0x07, 0x08,
    ]))

    #expect(waveData.data == Data([0x05, 0x06, 0x07, 0x08]))
}

@Test func audioWaveDataRejectsNonzeroPad() {
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try RDPAudioWaveDataPDU.parse(from: Data([
            0x01, 0x00, 0x00, 0x00,
            0x05, 0x06, 0x07, 0x08,
        ]))
    }
}

@Test func audioWave2ParsesPCMMetadataAndPayload() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x0D, 0x00, 0x10, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0x7A,
        0x00, 0x00, 0x00,
        0x78, 0x56, 0x34, 0x12,
        0x01, 0x02, 0x03, 0x04,
    ]))
    let wave2 = try #require(try RDPAudioWave2PDU.parseIfPresent(from: pdu))

    #expect(wave2.timestamp == 0x1234)
    #expect(wave2.formatNo == 0)
    #expect(wave2.blockNo == 0x7A)
    #expect(wave2.audioTimestamp == 0x1234_5678)
    #expect(wave2.data == Data([0x01, 0x02, 0x03, 0x04]))
}

@Test func audioSessionEnforcesNegotiatedVirtualChannelWaveVersion() throws {
    let channel = EmbeddedChannel()
    let session = RDPAudioSession(userChannelID: 1006, staticChannelID: 1004, channel: channel)
    let waveInfo = try RDPAudioPDU.parse(from: Data([
        0x02, 0x00, 0x10, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0x7A,
        0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04,
    ]))
    let wave2 = try RDPAudioPDU.parse(from: Data([
        0x0D, 0x00, 0x10, 0x00,
        0x34, 0x12,
        0x00, 0x00,
        0x7A,
        0x00, 0x00, 0x00,
        0x78, 0x56, 0x34, 0x12,
        0x01, 0x02, 0x03, 0x04,
    ]))

    session.respondToServerFormats(RDPAudioFormatsPDU(
        flags: 0,
        version: 7,
        formats: [.pcmStereo48k16Bit]
    ))
    #expect(try session.receive(waveInfo, receivedAt: Date()) == nil)
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try session.receive(wave2, receivedAt: Date())
    }

    _ = try session.receiveWaveData(
        Data([0x00, 0x00, 0x00, 0x00, 0x05, 0x06, 0x07, 0x08]),
        receivedAt: Date()
    )
    session.respondToServerFormats(RDPAudioFormatsPDU(
        flags: 0,
        version: 8,
        formats: [.pcmStereo48k16Bit]
    ))
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        try session.receive(waveInfo, receivedAt: Date())
    }
    #expect(try session.receive(wave2, receivedAt: Date())?.data == Data([0x01, 0x02, 0x03, 0x04]))

    _ = try channel.finish()
}

@Test func audioWaveConfirmEncodesTimestampAndBlockNumber() {
    #expect(RDPAudioWaveConfirmPDU(timestamp: 0x1234, blockNo: 0x7A).encoded() == Data([
        0x05, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x7A,
        0x00,
    ]))
}

@Test func audioVolumeParsesChannelVolume() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x03, 0x99, 0x04, 0x00,
        0x00, 0x80, 0xFF, 0xFF,
    ]))
    let volume = try #require(try RDPAudioVolumePDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "audio-volume")
    #expect(volume.volume == 0xFFFF_8000)
}

@Test func audioPitchParsesFixedPointMultiplier() throws {
    let pdu = try RDPAudioPDU.parse(from: Data([
        0x04, 0x99, 0x04, 0x00,
        0x00, 0x80, 0x0F, 0x00,
    ]))
    let pitch = try #require(try RDPAudioPitchPDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "audio-pitch")
    #expect(pitch.pitch == 0x000F_8000)
}

@Test func audioVolumeAndPitchRejectInvalidPayloadLength() throws {
    let invalidVolume = try RDPAudioPDU.parse(from: Data([
        0x03, 0x00, 0x03, 0x00,
        0x00, 0x80, 0xFF,
    ]))
    let invalidPitch = try RDPAudioPDU.parse(from: Data([
        0x04, 0x00, 0x05, 0x00,
        0x00, 0x80, 0x0F, 0x00, 0x00,
    ]))

    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        _ = try RDPAudioVolumePDU.parseIfPresent(from: invalidVolume)
    }
    #expect(throws: RDPDecodeError.invalidAudioPDU) {
        _ = try RDPAudioPitchPDU.parseIfPresent(from: invalidPitch)
    }
}

@MainActor
@Test func audioPlayerReportsReadyAfterReset() {
    let player = RDPAudioPlayer()

    #expect(player.statusMessage == "Ready.")

    player.reset()

    #expect(player.statusMessage == "Ready.")
}

@MainActor
@Test func audioPlayerRejectsUnsupportedFormatsBeforeStartingEngine() throws {
    let player = RDPAudioPlayer()
    let sample = RDPAudioSample(
        format: try RDPAudioFormat(
            formatTag: RDPAudioFormatTag.pcm,
            channelCount: 2,
            samplesPerSecond: 48000,
            averageBytesPerSecond: 96_000,
            blockAlign: 2,
            bitsPerSample: 8
        ),
        timestamp: 0,
        blockNo: 0,
        data: Data([0x00, 0x00]),
        receivedAt: Date()
    )

    #expect(throws: RDPAudioPlayerError.unsupportedFormat) {
        try player.enqueue(sample)
    }
}

@MainActor
@Test func audioPlayerDropsEmptyPCMSamplesBeforeStartingEngine() throws {
    let player = RDPAudioPlayer()
    let sample = RDPAudioSample(
        format: .pcmStereo48k16Bit,
        timestamp: 0,
        blockNo: 0,
        data: Data(),
        receivedAt: Date()
    )

    #expect(try player.enqueue(sample) == false)
    #expect(player.statusMessage == "Ready.")
}

private func clientSendDataRequest(from packet: Data) throws -> (channelID: UInt16, userData: Data) {
    var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
    let header = try cursor.readUInt8()
    _ = try cursor.readBigEndianUInt16()
    let channelID = try cursor.readBigEndianUInt16()
    let priority = try cursor.readUInt8()
    let length = try cursor.readPERLength()
    let userData = try cursor.readData(count: length)
    guard header == 0x64, priority == 0x70, cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSSendDataIndication
    }
    return (channelID: channelID, userData: userData)
}
