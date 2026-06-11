import Foundation
@testable import RDPKit
import Testing

@Test func encodesRDPGFXCapsAdvertiseWithAVC420Version81() {
    let advertise = RDPGFXCapsAdvertisePDU()

    #expect(advertise.encoded().rdpHexString == """
    12 00 00 00 16 00 00 00 01 00 05 01 08 00 04 00 00 00 12 00 00 00
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func parsesRDPGFXHeaderAndCapsConfirm() throws {
    let bytes = Data([
        0x13, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
    ])

    let header = try RDPGFXHeader.parse(from: bytes)
    let confirm = try #require(try RDPGFXCapsConfirmPDU.parseIfPresent(from: bytes))

    #expect(header.commandID == RDPGFXCommandID.capsConfirm)
    #expect(header.typeName == "rdpgfx-caps-confirm")
    #expect(confirm.capabilitySet.version == RDPGFXCapabilityVersion.version81)
    #expect(confirm.capabilitySet.data == Data([0x12, 0x00, 0x00, 0x00]))
}

@Test func decodesUncompressedSingleSegmentServerTransport() throws {
    let bytes = Data([
        0xE0, 0x04,
        0x13, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
    ])

    let messages = try RDPGFXServerTransport.decodeGraphicsMessages(from: bytes)

    #expect(messages.count == 1)
    #expect(messages.first?.typeName == "rdpgfx-caps-confirm")
    #expect(try RDPGFXCapabilitySet.parse(from: messages[0].payload).flags == 0x12)
}

@Test func decodesUncompressedServerTransportFromDataSlice() throws {
    let packet = Data([
        0xFF, 0xFF,
        0xE0, 0x04,
        0x13, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
    ])

    let messages = try RDPGFXServerTransport.decodeGraphicsMessages(from: packet.dropFirst(2))

    #expect(messages.count == 1)
    #expect(messages.first?.typeName == "rdpgfx-caps-confirm")
}

@Test func decodesUncompressedMultipartServerTransport() throws {
    let message = Data([
        0x13, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
    ])
    let first = message.prefix(10)
    let second = message.dropFirst(10)
    var bytes = Data([0xE1])
    bytes.appendLittleEndianUInt16(2)
    bytes.appendLittleEndianUInt32(UInt32(message.count))
    bytes.appendLittleEndianUInt32(UInt32(first.count + 1))
    bytes.appendUInt8(0x04)
    bytes.append(first)
    bytes.appendLittleEndianUInt32(UInt32(second.count + 1))
    bytes.appendUInt8(0x04)
    bytes.append(second)

    let messages = try RDPGFXServerTransport.decodeGraphicsMessages(from: bytes)

    #expect(messages.count == 1)
    #expect(messages.first?.typeName == "rdpgfx-caps-confirm")
}

@Test func wrapsRDPGFXCapsAdvertiseInDynamicChannelData() {
    let graphicsPayload = RDPGFXCapsAdvertisePDU().encoded()
    let dynamicPayload = RDPDynamicVirtualChannelDataPDU(
        channelID: 7,
        payload: graphicsPayload
    ).encoded()

    #expect(dynamicPayload.starts(with: Data([0x30, 0x07])))
    #expect(dynamicPayload.dropFirst(2) == graphicsPayload)
}

@Test func summarizesSurfaceAndFrameGraphicsMessages() throws {
    let createSurface = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: Data([
        0x09, 0x00, 0x00, 0x00,
        0x0F, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x80, 0x02,
        0xD0, 0x01,
        0x20,
    ])))
    let startFrame = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: Data([
        0x0B, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x2A, 0x00, 0x00, 0x00,
    ])))
    let endFrame = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: Data([
        0x0C, 0x00, 0x00, 0x00,
        0x0C, 0x00, 0x00, 0x00,
        0x2A, 0x00, 0x00, 0x00,
    ])))

    #expect(createSurface.typeName == "rdpgfx-create-surface")
    #expect(createSurface.surfaceID == 1)
    #expect(createSurface.width == 640)
    #expect(createSurface.height == 464)
    #expect(createSurface.pixelFormat == 0x20)
    #expect(startFrame.frameID == 42)
    #expect(endFrame.frameID == 42)
}

@Test func summarizesAVC420WireToSurface1Message() throws {
    let message = try RDPGFXHeader.parse(from: Data([
        0x01, 0x00, 0x00, 0x00,
        0x1C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x0B, 0x00,
        0x20,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x05,
        0xD0, 0x02,
        0x03, 0x00, 0x00, 0x00,
        0xAA, 0xBB, 0xCC,
    ]))

    let summary = try RDPGFXMessageSummary.summarize(message)

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.surfaceID == 1)
    #expect(summary.codecID == RDPGFXCodecID.avc420)
    #expect(summary.codecName == "avc420")
    #expect(summary.pixelFormat == 0x20)
    #expect(summary.bitmapDataLength == 3)
}

@Test func parsesAVC420BitmapStreamAndNALUnitTypes() throws {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(64)
    bitmapData.appendLittleEndianUInt16(32)
    bitmapData.appendUInt8(26)
    bitmapData.appendUInt8(90)
    bitmapData.append(Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x1F,
        0x00, 0x00, 0x01, 0x68, 0xEE, 0x3C, 0x80,
        0x00, 0x00, 0x01, 0x65, 0x88,
    ]))

    let stream = try RDPGFXAVC420BitmapStream.parse(from: bitmapData)

    #expect(stream.regionRects == [RDPGFXRect16(left: 0, top: 0, right: 64, bottom: 32)])
    #expect(stream.quantQualityVals == [RDPGFXAVC420QuantQuality(qpVal: 26, qualityVal: 90)])
    #expect(stream.nalUnitTypes == [7, 8, 5])
}

@Test func parsesHEVCAnnexBNALUnitTypes() {
    let bitstream = Data([
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x01, 0x44, 0x01,
        0x00, 0x00, 0x01, 0x26, 0x01,
    ])

    let units = RDPHEVCAnnexB.nalUnits(from: bitstream)

    #expect(units.map(\.type) == [32, 33, 34, 19])
    #expect(RDPHEVCAnnexB.nalUnitTypes(from: bitstream) == [32, 33, 34, 19])
}

@Test func preparesHEVCAnnexBSampleWithLengthPrefixesAndParameterSets() {
    let bitstream = Data([
        0xFF,
        0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x01, 0x44, 0x01,
        0x00, 0x00, 0x01, 0x26, 0x01, 0x99,
    ])

    let sample = RDPHEVCAnnexB.sample(from: bitstream)

    #expect(sample.videoParameterSet == Data([0x40, 0x01]))
    #expect(sample.sequenceParameterSet == Data([0x42, 0x01]))
    #expect(sample.pictureParameterSet == Data([0x44, 0x01]))
    #expect(sample.lengthPrefixedData == Data([
        0x00, 0x00, 0x00, 0x02, 0x40, 0x01,
        0x00, 0x00, 0x00, 0x02, 0x42, 0x01,
        0x00, 0x00, 0x00, 0x02, 0x44, 0x01,
        0x00, 0x00, 0x00, 0x03, 0x26, 0x01, 0x99,
    ]))
}

@Test func parsesAnnexBPayloadsWithMixedStartCodesAndLeadingBytes() {
    let bitstream = Data([
        0xFF,
        0x00, 0x00, 0x01, 0x67, 0x64,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
    ])

    let payloads = RDPAnnexB.nalUnitPayloads(from: bitstream)

    #expect(payloads == [
        Data([0x67, 0x64]),
        Data([0x65, 0x88, 0x84]),
    ])
    #expect(RDPH264AnnexB.nalUnitTypes(from: bitstream) == [7, 5])
}

@Test func preparesH264AnnexBSampleWithLengthPrefixesAndParameterSets() {
    let bitstream = Data([
        0xFF,
        0x00, 0x00, 0x01, 0x67, 0x64,
        0x00, 0x00, 0x00, 0x01, 0x68, 0xEE,
        0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
    ])

    let sample = RDPH264AnnexB.sample(from: bitstream)

    #expect(sample.sequenceParameterSet == Data([0x67, 0x64]))
    #expect(sample.pictureParameterSet == Data([0x68, 0xEE]))
    #expect(RDPH264AnnexB.nalUnitTypes(from: bitstream) == [7, 8, 5])
    #expect(sample.lengthPrefixedData == Data([
        0x00, 0x00, 0x00, 0x02, 0x67, 0x64,
        0x00, 0x00, 0x00, 0x02, 0x68, 0xEE,
        0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84,
    ]))
}

@Test func parsesAVC444BitmapStreamWithBothSubframes() throws {
    let yuv420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x67]),
        Data([0x00, 0x00, 0x01, 0x65]),
    ])
    let chroma420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x68]),
        Data([0x00, 0x00, 0x01, 0x41]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(yuv420.count))
    bitmapData.append(yuv420)
    bitmapData.append(chroma420)

    let stream = try RDPGFXAVC444BitmapStream.parse(from: bitmapData)

    #expect(stream.layoutCode == .yuv420AndChroma420)
    #expect(stream.firstStreamByteCount == UInt32(yuv420.count))
    #expect(stream.yuv420Stream?.nalUnitTypes == [7, 5])
    #expect(stream.chroma420Stream?.nalUnitTypes == [8, 1])
    #expect(stream.nalUnitTypes == [7, 5, 8, 1])
}

@Test func parsesAVC444BitmapStreamWithLumaOnlySubframe() throws {
    let yuv420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x65]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(yuv420.count) | UInt32(RDPGFXAVC444LayoutCode.yuv420Only.rawValue) << 30)
    bitmapData.append(yuv420)

    let stream = try RDPGFXAVC444BitmapStream.parse(from: bitmapData)

    #expect(stream.layoutCode == .yuv420Only)
    #expect(stream.yuv420Stream?.nalUnitTypes == [5])
    #expect(stream.chroma420Stream == nil)
}

@Test func parsesAVC444BitmapStreamWithChromaOnlySubframe() throws {
    let chroma420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x41]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(RDPGFXAVC444LayoutCode.chroma420Only.rawValue) << 30)
    bitmapData.append(chroma420)

    let stream = try RDPGFXAVC444BitmapStream.parse(from: bitmapData)

    #expect(stream.layoutCode == .chroma420Only)
    #expect(stream.yuv420Stream == nil)
    #expect(stream.chroma420Stream?.nalUnitTypes == [1])
}

@Test func rejectsAVC444BitmapStreamWithInvalidLayoutCode() {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(3) << 30)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXAVC444BitmapStream.parse(from: bitmapData)
    }
}

@Test func summarizesAVC420MetadataFromWireToSurface1Message() throws {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendUInt8(24)
    bitmapData.appendUInt8(80)
    bitmapData.append(Data([
        0x00, 0x00, 0x01, 0x67,
        0x00, 0x00, 0x01, 0x68,
        0x00, 0x00, 0x01, 0x41,
    ]))

    var bytes = Data([
        0x01, 0x00, 0x00, 0x00,
    ])
    bytes.appendLittleEndianUInt32(UInt32(8 + 17 + bitmapData.count))
    bytes.appendLittleEndianUInt16(3)
    bytes.appendLittleEndianUInt16(RDPGFXCodecID.avc420)
    bytes.appendUInt8(0x20)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt32(UInt32(bitmapData.count))
    bytes.append(bitmapData)

    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: bytes))

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.avc420RegionCount == 1)
    #expect(summary.avc420EncodedBitstreamLength == 12)
    #expect(summary.h264NalUnitTypes == [7, 8, 1])
}

@Test func canSummarizeAVC420MessageWithoutVideoDetails() throws {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendUInt8(24)
    bitmapData.appendUInt8(80)
    bitmapData.append(Data([
        0x00, 0x00, 0x01, 0x67,
        0x00, 0x00, 0x01, 0x68,
        0x00, 0x00, 0x01, 0x41,
    ]))

    var bytes = Data([
        0x01, 0x00, 0x00, 0x00,
    ])
    bytes.appendLittleEndianUInt32(UInt32(8 + 17 + bitmapData.count))
    bytes.appendLittleEndianUInt16(3)
    bytes.appendLittleEndianUInt16(RDPGFXCodecID.avc420)
    bytes.appendUInt8(0x20)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt32(UInt32(bitmapData.count))
    bytes.append(bitmapData)

    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: bytes),
        includeVideoDetails: false
    )

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.codecName == "avc420")
    #expect(summary.bitmapDataLength == UInt32(bitmapData.count))
    #expect(summary.avc420RegionCount == nil)
    #expect(summary.avc420EncodedBitstreamLength == nil)
    #expect(summary.h264NalUnitTypes == nil)
}

@Test func summarizesAVC444MetadataFromWireToSurface1Message() throws {
    let yuv420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x67]),
        Data([0x00, 0x00, 0x01, 0x65]),
    ])
    let chroma420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x68]),
        Data([0x00, 0x00, 0x01, 0x41]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(yuv420.count))
    bitmapData.append(yuv420)
    bitmapData.append(chroma420)

    var bytes = Data([
        0x01, 0x00, 0x00, 0x00,
    ])
    bytes.appendLittleEndianUInt32(UInt32(8 + 17 + bitmapData.count))
    bytes.appendLittleEndianUInt16(3)
    bytes.appendLittleEndianUInt16(RDPGFXCodecID.avc444)
    bytes.appendUInt8(0x20)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt32(UInt32(bitmapData.count))
    bytes.append(bitmapData)

    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: bytes))

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.codecName == "avc444")
    #expect(summary.avc444Layout == "yuv420+chroma420")
    #expect(summary.avc444FirstStreamByteCount == UInt32(yuv420.count))
    #expect(summary.avc444YUV420RegionCount == 1)
    #expect(summary.avc444YUV420EncodedBitstreamLength == 8)
    #expect(summary.avc444Chroma420RegionCount == 1)
    #expect(summary.avc444Chroma420EncodedBitstreamLength == 8)
    #expect(summary.h264NalUnitTypes == [7, 5, 8, 1])
}

@Test func frameAcknowledgeEncodesQueueDepthFrameAndCount() {
    let acknowledge = RDPGFXFrameAcknowledgePDU(
        frameID: 42,
        totalFramesDecoded: 1
    )

    #expect(acknowledge.encoded().rdpHexString == """
    0d 00 00 00 14 00 00 00 00 00 00 00 2a 00 00 00 01 00 00 00
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func avc420BitmapStream(nalUnits: [Data]) -> Data {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(0)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendLittleEndianUInt16(16)
    bitmapData.appendUInt8(24)
    bitmapData.appendUInt8(80)
    for nalUnit in nalUnits {
        bitmapData.append(nalUnit)
    }
    return bitmapData
}
