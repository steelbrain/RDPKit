import Foundation
@testable import RDPKit
import Testing

@Test func encodesRDPGFXCapsAdvertiseWithAVCThinClientFallbacks() {
    let advertise = RDPGFXCapsAdvertisePDU()

    #expect(advertise.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version107,
        RDPGFXCapabilityVersion.version81,
        RDPGFXCapabilityVersion.version8,
    ])
    #expect(advertise.capabilitySets.map(\.flags) == [
        RDPGFXCapabilityFlags.defaultVersion107,
        RDPGFXCapabilityFlags.defaultVersion81,
        RDPGFXCapabilityFlags.defaultVersion8,
    ])
    #expect(advertise.encoded().rdpHexString == """
    12 00 00 00 2e 00 00 00 03 00 01 07 0a 00 04 00 00 00 c2 00 00 00 05 01 08 00 04 00 00 00 13 00 00 00 04 00 08 00 04 00 00 00 03 00 00 00
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func parsesRDPGFXCapsAdvertiseCapabilitySets() throws {
    let advertise = RDPGFXCapsAdvertisePDU(
        capabilitySets: RDPGraphicsCapabilityProfile.automatic.capabilitySets
    )

    let parsed = try #require(try RDPGFXCapsAdvertisePDU.parseIfPresent(from: advertise.encoded()))

    #expect(parsed == advertise)
}

@Test func graphicsCapabilityProfilesSelectExpectedCapsets() {
    #expect(RDPGraphicsCapabilityProfile.automatic.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version107,
        RDPGFXCapabilityVersion.version81,
        RDPGFXCapabilityVersion.version8,
    ])
    #expect(RDPGraphicsCapabilityProfile.avcThinClient.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version107,
    ])
    #expect(RDPGraphicsCapabilityProfile.avc420.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version81,
    ])
    #expect(RDPGraphicsCapabilityProfile.legacy.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version8,
    ])
    #expect(RDPGraphicsCapabilityProfile.avc420.capabilitySets.map(\.flags) == [
        RDPGFXCapabilityFlags.defaultVersion81,
    ])
    #expect(RDPGraphicsCapabilityProfile.legacy.capabilitySets.map(\.flags) == [
        RDPGFXCapabilityFlags.defaultVersion8,
    ])
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
    #expect(messages[0].payload.rdpHexString == "05 01 08 00 04 00 00 00 12 00 00 00")
}

@Test func decodesCompressedSingleSegmentServerTransport() throws {
    let bytes = Data([
        0xE0, 0x24,
        0x09, 0xE3, 0x18, 0x0A,
        0x44, 0x8D, 0xF9, 0xE5,
        0x8D, 0xD1, 0x43, 0x4C,
        0x63, 0x00, 0x05,
    ])

    let messages = try RDPGFXServerTransport.decodeGraphicsMessages(from: bytes)

    #expect(messages.count == 1)
    #expect(messages.first?.typeName == "rdpgfx-caps-confirm")
    #expect(messages[0].payload.rdpHexString == "05 01 08 00 04 00 00 00 02 00 00 00")
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

@Test func summarizesSurfaceCacheAndFillGraphicsMessages() throws {
    var solidFillPayload = Data()
    solidFillPayload.appendLittleEndianUInt16(3)
    solidFillPayload.append(contentsOf: [0x10, 0x20, 0x30, 0x40])
    solidFillPayload.appendLittleEndianUInt16(2)
    solidFillPayload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    solidFillPayload.append(rectangleBytes(left: 19, top: 20, right: 31, bottom: 32))
    let solidFill = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.solidFill, payload: solidFillPayload))
    )

    var surfaceToCachePayload = Data()
    surfaceToCachePayload.appendLittleEndianUInt16(3)
    surfaceToCachePayload.appendLittleEndianUInt64(0x0102_0304_0506_0708)
    surfaceToCachePayload.appendLittleEndianUInt16(9)
    surfaceToCachePayload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    let surfaceToCache = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.surfaceToCache, payload: surfaceToCachePayload))
    )

    var cacheToSurfacePayload = Data()
    cacheToSurfacePayload.appendLittleEndianUInt16(9)
    cacheToSurfacePayload.appendLittleEndianUInt16(3)
    cacheToSurfacePayload.appendLittleEndianUInt16(2)
    cacheToSurfacePayload.append(pointBytes(x: 5, y: 6))
    cacheToSurfacePayload.append(pointBytes(x: 7, y: 8))
    let cacheToSurface = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.cacheToSurface, payload: cacheToSurfacePayload))
    )

    #expect(solidFill.typeName == "rdpgfx-solid-fill")
    #expect(solidFill.surfaceID == 3)
    #expect(solidFill.fillColor == "#302010")
    #expect(solidFill.fillRectCount == 2)
    #expect(surfaceToCache.typeName == "rdpgfx-surface-to-cache")
    #expect(surfaceToCache.surfaceID == 3)
    #expect(surfaceToCache.cacheKey == 0x0102_0304_0506_0708)
    #expect(surfaceToCache.cacheSlot == 9)
    #expect(surfaceToCache.sourceRect == RDPFrameRect(left: 1, top: 2, right: 17, bottom: 18))
    #expect(cacheToSurface.typeName == "rdpgfx-cache-to-surface")
    #expect(cacheToSurface.surfaceID == 3)
    #expect(cacheToSurface.cacheSlot == 9)
    #expect(cacheToSurface.destinationPointCount == 2)
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

@Test func summarizesCAPROGRESSIVEWireToSurface2Message() throws {
    let progressiveStream = caprogressiveBitmapStream()
    var payload = Data()
    payload.appendLittleEndianUInt16(7)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.caProgressive)
    payload.appendLittleEndianUInt32(12)
    payload.appendUInt8(0x20)
    payload.appendLittleEndianUInt32(UInt32(progressiveStream.count))
    payload.append(progressiveStream)

    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.wireToSurface2, payload: payload))
    )

    #expect(summary.typeName == "rdpgfx-wire-to-surface-2")
    #expect(summary.surfaceID == 7)
    #expect(summary.codecID == RDPGFXCodecID.caProgressive)
    #expect(summary.codecName == "caprogressive")
    #expect(summary.codecContextID == 12)
    #expect(summary.pixelFormat == 0x20)
    #expect(summary.bitmapDataLength == UInt32(progressiveStream.count))
    #expect(summary.progressiveBlockTypes == [0xCCC0, 0xCCC3, 0xCCC1, 0xCCC4, 0xCCC2])
    #expect(summary.progressiveBlockTypeNames == ["sync", "context", "frame-begin", "region", "frame-end"])
    #expect(summary.progressiveContextIDs == [0])
    #expect(summary.progressiveContextTileSizes == [64])
    #expect(summary.progressiveContextFlags == [1])
    #expect(summary.progressiveFrameIndexes == [5])
    #expect(summary.progressiveFrameRegionCounts == [1])
    #expect(summary.progressiveRegionCount == 1)
    #expect(summary.progressiveRegionRectCount == 1)
    #expect(summary.progressiveRegionRects == [
        RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
    ])
    #expect(summary.progressiveRegionTileCount == 1)
    #expect(summary.progressiveTileSimpleCount == 0)
    #expect(summary.progressiveTileFirstCount == 1)
    #expect(summary.progressiveTileUpgradeCount == 0)
}

@Test func summarizesCAVideoRemoteFXWireToSurface1Message() throws {
    let cavideoStream = cavideoBitmapStream()
    var payload = Data()
    payload.appendLittleEndianUInt16(9)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.cavideo)
    payload.appendUInt8(0x20)
    payload.append(rectangleBytes(left: 0, top: 0, right: 64, bottom: 64))
    payload.appendLittleEndianUInt32(UInt32(cavideoStream.count))
    payload.append(cavideoStream)

    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload))
    )

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.surfaceID == 9)
    #expect(summary.codecID == RDPGFXCodecID.cavideo)
    #expect(summary.codecName == "cavideo")
    #expect(summary.pixelFormat == 0x20)
    #expect(summary.bitmapDataLength == UInt32(cavideoStream.count))
    #expect(summary.cavideoBlockTypes == [0xCCC0, 0xCCC1, 0xCCC2, 0xCCC3, 0xCCC4, 0xCCC6, 0xCCC7, 0xCAC3, 0xCCC5])
    #expect(summary.cavideoBlockTypeNames == [
        "sync",
        "codec-versions",
        "channels",
        "context",
        "frame-begin",
        "region",
        "tile-set",
        "tile",
        "frame-end",
    ])
    #expect(summary.cavideoChannelWidths == [64])
    #expect(summary.cavideoChannelHeights == [64])
    #expect(summary.cavideoContextEntropyAlgorithms == ["rlgr3"])
    #expect(summary.cavideoTileSetEntropyAlgorithms == ["rlgr3"])
    #expect(summary.cavideoFrameIndexes == [7])
    #expect(summary.cavideoFrameRegionCounts == [1])
    #expect(summary.cavideoRegionCount == 1)
    #expect(summary.cavideoRegionRectCount == 1)
    #expect(summary.cavideoRegionRects == [
        RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
    ])
    #expect(summary.cavideoTileCount == 1)
    #expect(summary.cavideoTileRects == [
        RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64),
    ])
    #expect(summary.cavideoTileDataByteCount == 0)
}

@Test func summarizesCAVideoRemoteFXCompressedTilePayload() throws {
    let cavideoStream = cavideoRemoteFXGrayTileStream(
        frameIndex: 9,
        channelWidth: 192,
        channelHeight: 192,
        regionX: 64,
        regionY: 128,
        regionWidth: 64,
        regionHeight: 64,
        tileXIndex: 1,
        tileYIndex: 2
    )
    var payload = Data()
    payload.appendLittleEndianUInt16(10)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.cavideo)
    payload.appendUInt8(0x20)
    payload.append(rectangleBytes(left: 0, top: 0, right: 192, bottom: 192))
    payload.appendLittleEndianUInt32(UInt32(cavideoStream.count))
    payload.append(cavideoStream)

    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload))
    )

    #expect(summary.surfaceID == 10)
    #expect(summary.codecName == "cavideo")
    #expect(summary.cavideoChannelWidths == [192])
    #expect(summary.cavideoChannelHeights == [192])
    #expect(summary.cavideoFrameIndexes == [9])
    #expect(summary.cavideoRegionRects == [
        RDPFrameRect(left: 64, top: 128, right: 128, bottom: 192),
    ])
    #expect(summary.cavideoTileCount == 1)
    #expect(summary.cavideoTileRects == [
        RDPFrameRect(left: 64, top: 128, right: 128, bottom: 192),
    ])
    #expect((summary.cavideoTileDataByteCount ?? 0) > 0)
}

@Test func canSummarizeCAVideoMessageWithoutVideoDetails() throws {
    let cavideoStream = cavideoBitmapStream()
    var payload = Data()
    payload.appendLittleEndianUInt16(9)
    payload.appendLittleEndianUInt16(RDPGFXCodecID.cavideo)
    payload.appendUInt8(0x20)
    payload.append(rectangleBytes(left: 0, top: 0, right: 64, bottom: 64))
    payload.appendLittleEndianUInt32(UInt32(cavideoStream.count))
    payload.append(cavideoStream)

    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload)),
        includeVideoDetails: false
    )

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.codecName == "cavideo")
    #expect(summary.bitmapDataLength == UInt32(cavideoStream.count))
    #expect(summary.cavideoBlockTypes == nil)
    #expect(summary.cavideoTileCount == nil)
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

@Test func summarizesClearCodecSubcodecMetadataFromWireToSurface1Message() throws {
    let nsCodec = nsCodecSummaryFrame()
    var subcodec = Data()
    subcodec.appendLittleEndianUInt16(4)
    subcodec.appendLittleEndianUInt16(6)
    subcodec.appendLittleEndianUInt16(8)
    subcodec.appendLittleEndianUInt16(10)
    subcodec.appendLittleEndianUInt32(UInt32(nsCodec.count))
    subcodec.appendUInt8(0x01)
    subcodec.append(nsCodec)

    var bitmapData = Data([0x00, 0x01])
    bitmapData.appendLittleEndianUInt32(0)
    bitmapData.appendLittleEndianUInt32(0)
    bitmapData.appendLittleEndianUInt32(UInt32(subcodec.count))
    bitmapData.append(subcodec)

    var bytes = Data([
        0x01, 0x00, 0x00, 0x00,
    ])
    bytes.appendLittleEndianUInt32(UInt32(8 + 17 + bitmapData.count))
    bytes.appendLittleEndianUInt16(3)
    bytes.appendLittleEndianUInt16(RDPGFXCodecID.clearCodec)
    bytes.appendUInt8(0x20)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(0)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt16(16)
    bytes.appendLittleEndianUInt32(UInt32(bitmapData.count))
    bytes.append(bitmapData)

    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: bytes))

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.codecName == "clearcodec")
    #expect(summary.clearCodecSubcodecIDs == [0x01])
    #expect(summary.clearCodecSubcodecByteCounts == [UInt32(nsCodec.count)])
    #expect(summary.clearCodecSubcodecRects == [
        RDPFrameRect(left: 4, top: 6, right: 12, bottom: 16),
    ])
    #expect(summary.clearCodecNSCodecYByteCounts == [1])
    #expect(summary.clearCodecNSCodecCoByteCounts == [1])
    #expect(summary.clearCodecNSCodecCgByteCounts == [1])
    #expect(summary.clearCodecNSCodecAlphaByteCounts == [1])
    #expect(summary.clearCodecNSCodecColorLossLevels == [3])
    #expect(summary.clearCodecNSCodecChromaSubsamplingLevels == [0])
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

private func nsCodecSummaryFrame() -> Data {
    var data = Data()
    data.appendLittleEndianUInt32(1)
    data.appendLittleEndianUInt32(1)
    data.appendLittleEndianUInt32(1)
    data.appendLittleEndianUInt32(1)
    data.appendUInt8(3)
    data.appendUInt8(0)
    data.appendUInt8(0)
    data.appendUInt8(0)
    data.append(contentsOf: [0x10, 0x20, 0x30, 0xFF])
    return data
}

private func caprogressiveBitmapStream() -> Data {
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendProgressiveBlock(type: 0xCCC0, body: sync)

    var context = Data()
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(64)
    context.appendUInt8(1)
    stream.appendProgressiveBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendLittleEndianUInt32(5)
    frameBegin.appendLittleEndianUInt16(1)
    stream.appendProgressiveBlock(type: 0xCCC1, body: frameBegin)

    var tileBody = Data()
    tileBody.appendUInt8(0)
    tileBody.appendUInt8(0)
    tileBody.appendUInt8(0)
    tileBody.appendLittleEndianUInt16(0)
    tileBody.appendLittleEndianUInt16(0)
    tileBody.appendUInt8(0)
    tileBody.appendUInt8(0x40)
    tileBody.appendLittleEndianUInt16(0)
    tileBody.appendLittleEndianUInt16(0)
    tileBody.appendLittleEndianUInt16(0)
    tileBody.appendLittleEndianUInt16(0)

    var tileBlock = Data()
    tileBlock.appendProgressiveBlock(type: 0xCCC6, body: tileBody)

    var region = Data()
    region.appendUInt8(64)
    region.appendLittleEndianUInt16(1)
    region.appendUInt8(1)
    region.appendUInt8(0)
    region.appendUInt8(1)
    region.appendLittleEndianUInt16(1)
    region.appendLittleEndianUInt32(UInt32(tileBlock.count))
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(64)
    region.appendLittleEndianUInt16(64)
    region.append(contentsOf: [0, 0, 0, 0, 0])
    region.append(tileBlock)
    stream.appendProgressiveBlock(type: 0xCCC4, body: region)

    stream.appendProgressiveBlock(type: 0xCCC2, body: Data())

    return stream
}

private func cavideoBitmapStream() -> Data {
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendRFXBlock(type: 0xCCC0, body: sync)

    stream.appendRFXBlock(type: 0xCCC1, body: Data([
        0x01,
        0x01, 0x00, 0x01,
    ]))

    var channels = Data()
    channels.appendUInt8(1)
    channels.appendUInt8(0)
    channels.appendLittleEndianUInt16(64)
    channels.appendLittleEndianUInt16(64)
    stream.appendRFXBlock(type: 0xCCC2, body: channels)

    var context = Data()
    context.appendRFXChannelHeader(channelID: 0xFF)
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(64)
    context.appendLittleEndianUInt16(0xA828)
    stream.appendRFXBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendRFXChannelHeader(channelID: 0)
    frameBegin.appendLittleEndianUInt32(7)
    frameBegin.appendLittleEndianUInt16(1)
    stream.appendRFXBlock(type: 0xCCC4, body: frameBegin)

    var region = Data()
    region.appendRFXChannelHeader(channelID: 0)
    region.appendUInt8(1)
    region.appendLittleEndianUInt16(1)
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(0)
    region.appendLittleEndianUInt16(64)
    region.appendLittleEndianUInt16(64)
    region.appendLittleEndianUInt16(0xCAC1)
    region.appendLittleEndianUInt16(1)
    stream.appendRFXBlock(type: 0xCCC6, body: region)

    var tile = Data()
    tile.appendUInt8(0)
    tile.appendUInt8(0)
    tile.appendUInt8(0)
    tile.appendLittleEndianUInt16(0)
    tile.appendLittleEndianUInt16(0)
    tile.appendLittleEndianUInt16(0)
    tile.appendLittleEndianUInt16(0)
    tile.appendLittleEndianUInt16(0)
    var tileBlock = Data()
    tileBlock.appendRFXBlock(type: 0xCAC3, body: tile)

    var tileSet = Data()
    tileSet.appendRFXChannelHeader(channelID: 0)
    tileSet.appendLittleEndianUInt16(0xCAC2)
    tileSet.appendLittleEndianUInt16(0)
    tileSet.appendLittleEndianUInt16(0x5051)
    tileSet.appendUInt8(1)
    tileSet.appendUInt8(64)
    tileSet.appendLittleEndianUInt16(1)
    tileSet.appendLittleEndianUInt32(UInt32(tileBlock.count))
    tileSet.append(contentsOf: [0x66, 0x66, 0x77, 0x88, 0x98])
    tileSet.append(tileBlock)
    stream.appendRFXBlock(type: 0xCCC7, body: tileSet)

    var frameEnd = Data()
    frameEnd.appendRFXChannelHeader(channelID: 0)
    stream.appendRFXBlock(type: 0xCCC5, body: frameEnd)

    return stream
}

private func graphicsMessage(commandID: UInt16, payload: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(commandID)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt32(UInt32(8 + payload.count))
    data.append(payload)
    return data
}

private extension Data {
    mutating func appendProgressiveBlock(type: UInt16, body: Data) {
        appendLittleEndianUInt16(type)
        appendLittleEndianUInt32(UInt32(6 + body.count))
        append(body)
    }

    mutating func appendRFXBlock(type: UInt16, body: Data) {
        appendLittleEndianUInt16(type)
        appendLittleEndianUInt32(UInt32(6 + body.count))
        append(body)
    }

    mutating func appendRFXChannelHeader(channelID: UInt8) {
        appendUInt8(1)
        appendUInt8(channelID)
    }
}

private func rectangleBytes(left: UInt16, top: UInt16, right: UInt16, bottom: UInt16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(left)
    data.appendLittleEndianUInt16(top)
    data.appendLittleEndianUInt16(right)
    data.appendLittleEndianUInt16(bottom)
    return data
}

private func pointBytes(x: UInt16, y: UInt16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(x)
    data.appendLittleEndianUInt16(y)
    return data
}
