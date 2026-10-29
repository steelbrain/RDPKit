import AVFoundation
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

@Test func audioFormatWithOverflowingBlockAlignIsNotPCM16BitInsteadOfTrapping() throws {
    let hostile = try RDPAudioFormat(
        formatTag: RDPAudioFormatTag.pcm,
        channelCount: 0x8000,
        samplesPerSecond: 48000,
        averageBytesPerSecond: 0,
        blockAlign: 0,
        bitsPerSample: 16
    )

    #expect(hostile.isPCM16Bit == false)
    #expect(RDPAudioFormatsPDU.compatibleClientFormats(from: [hostile]) == [])
}

@Test func audioClientFormatsEncodePCMStaticChannelHandshake() throws {
    let formats = RDPAudioFormatsPDU.client(version: 6, formats: [.pcmStereo48k16Bit])
    let encoded = formats.encoded()
    let parsed = try #require(try RDPAudioFormatsPDU.parseIfPresent(from: RDPAudioPDU.parse(from: encoded)))

    #expect(encoded == Data([
        0x07, 0x00, 0x26, 0x00,
        0x01, 0x00, 0x00, 0x00,
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
    // No TSSNDCAPS_VOLUME: the client does not apply Volume PDUs (MS-RDPEA 3.2.5.3.1.1).
    #expect(parsed.flags == RDPAudioCapabilityFlags.alive)
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

@Test func audioClientFormatsSkipPCMFormatsCarryingExtraData() throws {
    let pcmWithExtraData = try RDPAudioFormat(
        formatTag: RDPAudioFormatTag.pcm,
        channelCount: 2,
        samplesPerSecond: 48000,
        averageBytesPerSecond: 192_000,
        blockAlign: 4,
        bitsPerSample: 16,
        extraData: Data(count: 2_000)
    )
    let pcmMono = try RDPAudioFormat(
        formatTag: RDPAudioFormatTag.pcm,
        channelCount: 1,
        samplesPerSecond: 22050,
        averageBytesPerSecond: 44100,
        blockAlign: 2,
        bitsPerSample: 16
    )

    #expect(RDPAudioFormatsPDU.compatibleClientFormats(from: [pcmWithExtraData, pcmMono]) == [pcmMono])
}

@Test func audioClientFormatsSkipPCMFormatsAudioEngineCannotPlay() throws {
    func pcm(channelCount: UInt16, samplesPerSecond: UInt32) throws -> RDPAudioFormat {
        try RDPAudioFormat(
            formatTag: RDPAudioFormatTag.pcm,
            channelCount: channelCount,
            samplesPerSecond: samplesPerSecond,
            averageBytesPerSecond: samplesPerSecond * UInt32(channelCount) * 2,
            blockAlign: channelCount * 2,
            bitsPerSample: 16
        )
    }
    let unplayable = [
        try pcm(channelCount: 2, samplesPerSecond: 10_000_000),
        try pcm(channelCount: 2, samplesPerSecond: 1),
        try pcm(channelCount: 6, samplesPerSecond: 48000),
    ]
    let mono8k = try pcm(channelCount: 1, samplesPerSecond: 8000)

    #expect(RDPAudioFormatsPDU.compatibleClientFormats(from: unplayable) == [])
    #expect(RDPAudioFormatsPDU.compatibleClientFormats(from: unplayable + [mono8k]) == [mono8k])
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
    let packets = RDPAudioSession.encodedPackets(
        RDPAudioQualityModePDU().encoded(),
        userChannelID: 1006,
        staticChannelID: 1004,
        dynamicChannelID: nil
    )
    #expect(packets.count == 1)
    let request = try mcsSendDataRequest(fromTPKT: packets[0])
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)

    #expect(request.channelID == 1004)
    #expect(pdu.flags == RDPStaticVirtualChannelFlags.complete)
    #expect(pdu.payload == RDPAudioQualityModePDU().encoded())
}

@Test func audioSessionWrapsDynamicAudioWithCompleteFlags() throws {
    let audioPayload = RDPAudioQualityModePDU().encoded()
    let packets = RDPAudioSession.encodedPackets(
        audioPayload,
        userChannelID: 1006,
        staticChannelID: 1004,
        dynamicChannelID: 0x1122_3344
    )
    #expect(packets.count == 1)
    let request = try mcsSendDataRequest(fromTPKT: packets[0])
    let pdu = try RDPStaticVirtualChannelPDU.parse(fromUserData: request.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)
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
    let firstRequest = try mcsSendDataRequest(fromTPKT: packets[0])
    let secondRequest = try mcsSendDataRequest(fromTPKT: packets[1])
    let firstStaticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: firstRequest.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)
    let secondStaticPDU = try RDPStaticVirtualChannelPDU.parse(fromUserData: secondRequest.userData, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount)
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
@Test func audioPlayerRejectsAbsurdSampleRateBeforeConfiguringEngine() throws {
    let player = RDPAudioPlayer()
    let sample = RDPAudioSample(
        format: try RDPAudioFormat(
            formatTag: RDPAudioFormatTag.pcm,
            channelCount: 2,
            samplesPerSecond: 10_000_000,
            averageBytesPerSecond: 40_000_000,
            blockAlign: 4,
            bitsPerSample: 16
        ),
        timestamp: 0,
        blockNo: 0,
        data: Data(count: 4),
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

/// An audio interruption or output device change stops the engine with buffers still queued;
/// they never drain, so they must not keep every later sample out of the queue.
@MainActor
@Test func audioPlayerResumesAfterTheEngineStopsWithAFullQueue() throws {
    let player = RDPAudioPlayer()
    // Offline manual rendering starts without an audio device and never drains the queue.
    let renderFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    try player.engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
    let sample = RDPAudioSample(
        format: .pcmStereo48k16Bit,
        timestamp: 0,
        blockNo: 0,
        data: Data(count: 4 * 2_400),
        receivedAt: Date()
    )

    var acceptedCount = 0
    while acceptedCount < 32, try player.enqueue(sample) {
        acceptedCount += 1
    }
    #expect(acceptedCount == 16)

    player.engine.stop()

    #expect(try player.enqueue(sample))
    #expect(player.engine.isRunning)
    player.reset()
}
