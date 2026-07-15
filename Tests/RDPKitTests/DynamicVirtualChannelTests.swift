import Foundation
@testable import RDPKit
import Testing

@Test func parsesDynamicVirtualChannelCapabilitiesRequest() throws {
    let request = try #require(try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
        from: Data([
            0x50, 0x00, 0x03, 0x00,
            0x33, 0x33, 0x11, 0x11, 0x3D, 0x0A, 0xA7, 0x04,
        ])
    ))

    #expect(request.version == 3)
    #expect(request.priorityChargeData == Data([0x33, 0x33, 0x11, 0x11, 0x3D, 0x0A, 0xA7, 0x04]))
    #expect(request.typeName == "dynvc-capabilities-request")
}

@Test func parsesDynamicVirtualChannelVersion1CapabilitiesRequestWithoutPriorityCharges() throws {
    let request = try #require(try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
        from: Data([0x50, 0x00, 0x01, 0x00])
    ))

    #expect(request.version == 1)
    #expect(request.priorityChargeData.isEmpty)
}

@Test func rejectsDynamicVirtualChannelCapabilitiesRequestWithInvalidVersionOrPriorityLength() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
            from: Data([0x50, 0x00, 0x04, 0x00])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
            from: Data([0x50, 0x00, 0x01, 0x00, 0x00, 0x00])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(
            from: Data([0x50, 0x00, 0x03, 0x00, 0x33, 0x33])
        )
    }
}

@Test func parsesDynamicVirtualChannelCompressedCommandHeader() throws {
    let header = try RDPDynamicVirtualChannelHeader(byte: 0x71)

    #expect(header.channelIDLength == 1)
    #expect(header.sp == 0)
    #expect(header.command == .dataCompressed)
    #expect(header.command.typeName == "dynvc-data-compressed")
}

@Test func detectsCompressedDynamicVirtualChannelDataPDUs() throws {
    let dataCompressed = try #require(try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
        from: Data([0x70, 0x07, 0x12, 0x00])
    ))
    let dataFirstCompressed = try #require(try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
        from: Data([0x64, 0x07, 0x00, 0x08, 0x12, 0x00])
    ))

    #expect(dataCompressed.command == .dataCompressed)
    #expect(dataCompressed.channelID == 7)
    #expect(dataCompressed.totalLength == nil)
    #expect(dataCompressed.compressedPayload.rdpHexString == "12 00")
    #expect(dataCompressed.typeName == "dynvc-data-compressed")
    #expect(dataFirstCompressed.command == .dataFirstCompressed)
    #expect(dataFirstCompressed.channelID == 7)
    #expect(dataFirstCompressed.totalLength == 2048)
    #expect(dataFirstCompressed.compressedPayload.rdpHexString == "12 00")
    #expect(dataFirstCompressed.typeName == "dynvc-data-first-compressed")
}

@Test func acceptsCompressedDynamicVirtualChannelDataPDUWithUnusedSpBits() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
        from: Data([0x74, 0x07, 0x12, 0x00])
    ))

    #expect(pdu.channelID == 7)
    #expect(pdu.compressedPayload == Data([0x12, 0x00]))
}

@Test func rejectsMalformedCompressedDynamicVirtualChannelDataPDUs() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
            from: Data([0x70, 0x07, 0x12])
        )
    }

    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
            from: Data([0x70, 0x07]) + Data(repeating: 0, count: 1_599)
        )
    }

    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(
            from: Data([0x64, 0x07, 0x00, 0x08]) + Data(repeating: 0, count: 1_597)
        )
    }
}

@Test func closingDynamicChannelDiscardsCompressionContext() {
    var contexts = [
        UInt32(7): RDPZGFXDecompressor.rdp8Lite(),
        UInt32(8): RDPZGFXDecompressor.rdp8Lite(),
    ]

    discardDynamicVirtualChannelCompressionContext(channelID: 7, decompressors: &contexts)

    #expect(contexts[7] == nil)
    #expect(contexts[8] != nil)
}

@Test func detectsDynamicVirtualChannelSoftSyncPDUs() throws {
    let request = try #require(try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
        from: Data([
            0x80, 0x00,
            0x08, 0x00, 0x00, 0x00,
            0x01, 0x00,
            0x00, 0x00,
        ])
    ))
    let response = try #require(try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
        from: Data([
            0x90, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
    ))

    #expect(request.command == .softSyncRequest)
    #expect(request.typeName == "dynvc-soft-sync-request")
    #expect(request.flags == 0x0001)
    #expect(request.channelLists.isEmpty)
    #expect(request.tunnelsToSwitch.isEmpty)
    #expect(response.command == .softSyncResponse)
    #expect(response.typeName == "dynvc-soft-sync-response")
    #expect(response.flags == nil)
    #expect(response.channelLists.isEmpty)
    #expect(response.tunnelsToSwitch.isEmpty)
}

@Test func parsesDynamicVirtualChannelSoftSyncChannelListsAndResponseTunnels() throws {
    let request = try #require(try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
        from: Data([
            0x80, 0x00,
            0x16, 0x00, 0x00, 0x00,
            0x03, 0x00,
            0x01, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x02, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x08, 0x00, 0x00, 0x00,
        ])
    ))
    let response = try #require(try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
        from: Data([
            0x90, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
        ])
    ))

    #expect(request.flags == 0x0003)
    #expect(request.channelLists == [
        RDPDynamicVirtualChannelSoftSyncChannelList(
            tunnelType: 1,
            channelIDs: [7, 8]
        ),
    ])
    #expect(response.tunnelsToSwitch == [1, 3])
}

@Test func rejectsInvalidDynamicVirtualChannelSoftSyncPDU() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x84, 0x00,
                0x08, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x08, 0x00, 0x00, 0x00,
                0x00, 0x00,
                0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x08, 0x00, 0x00, 0x00,
                0x03, 0x00,
                0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x08, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x01, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x0e, 0x00, 0x00, 0x00,
                0x03, 0x00,
                0x01, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x01, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x08, 0x00, 0x00, 0x00,
                0x05, 0x00,
                0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x0e, 0x00, 0x00, 0x00,
                0x03, 0x00,
                0x01, 0x00,
                0x02, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x1c, 0x00, 0x00, 0x00,
                0x03, 0x00,
                0x02, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x07, 0x00, 0x00, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x08, 0x00, 0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x80, 0x00,
                0x1c, 0x00, 0x00, 0x00,
                0x03, 0x00,
                0x02, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x07, 0x00, 0x00, 0x00,
                0x03, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x07, 0x00, 0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelSoftSyncPDU.parseIfPresent(
            from: Data([
                0x90, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
            ])
        )
    }
}

@Test func encodesDynamicVirtualChannelCapabilitiesResponse() {
    let response = RDPDynamicVirtualChannelCapabilitiesResponse(version: 2)

    #expect(response.encoded().rdpHexString == "50 00 02 00")
}

@Test func encodesDynamicVirtualChannelVersion3CapabilitiesResponse() {
    let response = RDPDynamicVirtualChannelCapabilitiesResponse(version: 3)

    #expect(response.encoded().rdpHexString == "50 00 03 00")
}

@Test func capsDynamicVirtualChannelNegotiatesWindowsVersion3() {
    let response = RDPDynamicVirtualChannelCapabilitiesResponse(requestedVersion: 3)

    #expect(response.version == RDPDynamicVirtualChannelCapabilitiesResponse.maximumSupportedVersion)
    #expect(response.encoded().rdpHexString == "50 00 03 00")
}

@Test func parsesDynamicVirtualChannelCreateRequest() throws {
    let name = Array(RDPGFXChannel.name.utf8)
    let payload = Data([0x14, 0x07] + name + [0x00])

    let request = try #require(try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: payload))

    #expect(request.channelID == 7)
    #expect(request.priority == 1)
    #expect(request.channelName == RDPGFXChannel.name)
    #expect(request.typeName == "dynvc-create-request")
}

@Test func parsesDynamicVirtualChannelCreateRequestANSIName() throws {
    let payload = Data([0x10, 0x07, 0x43, 0x61, 0x66, 0xE9, 0x00])

    let request = try #require(try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: payload))

    #expect(request.channelID == 7)
    #expect(request.channelName == "Café")
}

@Test func rejectsInvalidDynamicVirtualChannelCreateRequestNames() {
    let name = Array(RDPGFXChannel.name.utf8)

    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: Data([0x14, 0x07] + name))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: Data([0x14, 0x07, 0x00]))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: Data([0x14, 0x07] + name + [0x00, 0x00]))
    }
}

@Test func encodesDynamicVirtualChannelCreateResponse() {
    let response = RDPDynamicVirtualChannelCreateResponse(channelID: 300)

    #expect(response.encoded().rdpHexString == "11 2c 01 00 00 00 00")
}

@Test func parsesAndEncodesDynamicVirtualChannelClosePDU() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelClosePDU.parseIfPresent(
        from: Data([0x41, 0x2c, 0x01])
    ))
    let pduWithUnusedSp = try #require(try RDPDynamicVirtualChannelClosePDU.parseIfPresent(
        from: Data([0x45, 0x2c, 0x01])
    ))

    #expect(pdu.channelID == 300)
    #expect(pdu.typeName == "dynvc-close")
    #expect(pdu.encoded().rdpHexString == "41 2c 01")
    #expect(pduWithUnusedSp.channelID == 300)
}

@Test func rejectsInvalidDynamicVirtualChannelClosePDU() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelClosePDU.parseIfPresent(from: Data([0x40, 0x07, 0x00]))
    }
}

@Test func encodesDynamicVirtualChannelDataPDU() {
    let pdu = RDPDynamicVirtualChannelDataPDU(
        channelID: 7,
        payload: Data([0x12, 0x00])
    )

    #expect(pdu.encoded().rdpHexString == "30 07 12 00")
}

@Test func packetizesDynamicVirtualChannelDataPDUWithoutFragmentationWhenItFits() throws {
    let payload = Data(repeating: 0xAA, count: RDPDynamicVirtualChannelDataPDU.maximumPayloadByteCount(
        channelID: 7
    ))
    let packets = RDPDynamicVirtualChannelDataPacketizer(channelID: 7, payload: payload).encodedPDUs()
    let pdu = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: packets[0]))

    #expect(packets.count == 1)
    #expect(pdu.channelID == 7)
    #expect(pdu.payload == payload)
    #expect(packets[0].count == 1_600)
}

@Test func packetizesLargeDynamicVirtualChannelDataPDUWithDataFirst() throws {
    let payload = Data((0 ..< 2_000).map { UInt8(truncatingIfNeeded: $0) })
    let packets = RDPDynamicVirtualChannelDataPacketizer(channelID: 7, payload: payload).encodedPDUs()
    let first = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(from: packets[0]))
    let second = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: packets[1]))

    #expect(packets.count == 2)
    #expect(packets[0].count == 1_600)
    #expect(first.channelID == 7)
    #expect(first.totalLength == 2_000)
    #expect(first.payload == payload.prefix(1_596))
    #expect(second.channelID == 7)
    #expect(second.payload == payload.suffix(404))
}

@Test func acceptsWindowsAuxiliaryDynamicChannelNames() {
    #expect(RDPWindowsAuxiliaryDynamicChannel.isAcceptedNoOp(RDPInputDynamicChannel.name))
    #expect(RDPWindowsAuxiliaryDynamicChannel.isAcceptedNoOp(RDPCoreInputChannel.name))
    #expect(RDPWindowsAuxiliaryDynamicChannel.isAcceptedNoOp(RDPMouseCursorChannel.name))
    #expect(RDPWindowsAuxiliaryDynamicChannel.isAcceptedNoOp(RDPAudioInputDynamicChannel.name))
    #expect(!RDPWindowsAuxiliaryDynamicChannel.isAcceptedNoOp(RDPGFXChannel.name))
}

@Test func encodesMouseCursorCapsAdvertisePDU() {
    #expect(RDPMouseCursorCapsAdvertisePDU().encoded().rdpHexString == (
        "01 00 00 00 43 41 50 53 01 00 00 00 0c 00 00 00"
    ))
}

@Test func encodesCoreInputInitRequestPDU() {
    #expect(RDPCoreInputInitRequestPDU().encoded().rdpHexString == (
        "03 01 00 00 00 01 00 01 00 00 00 00 00 00 00 00"
    ))
}

@Test func parsesRDPInputServerReadyPDU() throws {
    let pdu = try #require(try RDPInputServerReadyPDU.parseIfPresent(
        from: Data([
            0x01, 0x00,
            0x0e, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
    ))

    #expect(pdu.protocolVersion == .version300)
    #expect(pdu.supportedFeatures == RDPInputServerReadyFeatures.multipenInjectionSupported)
}

@Test func parsesRDPInputServerReadyPDUWithoutOptionalVersionThreeFeatures() throws {
    let pdu = try #require(try RDPInputServerReadyPDU.parseIfPresent(
        from: Data([
            0x01, 0x00,
            0x0a, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00,
        ])
    ))

    #expect(pdu.protocolVersion == .version300)
    #expect(pdu.supportedFeatures == nil)
}

@Test func rejectsInvalidRDPInputServerReadyPDU() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPInputServerReadyPDU.parseIfPresent(
            from: Data([
                0x01, 0x00,
                0x0a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x03, 0x00,
                0x01, 0x00, 0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPInputServerReadyPDU.parseIfPresent(
            from: Data([
                0x01, 0x00,
                0x0e, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x02, 0x00,
                0x01, 0x00, 0x00, 0x00,
            ])
        )
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPInputServerReadyPDU.parseIfPresent(
            from: Data([
                0x01, 0x00,
                0x0e, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x03, 0x00,
                0x02, 0x00, 0x00, 0x00,
            ])
        )
    }
}

@Test func encodesRDPInputClientReadyPDU() {
    #expect(RDPInputClientReadyPDU().encoded().rdpHexString == (
        "02 00 10 00 00 00 00 00 00 00 00 00 01 00 00 00"
    ))
}

@Test func encodesRDPInputClientReadyPDUWithServerProtocolVersion() throws {
    let serverReady = try #require(try RDPInputServerReadyPDU.parseIfPresent(
        from: Data([
            0x01, 0x00,
            0x0e, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00,
            0x01, 0x00, 0x00, 0x00,
        ])
    ))

    #expect(RDPInputClientReadyPDU(serverReady: serverReady).encoded().rdpHexString == (
        "02 00 10 00 00 00 00 00 00 00 00 00 03 00 00 00"
    ))
}

@Test func encodesRDPInputClientReadyPDUWithFlagsAndMaxTouchContacts() {
    let flags = RDPInputClientReadyFlags.showTouchVisuals
        | RDPInputClientReadyFlags.disableTimestampInjection
        | RDPInputClientReadyFlags.enableMultipenInjection
    #expect(RDPInputClientReadyPDU(
        flags: flags,
        protocolVersion: .version300,
        maxTouchContacts: 10
    ).encoded().rdpHexString == (
        "02 00 10 00 00 00 07 00 00 00 00 00 03 00 0a 00"
    ))
}

@Test func parsesRDPInputSuspendAndResumePDUs() throws {
    #expect(try RDPInputSuspendPDU.parseIfPresent(from: Data([
        0x04, 0x00,
        0x06, 0x00, 0x00, 0x00,
    ])) != nil)
    #expect(try RDPInputResumePDU.parseIfPresent(from: Data([
        0x05, 0x00,
        0x06, 0x00, 0x00, 0x00,
    ])) != nil)
}

@Test func rejectsMalformedRDPInputSuspendAndResumePDUs() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPInputSuspendPDU.parseIfPresent(from: Data([
            0x04, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x00,
        ]))
    }
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPInputResumePDU.parseIfPresent(from: Data([
            0x05, 0x00,
            0x06, 0x00, 0x00, 0x00,
            0x00,
        ]))
    }
}

@Test func parsesDynamicVirtualChannelDataFirstPDU() throws {
    let payload = Data(repeating: 0xE0, count: 1_596)
    let pdu = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
        from: Data([0x24, 0x01, 0x40, 0x06]) + payload
    ))

    #expect(pdu.channelID == 1)
    #expect(pdu.totalLength == 1600)
    #expect(pdu.payload == payload)
}

@Test func parsesDynamicVirtualChannelDataFirstVariableLengthFields() throws {
    let oneByteLength = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
        from: Data([0x20, 0x01, 0x03, 0xAA, 0xBB, 0xCC])
    ))
    let fourByteLength = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
        from: Data([0x28, 0x01, 0x05, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    ))

    #expect(oneByteLength.channelID == 1)
    #expect(oneByteLength.totalLength == 3)
    #expect(oneByteLength.payload == Data([0xAA, 0xBB, 0xCC]))
    #expect(fourByteLength.channelID == 1)
    #expect(fourByteLength.totalLength == 5)
    #expect(fourByteLength.payload == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE]))
}

@Test func rejectsDynamicVirtualChannelDataFirstWithInvalidLengthCode() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(from: Data([0x2C, 0x01, 0x00]))
    }
}

@Test func rejectsDynamicVirtualChannelDataFirstPayloadLongerThanTotalLength() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
            from: Data([0x20, 0x01, 0x02, 0xAA, 0xBB, 0xCC])
        )
    }
}

@Test func rejectsDynamicVirtualChannelDataFirstPayloadShorterThanExpectedLength() {
    #expect(throws: RDPDecodeError.invalidDynamicVirtualChannelPDU) {
        try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(
            from: Data([0x20, 0x01, 0x03, 0xAA, 0xBB])
        )
    }
}

@Test func parsesDynamicVirtualChannelDataPDU() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(
        from: Data([0x31, 0x2C, 0x01, 0x12, 0x00])
    ))

    #expect(pdu.channelID == 300)
    #expect(pdu.payload == Data([0x12, 0x00]))
}

@Test func acceptsDynamicVirtualChannelDataPDUWithUnusedSpBits() throws {
    let pdu = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(
        from: Data([0x34, 0x07, 0x12, 0x00])
    ))

    #expect(pdu.channelID == 7)
    #expect(pdu.payload == Data([0x12, 0x00]))
}
