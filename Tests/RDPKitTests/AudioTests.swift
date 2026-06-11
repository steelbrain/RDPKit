import Foundation
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

@Test func audioClientFormatsEncodePCMStaticChannelHandshake() throws {
    let formats = RDPAudioFormatsPDU.clientPCM(version: 6)
    let encoded = formats.encoded()
    let parsed = try #require(try RDPAudioFormatsPDU.parseIfPresent(from: RDPAudioPDU.parse(from: encoded)))

    #expect(encoded == Data([
        0x07, 0x00, 0x26, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
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
    #expect(parsed.flags == RDPAudioCapabilityFlags.alive)
    #expect(parsed.datagramPort == 0)
    #expect(parsed.version == 6)
    #expect(parsed.formats == [.pcmStereo48k16Bit])
}

@Test func audioQualityModeEncodesDynamicQuality() {
    #expect(RDPAudioQualityModePDU().encoded() == Data([
        0x0C, 0x00, 0x04, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ]))
}

@Test func audioTrainingConfirmEchoesServerTimestampAndPacketSize() throws {
    let serverTraining = try RDPAudioPDU.parse(from: Data([
        0x06, 0x00, 0x08, 0x00,
        0x34, 0x12,
        0x08, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ]))
    let training = try #require(try RDPAudioTrainingPDU.parseIfPresent(from: serverTraining))

    #expect(training.timestamp == 0x1234)
    #expect(training.packetSize == 8)
    #expect(training.confirmEncoded() == Data([
        0x06, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x08, 0x00,
    ]))
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

@Test func audioWaveDataSkipsPadAndReturnsRemainingAudioBytes() throws {
    let waveData = try RDPAudioWaveDataPDU.parse(from: Data([
        0x00, 0x00, 0x00, 0x00,
        0x05, 0x06, 0x07, 0x08,
    ]))

    #expect(waveData.data == Data([0x05, 0x06, 0x07, 0x08]))
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

@Test func audioWaveConfirmEncodesTimestampAndBlockNumber() {
    #expect(RDPAudioWaveConfirmPDU(timestamp: 0x1234, blockNo: 0x7A).encoded() == Data([
        0x05, 0x00, 0x04, 0x00,
        0x34, 0x12,
        0x7A,
        0x00,
    ]))
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
