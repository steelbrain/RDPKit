import Foundation
@testable import RDPKit
import Testing

@Test func encodesRDPGFXCapsAdvertiseWithDefaultSupportedFallbacks() throws {
    let advertise = RDPGFXCapsAdvertisePDU()

    #expect(advertise.capabilitySets.map(\.version) == [
        RDPGFXCapabilityVersion.version107,
        RDPGFXCapabilityVersion.version106,
        RDPGFXCapabilityVersion.version105,
        RDPGFXCapabilityVersion.version104,
        RDPGFXCapabilityVersion.version103,
        RDPGFXCapabilityVersion.version102,
        RDPGFXCapabilityVersion.version101,
        RDPGFXCapabilityVersion.version10,
        RDPGFXCapabilityVersion.version81,
        RDPGFXCapabilityVersion.version8,
    ])
    #expect(advertise.capabilitySets.map(\.flags) == [
        RDPGFXCapabilityFlags.defaultVersion107,
        RDPGFXCapabilityFlags.defaultVersion104Through107,
        RDPGFXCapabilityFlags.defaultVersion104Through107,
        RDPGFXCapabilityFlags.defaultVersion104Through107,
        RDPGFXCapabilityFlags.defaultVersion103,
        RDPGFXCapabilityFlags.defaultVersion102,
        0,
        RDPGFXCapabilityFlags.defaultVersion10,
        RDPGFXCapabilityFlags.defaultVersion81,
        RDPGFXCapabilityFlags.defaultVersion8,
    ])
    let parsed = try #require(try RDPGFXCapsAdvertisePDU.parseIfPresent(from: advertise.encoded()))
    #expect(parsed == advertise)
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
        RDPGFXCapabilityVersion.version106,
        RDPGFXCapabilityVersion.version105,
        RDPGFXCapabilityVersion.version104,
        RDPGFXCapabilityVersion.version103,
        RDPGFXCapabilityVersion.version102,
        RDPGFXCapabilityVersion.version101,
        RDPGFXCapabilityVersion.version10,
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
    #expect(
        RDPGFXCapabilityFlags.defaultVersion107 & RDPGFXCapabilityFlags.scaledMapDisabled == 0
    )
    #expect(
        RDPGFXCapabilityFlags.defaultVersion8
            & (RDPGFXCapabilityFlags.thinClient | RDPGFXCapabilityFlags.smallCache)
            == RDPGFXCapabilityFlags.smallCache
    )
}

@Test func logicalFrameTrackerAcceptsFramedGraphicsCommands() throws {
    var tracker = RDPGFXLogicalFrameTracker()

    #expect(try tracker.shouldProcess(RDPGFXHeader.parse(from: startFrameMessage(frameID: 42))))
    #expect(tracker.activeFrameID == 42)
    #expect(try tracker.shouldProcess(RDPGFXHeader.parse(from: solidFillMessage())))
    #expect(tracker.activeFrameID == 42)
    #expect(try tracker.shouldProcess(RDPGFXHeader.parse(from: endFrameMessage(frameID: 42))))
    #expect(tracker.activeFrameID == nil)
}

@Test func logicalFrameTrackerIgnoresUnexpectedGraphicsSequences() throws {
    let start = try RDPGFXHeader.parse(from: startFrameMessage(frameID: 42))
    let mismatchedEnd = try RDPGFXHeader.parse(from: endFrameMessage(frameID: 43))
    let fill = try RDPGFXHeader.parse(from: solidFillMessage())

    var outsideFrame = RDPGFXLogicalFrameTracker()
    #expect(try !outsideFrame.shouldProcess(fill))

    var nestedFrame = RDPGFXLogicalFrameTracker()
    #expect(try nestedFrame.shouldProcess(start))
    #expect(try !nestedFrame.shouldProcess(start))
    #expect(nestedFrame.activeFrameID == 42)

    var wrongEnd = RDPGFXLogicalFrameTracker()
    #expect(try wrongEnd.shouldProcess(start))
    #expect(try !wrongEnd.shouldProcess(mismatchedEnd))
    #expect(wrongEnd.activeFrameID == 42)
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

@Test func rejectsStandaloneRDPGFXHeaderWithTrailingBytes() {
    let bytes = Data([
        0x13, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
        0x00,
    ])

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXHeader.parse(from: bytes)
    }
}

@Test func rejectsRDPGFXHeaderWithNonzeroFlags() {
    let bytes = Data([
        0x13, 0x00, 0x01, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXHeader.parse(from: bytes)
    }
}

@Test func rejectsCapsConfirmCapabilitySetWithTrailingBytes() {
    let bytes = Data([
        0x13, 0x00, 0x00, 0x00,
        0x16, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
        0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapsConfirmPDU.parseIfPresent(from: bytes)
    }
}

@Test func rejectsCapsConfirmCapabilitySetWithInvalidKnownVersionLength() {
    let bytes = Data([
        0x13, 0x00, 0x00, 0x00,
        0x18, 0x00, 0x00, 0x00,
        0x05, 0x01, 0x08, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapsConfirmPDU.parseIfPresent(from: bytes)
    }
}

@Test func ignoresCapsConfirmWithUnknownCapabilityVersion() throws {
    let bytes = graphicsMessage(
        commandID: RDPGFXCommandID.capsConfirm,
        payload: capabilitySetBytes(version: 0xCAFE_BABE, data: Data([0x01, 0x02, 0x03, 0x04]))
    )

    let confirm = try RDPGFXCapsConfirmPDU.parseIfPresent(from: bytes)

    #expect(confirm == nil)
}

@Test func rejectsCapsAdvertiseWithDuplicateCapabilityVersions() {
    var payload = Data()
    payload.appendLittleEndianUInt16(2)
    payload.append(RDPGFXCapabilitySet.version81(flags: RDPGFXCapabilityFlags.defaultVersion81).encoded)
    payload.append(RDPGFXCapabilitySet.version81(flags: RDPGFXCapabilityFlags.defaultVersion81).encoded)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapsAdvertisePDU.parseIfPresent(from: graphicsMessage(
            commandID: RDPGFXCommandID.capsAdvertise,
            payload: payload
        ))
    }
}

@Test func rejectsCapsAdvertiseWithUnknownCapabilityVersion() {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.append(capabilitySetBytes(version: 0xCAFE_BABE, data: Data([0x01, 0x02, 0x03, 0x04])))

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapsAdvertisePDU.parseIfPresent(from: graphicsMessage(
            commandID: RDPGFXCommandID.capsAdvertise,
            payload: payload
        ))
    }
}

@Test func rejectsVersion101CapabilitySetWithNonzeroReservedBytes() {
    var bytes = Data()
    bytes.appendLittleEndianUInt32(RDPGFXCapabilityVersion.version101)
    bytes.appendLittleEndianUInt32(16)
    bytes.append(Data(repeating: 0, count: 15))
    bytes.appendUInt8(1)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapabilitySet.parse(from: bytes)
    }
}

@Test func rejectsNewerCapabilitySetWithIncompatibleAVCFlags() {
    var bytes = Data()
    bytes.appendLittleEndianUInt32(RDPGFXCapabilityVersion.version107)
    bytes.appendLittleEndianUInt32(4)
    bytes.appendLittleEndianUInt32(RDPGFXCapabilityFlags.avcDisabled | RDPGFXCapabilityFlags.avcThinClient)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCapabilitySet.parse(from: bytes)
    }
}

@Test func rejectsKnownCapabilitySetWithUndefinedFlagsForVersion() {
    let cases: [(version: UInt32, flags: UInt32)] = [
        (RDPGFXCapabilityVersion.version8, RDPGFXCapabilityFlags.avc420Enabled),
        (RDPGFXCapabilityVersion.version81, RDPGFXCapabilityFlags.avcDisabled),
        (RDPGFXCapabilityVersion.version10, RDPGFXCapabilityFlags.avcThinClient),
        (RDPGFXCapabilityVersion.version102, RDPGFXCapabilityFlags.scaledMapDisabled),
        (RDPGFXCapabilityVersion.version103, RDPGFXCapabilityFlags.smallCache),
        (RDPGFXCapabilityVersion.version104, RDPGFXCapabilityFlags.scaledMapDisabled),
        (RDPGFXCapabilityVersion.version105, RDPGFXCapabilityFlags.scaledMapDisabled),
        (RDPGFXCapabilityVersion.version106, RDPGFXCapabilityFlags.scaledMapDisabled),
    ]

    for testCase in cases {
        var bytes = Data()
        bytes.appendLittleEndianUInt32(testCase.version)
        bytes.appendLittleEndianUInt32(4)
        bytes.appendLittleEndianUInt32(testCase.flags)

        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            try RDPGFXCapabilitySet.parse(from: bytes)
        }
    }
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
    let deleteSurface = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.deleteSurface,
        payload: littleEndianUInt16Data(1)
    )))
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
    #expect(deleteSurface.typeName == "rdpgfx-delete-surface")
    #expect(deleteSurface.surfaceID == 1)
    #expect(startFrame.frameID == 42)
    #expect(endFrame.frameID == 42)
}

@Test func parsesStartFrameTimestampWithinSpecLimits() throws {
    let timestamp = startFrameTimestamp(milliseconds: 999, seconds: 59, minutes: 59, hours: 23)
    var payload = Data()
    payload.appendLittleEndianUInt32(timestamp)
    payload.appendLittleEndianUInt32(42)

    let startFrame = try RDPGFXStartFramePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.startFrame,
        payload: payload
    )))

    #expect(startFrame.timestamp == timestamp)
    #expect(startFrame.frameID == 42)
}

@Test func rejectsStartFrameTimestampOutsideSpecLimits() {
    let invalidTimestamps = [
        startFrameTimestamp(milliseconds: 1000, seconds: 0, minutes: 0, hours: 0),
        startFrameTimestamp(milliseconds: 0, seconds: 60, minutes: 0, hours: 0),
        startFrameTimestamp(milliseconds: 0, seconds: 0, minutes: 60, hours: 0),
        startFrameTimestamp(milliseconds: 0, seconds: 0, minutes: 0, hours: 24),
    ]

    for timestamp in invalidTimestamps {
        var payload = Data()
        payload.appendLittleEndianUInt32(timestamp)
        payload.appendLittleEndianUInt32(42)

        #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
            try RDPGFXStartFramePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
                commandID: RDPGFXCommandID.startFrame,
                payload: payload
            )))
        }
    }
}

@Test func summarizesDeleteEncodingContextMessage() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(7)
    payload.appendLittleEndianUInt32(12)

    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.deleteEncodingContext,
        payload: payload
    )))

    #expect(summary.typeName == "rdpgfx-delete-encoding-context")
    #expect(summary.surfaceID == 7)
    #expect(summary.codecContextID == 12)
}

@Test func rejectsDeletePDUsWithInvalidLength() {
    var overlongDeleteSurfacePayload = littleEndianUInt16Data(1)
    overlongDeleteSurfacePayload.appendUInt8(0)
    var overlongDeleteEncodingContextPayload = Data()
    overlongDeleteEncodingContextPayload.appendLittleEndianUInt16(7)
    overlongDeleteEncodingContextPayload.appendLittleEndianUInt32(12)
    overlongDeleteEncodingContextPayload.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXDeleteSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.deleteSurface,
            payload: Data()
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXDeleteSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.deleteSurface,
            payload: overlongDeleteSurfacePayload
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXDeleteEncodingContextPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.deleteEncodingContext,
            payload: littleEndianUInt16Data(7)
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXDeleteEncodingContextPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.deleteEncodingContext,
            payload: overlongDeleteEncodingContextPayload
        )))
    }
}

@Test func rejectsInvalidPixelFormatInSurfaceAndBitmapPDUs() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCreateSurfacePDU.parse(from: RDPGFXHeader.parse(from: createSurfaceMessage(pixelFormat: 0x22)))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXWireToSurface1PDU.parse(from: RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: 0x22
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXWireToSurface2PDU.parse(from: RDPGFXHeader.parse(from: wireToSurface2Message(
            codecID: RDPGFXCodecID.caProgressive,
            pixelFormat: 0x22
        )))
    }
}

@Test func rejectsInvalidCodecIDInBitmapPDUs() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXWireToSurface1PDU.parse(from: RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.caProgressive,
            pixelFormat: 0x20
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXWireToSurface2PDU.parse(from: RDPGFXHeader.parse(from: wireToSurface2Message(
            codecID: RDPGFXCodecID.uncompressed,
            pixelFormat: 0x20
        )))
    }
}

@Test func parsesResetGraphicsWithinSpecLimits() throws {
    let reset = try RDPGFXResetGraphicsPDU.parse(from: RDPGFXHeader.parse(from: resetGraphicsMessage(
        width: RDPGFXResetGraphicsPDU.maximumDimension,
        height: RDPGFXResetGraphicsPDU.maximumDimension,
        monitorCount: RDPGFXResetGraphicsPDU.maximumMonitorCount
    )))

    #expect(reset.width == RDPGFXResetGraphicsPDU.maximumDimension)
    #expect(reset.height == RDPGFXResetGraphicsPDU.maximumDimension)
    #expect(reset.monitorCount == RDPGFXResetGraphicsPDU.maximumMonitorCount)
    #expect(reset.monitorDefinitions.count == Int(RDPGFXResetGraphicsPDU.maximumMonitorCount))
}

@Test func parsesResetGraphicsMonitorDefinitions() throws {
    let monitor = RDPGFXMonitorDefinition(
        left: -1440,
        top: 0,
        right: 0,
        bottom: 900,
        flags: 1
    )
    let message = try RDPGFXHeader.parse(from: resetGraphicsMessage(
        width: 1440,
        height: 900,
        monitorCount: 1,
        monitorDefinitions: [monitor]
    ))
    let reset = try RDPGFXResetGraphicsPDU.parse(from: message)
    let summary = try RDPGFXMessageSummary.summarize(message)

    #expect(reset.monitorDefinitions == [monitor])
    #expect(summary.width == 1440)
    #expect(summary.height == 900)
    #expect(summary.monitorCount == 1)
}

@Test func rejectsResetGraphicsOutsideSpecLimits() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXResetGraphicsPDU.parse(from: RDPGFXHeader.parse(from: resetGraphicsMessage(
            width: RDPGFXResetGraphicsPDU.maximumDimension + 1,
            height: 1080,
            monitorCount: 1
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXResetGraphicsPDU.parse(from: RDPGFXHeader.parse(from: resetGraphicsMessage(
            width: 1920,
            height: RDPGFXResetGraphicsPDU.maximumDimension + 1,
            monitorCount: 1
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXResetGraphicsPDU.parse(from: RDPGFXHeader.parse(from: resetGraphicsMessage(
            width: 1920,
            height: 1080,
            monitorCount: RDPGFXResetGraphicsPDU.maximumMonitorCount + 1
        )))
    }
}

@Test func parsesMapSurfaceToOutputWithZeroReservedField() throws {
    let map = try RDPGFXMapSurfaceToOutputPDU.parse(from: RDPGFXHeader.parse(from: mapSurfaceToOutputMessage(
        surfaceID: 7,
        reserved: 0,
        x: 10,
        y: 20
    )))

    #expect(map.surfaceID == 7)
    #expect(map.outputOriginX == 10)
    #expect(map.outputOriginY == 20)
}

@Test func summarizesScaledOutputAndWindowMappingPDUs() throws {
    let scaledOutput = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: mapSurfaceToScaledOutputMessage(
        surfaceID: 7,
        reserved: 0,
        x: 10,
        y: 20,
        targetWidth: 1920,
        targetHeight: 1080
    )))
    let window = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: mapSurfaceToWindowMessage(
        commandID: RDPGFXCommandID.mapSurfaceToWindow,
        surfaceID: 8,
        windowID: 0x0102_0304_0506_0708,
        mappedWidth: 800,
        mappedHeight: 600
    )))
    let scaledWindow = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: mapSurfaceToWindowMessage(
        commandID: RDPGFXCommandID.mapSurfaceToScaledWindow,
        surfaceID: 9,
        windowID: 0x1112_1314_1516_1718,
        mappedWidth: 1024,
        mappedHeight: 768,
        targetWidth: 2048,
        targetHeight: 1536
    )))

    #expect(scaledOutput.typeName == "rdpgfx-map-surface-to-scaled-output")
    #expect(scaledOutput.surfaceID == 7)
    #expect(scaledOutput.outputOriginX == 10)
    #expect(scaledOutput.outputOriginY == 20)
    #expect(scaledOutput.targetWidth == 1920)
    #expect(scaledOutput.targetHeight == 1080)
    #expect(window.typeName == "rdpgfx-map-surface-to-window")
    #expect(window.surfaceID == 8)
    #expect(window.windowID == 0x0102_0304_0506_0708)
    #expect(window.mappedWidth == 800)
    #expect(window.mappedHeight == 600)
    #expect(scaledWindow.typeName == "rdpgfx-map-surface-to-scaled-window")
    #expect(scaledWindow.surfaceID == 9)
    #expect(scaledWindow.windowID == 0x1112_1314_1516_1718)
    #expect(scaledWindow.mappedWidth == 1024)
    #expect(scaledWindow.mappedHeight == 768)
    #expect(scaledWindow.targetWidth == 2048)
    #expect(scaledWindow.targetHeight == 1536)
}

@Test func rejectsMapSurfaceToOutputWithNonzeroReservedField() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXMapSurfaceToOutputPDU.parse(from: RDPGFXHeader.parse(from: mapSurfaceToOutputMessage(
            surfaceID: 7,
            reserved: 1,
            x: 10,
            y: 20
        )))
    }
}

@Test func rejectsMapSurfaceToScaledOutputWithNonzeroReservedField() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXMapSurfaceToScaledOutputPDU.parse(from: RDPGFXHeader.parse(from: mapSurfaceToScaledOutputMessage(
            surfaceID: 7,
            reserved: 1,
            x: 10,
            y: 20,
            targetWidth: 1920,
            targetHeight: 1080
        )))
    }
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

    let evictCache = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: evictCacheEntryMessage(cacheSlot: 9))
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
    #expect(evictCache.typeName == "rdpgfx-evict-cache-entry")
    #expect(evictCache.cacheSlot == 9)
}

@Test func summarizesCacheImportReply() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(2)
    payload.appendLittleEndianUInt16(6)
    payload.appendLittleEndianUInt16(9)

    let reply = try RDPGFXCacheImportReplyPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.cacheImportReply,
        payload: payload
    )))
    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.cacheImportReply,
        payload: payload
    )))

    #expect(reply.cacheSlots == [6, 9])
    #expect(reply.importedEntriesCount == 2)
    #expect(summary.typeName == "rdpgfx-cache-import-reply")
    #expect(summary.importedEntriesCount == 2)
}

@Test func rejectsCacheImportReplyWithInvalidCacheSlotOrLength() {
    var invalidCacheSlotPayload = Data()
    invalidCacheSlotPayload.appendLittleEndianUInt16(1)
    invalidCacheSlotPayload.appendLittleEndianUInt16(0)

    var overlongPayload = Data()
    overlongPayload.appendLittleEndianUInt16(1)
    overlongPayload.appendLittleEndianUInt16(6)
    overlongPayload.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCacheImportReplyPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.cacheImportReply,
            payload: invalidCacheSlotPayload
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCacheImportReplyPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.cacheImportReply,
            payload: overlongPayload
        )))
    }
}

@Test func summarizesSurfaceToSurfaceGraphicsMessage() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(11)
    payload.appendLittleEndianUInt16(12)
    payload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    payload.appendLittleEndianUInt16(2)
    payload.append(pointBytes(x: 5, y: 6))
    payload.append(pointBytes(x: 7, y: 8))

    let copy = try RDPGFXSurfaceToSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.surfaceToSurface,
        payload: payload
    )))
    let summary = try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.surfaceToSurface,
        payload: payload
    )))

    #expect(copy.sourceSurfaceID == 11)
    #expect(copy.destinationSurfaceID == 12)
    #expect(copy.sourceRect == RDPGFXRect16(left: 1, top: 2, right: 17, bottom: 18))
    #expect(copy.destinationPoints == [
        RDPGFXPoint16(x: 5, y: 6),
        RDPGFXPoint16(x: 7, y: 8),
    ])
    #expect(summary.typeName == "rdpgfx-surface-to-surface")
    #expect(summary.surfaceID == 12)
    #expect(summary.sourceSurfaceID == 11)
    #expect(summary.sourceRect == RDPFrameRect(left: 1, top: 2, right: 17, bottom: 18))
    #expect(summary.destinationPointCount == 2)
}

@Test func parsesSignedRDPGFXDestinationPoints() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(11)
    payload.appendLittleEndianUInt16(12)
    payload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    payload.appendLittleEndianUInt16(1)
    payload.append(pointBytes(x: -1, y: -2))

    let copy = try RDPGFXSurfaceToSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.surfaceToSurface,
        payload: payload
    )))

    #expect(copy.destinationPoints == [RDPGFXPoint16(x: -1, y: -2)])
}

@Test func rejectsSurfaceToSurfaceWithInvalidLength() {
    var missingDestinationPointPayload = Data()
    missingDestinationPointPayload.appendLittleEndianUInt16(11)
    missingDestinationPointPayload.appendLittleEndianUInt16(12)
    missingDestinationPointPayload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    missingDestinationPointPayload.appendLittleEndianUInt16(1)

    var overlongDestinationPointPayload = missingDestinationPointPayload
    overlongDestinationPointPayload.append(pointBytes(x: 5, y: 6))
    overlongDestinationPointPayload.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXSurfaceToSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.surfaceToSurface,
            payload: missingDestinationPointPayload
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXSurfaceToSurfacePDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.surfaceToSurface,
            payload: overlongDestinationPointPayload
        )))
    }
}

@Test func rejectsCachePDUsWithInvalidCacheSlot() {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXSurfaceToCachePDU.parse(from: RDPGFXHeader.parse(from: surfaceToCacheMessage(cacheSlot: 0)))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXSurfaceToCachePDU.parse(from: RDPGFXHeader.parse(from: surfaceToCacheMessage(
            cacheSlot: RDPGFXCacheSlot.maximumSlot + 1
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCacheToSurfacePDU.parse(from: RDPGFXHeader.parse(from: cacheToSurfaceMessage(cacheSlot: 0)))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXCacheToSurfacePDU.parse(from: RDPGFXHeader.parse(from: cacheToSurfaceMessage(
            cacheSlot: RDPGFXCacheSlot.maximumSlot + 1
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXEvictCacheEntryPDU.parse(from: RDPGFXHeader.parse(from: evictCacheEntryMessage(cacheSlot: 0)))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXEvictCacheEntryPDU.parse(from: RDPGFXHeader.parse(from: evictCacheEntryMessage(
            cacheSlot: RDPGFXCacheSlot.maximumSlot + 1
        )))
    }
}

@Test func rejectsEvictCacheEntryWithInvalidLength() {
    var overlongPayload = Data()
    overlongPayload.appendLittleEndianUInt16(9)
    overlongPayload.appendUInt8(0)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXEvictCacheEntryPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.evictCacheEntry,
            payload: Data()
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXEvictCacheEntryPDU.parse(from: RDPGFXHeader.parse(from: graphicsMessage(
            commandID: RDPGFXCommandID.evictCacheEntry,
            payload: overlongPayload
        )))
    }
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

@Test func summarizesAlphaWireToSurface1RawBitmapStream() throws {
    let alphaStream = alphaBitmapStream(compressed: 0, payload: Data([0x00, 0x7F]))
    let summary = try RDPGFXMessageSummary.summarize(
        RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: rectangleBytes(left: 0, top: 0, right: 2, bottom: 1),
            bitmapData: alphaStream
        ))
    )

    #expect(summary.typeName == "rdpgfx-wire-to-surface-1")
    #expect(summary.codecID == RDPGFXCodecID.alpha)
    #expect(summary.codecName == "alpha")
    #expect(summary.bitmapDataLength == UInt32(alphaStream.count))
}

@Test func parsesAlphaBitmapStreamRunLengthSegments() throws {
    let stream = alphaBitmapStream(compressed: 1, payload: Data([
        0x7F, 0x02,
        0x80, 0xFF, 0x03, 0x00,
        0x81, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00,
    ]))

    let parsed = try RDPGFXAlphaBitmapStream.parse(from: stream, pixelCount: 6)

    #expect(parsed.compressed)
    #expect(parsed.alphaValues == Data([0x7F, 0x7F, 0x80, 0x80, 0x80, 0x81]))
}

@Test func rejectsMalformedAlphaWireToSurface1BitmapStream() throws {
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: rectangleBytes(left: 0, top: 0, right: 2, bottom: 1),
            bitmapData: Data([0x4C, 0x00, 0x00, 0x00, 0xAA, 0xBB])
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: rectangleBytes(left: 0, top: 0, right: 2, bottom: 1),
            bitmapData: alphaBitmapStream(compressed: 0, payload: Data([0xAA]))
        )))
    }
    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXMessageSummary.summarize(RDPGFXHeader.parse(from: wireToSurface1Message(
            codecID: RDPGFXCodecID.alpha,
            pixelFormat: RDPGFXPixelFormat.argb8888,
            destinationRect: rectangleBytes(left: 0, top: 0, right: 2, bottom: 1),
            bitmapData: alphaBitmapStream(compressed: 1, payload: Data([0xAA, 0x01]))
        )))
    }
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

@Test func parsesAVC420QuantQualityBitfields() throws {
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.append(rectangleBytes(left: 0, top: 0, right: 64, bottom: 32))
    bitmapData.appendUInt8(0x80 | 0x40 | 51)
    bitmapData.appendUInt8(100)
    bitmapData.append(Data([0x00, 0x00, 0x01, 0x65]))

    let stream = try RDPGFXAVC420BitmapStream.parse(from: bitmapData)

    #expect(stream.quantQualityVals == [
        RDPGFXAVC420QuantQuality(qpVal: 51, isProgressive: true, qualityVal: 100),
    ])
}

@Test func rejectsAVC420QuantQualityAboveSpecRange() {
    var excessiveQP = Data()
    excessiveQP.appendLittleEndianUInt32(1)
    excessiveQP.append(rectangleBytes(left: 0, top: 0, right: 64, bottom: 32))
    excessiveQP.appendUInt8(52)
    excessiveQP.appendUInt8(100)
    excessiveQP.append(Data([0x00, 0x00, 0x01, 0x65]))

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXAVC420BitmapStream.parse(from: excessiveQP)
    }

    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1)
    bitmapData.append(rectangleBytes(left: 0, top: 0, right: 64, bottom: 32))
    bitmapData.appendUInt8(26)
    bitmapData.appendUInt8(101)
    bitmapData.append(Data([0x00, 0x00, 0x01, 0x65]))

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXAVC420BitmapStream.parse(from: bitmapData)
    }
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

@Test func rejectsAVC444LumaOnlyStreamWithMismatchedByteCount() {
    let yuv420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x65]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(UInt32(yuv420.count + 1) | UInt32(RDPGFXAVC444LayoutCode.yuv420Only.rawValue) << 30)
    bitmapData.append(yuv420)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXAVC444BitmapStream.parse(from: bitmapData)
    }
}

@Test func rejectsAVC444ChromaOnlyStreamWithNonzeroYUV420ByteCount() {
    let chroma420 = avc420BitmapStream(nalUnits: [
        Data([0x00, 0x00, 0x01, 0x41]),
    ])
    var bitmapData = Data()
    bitmapData.appendLittleEndianUInt32(1 | UInt32(RDPGFXAVC444LayoutCode.chroma420Only.rawValue) << 30)
    bitmapData.append(chroma420)

    #expect(throws: RDPDecodeError.invalidRDPGFXPDU) {
        try RDPGFXAVC444BitmapStream.parse(from: bitmapData)
    }
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

@Test func namesAllSpecDefinedClientGraphicsCommands() throws {
    #expect(try RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.cacheImportOffer,
        payload: Data()
    )).typeName == "rdpgfx-cache-import-offer")
    #expect(try RDPGFXHeader.parse(from: graphicsMessage(
        commandID: RDPGFXCommandID.qoeFrameAcknowledge,
        payload: Data()
    )).typeName == "rdpgfx-qoe-frame-acknowledge")
}

@Test func qoeFrameAcknowledgeEncodesFrameAndTimingFields() {
    let acknowledge = RDPGFXQoEFrameAcknowledgePDU(
        frameID: 42,
        timestamp: 1_234,
        timeDiffSE: 12,
        timeDiffEDR: 34
    )

    #expect(acknowledge.encoded().rdpHexString == """
    16 00 00 00 14 00 00 00 2a 00 00 00 d2 04 00 00 0c 00 22 00
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

private func littleEndianUInt16Data(_ value: UInt16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(value)
    return data
}

private func startFrameTimestamp(
    milliseconds: UInt32,
    seconds: UInt32,
    minutes: UInt32,
    hours: UInt32
) -> UInt32 {
    (milliseconds & 0x03FF)
        | (seconds & 0x003F) << 10
        | (minutes & 0x003F) << 16
        | (hours & 0x03FF) << 22
}

private func surfaceToCacheMessage(cacheSlot: UInt16) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(3)
    payload.appendLittleEndianUInt64(0x0102_0304_0506_0708)
    payload.appendLittleEndianUInt16(cacheSlot)
    payload.append(rectangleBytes(left: 1, top: 2, right: 17, bottom: 18))
    return graphicsMessage(commandID: RDPGFXCommandID.surfaceToCache, payload: payload)
}

private func cacheToSurfaceMessage(cacheSlot: UInt16) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(cacheSlot)
    payload.appendLittleEndianUInt16(3)
    payload.appendLittleEndianUInt16(1)
    payload.append(pointBytes(x: 5, y: 6))
    return graphicsMessage(commandID: RDPGFXCommandID.cacheToSurface, payload: payload)
}

private func evictCacheEntryMessage(cacheSlot: UInt16) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(cacheSlot)
    return graphicsMessage(commandID: RDPGFXCommandID.evictCacheEntry, payload: payload)
}

private func createSurfaceMessage(pixelFormat: UInt8) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(640)
    payload.appendLittleEndianUInt16(480)
    payload.appendUInt8(pixelFormat)
    return graphicsMessage(commandID: RDPGFXCommandID.createSurface, payload: payload)
}

private func wireToSurface1Message(
    codecID: UInt16,
    pixelFormat: UInt8,
    destinationRect: Data = rectangleBytes(left: 0, top: 0, right: 1, bottom: 1),
    bitmapData: Data = Data([0x00, 0x00, 0x00, 0x00])
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(codecID)
    payload.appendUInt8(pixelFormat)
    payload.append(destinationRect)
    payload.appendLittleEndianUInt32(UInt32(bitmapData.count))
    payload.append(bitmapData)
    return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface1, payload: payload)
}

private func alphaBitmapStream(compressed: UInt16, payload: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(0x414C)
    data.appendLittleEndianUInt16(compressed)
    data.append(payload)
    return data
}

private func wireToSurface2Message(codecID: UInt16, pixelFormat: UInt8) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(codecID)
    payload.appendLittleEndianUInt32(7)
    payload.appendUInt8(pixelFormat)
    payload.appendLittleEndianUInt32(1)
    payload.appendUInt8(0)
    return graphicsMessage(commandID: RDPGFXCommandID.wireToSurface2, payload: payload)
}

private func startFrameMessage(frameID: UInt32) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(frameID)
    return graphicsMessage(commandID: RDPGFXCommandID.startFrame, payload: payload)
}

private func endFrameMessage(frameID: UInt32) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt32(frameID)
    return graphicsMessage(commandID: RDPGFXCommandID.endFrame, payload: payload)
}

private func solidFillMessage() -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.append(contentsOf: [0, 0, 0, 0xFF])
    payload.appendLittleEndianUInt16(1)
    payload.append(rectangleBytes(left: 0, top: 0, right: 1, bottom: 1))
    return graphicsMessage(commandID: RDPGFXCommandID.solidFill, payload: payload)
}

private func resetGraphicsMessage(
    width: UInt32,
    height: UInt32,
    monitorCount: UInt32,
    monitorDefinitions: [RDPGFXMonitorDefinition] = []
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt32(width)
    payload.appendLittleEndianUInt32(height)
    payload.appendLittleEndianUInt32(monitorCount)
    for monitor in monitorDefinitions {
        payload.appendLittleEndianUInt32(UInt32(bitPattern: monitor.left))
        payload.appendLittleEndianUInt32(UInt32(bitPattern: monitor.top))
        payload.appendLittleEndianUInt32(UInt32(bitPattern: monitor.right))
        payload.appendLittleEndianUInt32(UInt32(bitPattern: monitor.bottom))
        payload.appendLittleEndianUInt32(monitor.flags)
    }
    if payload.count < 332 {
        payload.append(Data(repeating: 0, count: 332 - payload.count))
    }
    return graphicsMessage(commandID: RDPGFXCommandID.resetGraphics, payload: payload)
}

private func mapSurfaceToOutputMessage(
    surfaceID: UInt16,
    reserved: UInt16,
    x: UInt32,
    y: UInt32
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(reserved)
    payload.appendLittleEndianUInt32(x)
    payload.appendLittleEndianUInt32(y)
    return graphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToOutput, payload: payload)
}

private func mapSurfaceToScaledOutputMessage(
    surfaceID: UInt16,
    reserved: UInt16,
    x: UInt32,
    y: UInt32,
    targetWidth: UInt32,
    targetHeight: UInt32
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt16(reserved)
    payload.appendLittleEndianUInt32(x)
    payload.appendLittleEndianUInt32(y)
    payload.appendLittleEndianUInt32(targetWidth)
    payload.appendLittleEndianUInt32(targetHeight)
    return graphicsMessage(commandID: RDPGFXCommandID.mapSurfaceToScaledOutput, payload: payload)
}

private func mapSurfaceToWindowMessage(
    commandID: UInt16,
    surfaceID: UInt16,
    windowID: UInt64,
    mappedWidth: UInt32,
    mappedHeight: UInt32,
    targetWidth: UInt32? = nil,
    targetHeight: UInt32? = nil
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(surfaceID)
    payload.appendLittleEndianUInt64(windowID)
    payload.appendLittleEndianUInt32(mappedWidth)
    payload.appendLittleEndianUInt32(mappedHeight)
    if let targetWidth, let targetHeight {
        payload.appendLittleEndianUInt32(targetWidth)
        payload.appendLittleEndianUInt32(targetHeight)
    }
    return graphicsMessage(commandID: commandID, payload: payload)
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

private func pointBytes(x: Int16, y: Int16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(UInt16(bitPattern: x))
    data.appendLittleEndianUInt16(UInt16(bitPattern: y))
    return data
}

private func capabilitySetBytes(version: UInt32, data: Data) -> Data {
    var bytes = Data()
    bytes.appendLittleEndianUInt32(version)
    bytes.appendLittleEndianUInt32(UInt32(data.count))
    bytes.append(data)
    return bytes
}
