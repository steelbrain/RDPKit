import Foundation
@testable import RDPKit
import Testing

@Test func parsesDemandActivePacket() throws {
    let demandActive = try #require(try RDPDemandActivePDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 3d 02 f0 80 68 00 05 03 eb 70 2f
    2f 00 11 00 ee 03 ee 03 01 00 04 00 19 00 52 44 50 00
    03 00 00 00 01 00 04 00 1c 00 0c 00 52 00 00 00 00 00 00 00 1d 00 05 00 00
    00 00 00 00
    """)))

    #expect(demandActive.channelID == 1003)
    #expect(demandActive.pduSource == 1006)
    #expect(demandActive.shareID == 0x0001_03EE)
    #expect(demandActive.sourceDescriptorText == "RDP\u{0}")
    #expect(demandActive.capabilitySets.count == 3)
    #expect(demandActive.capabilitySets.map(\.name).contains("surface-commands"))
    #expect(demandActive.capabilitySets.map(\.name).contains("bitmap-codecs"))
    #expect(demandActive.sessionID == 0)
}

@Test func rejectsDemandActiveWhenDeclaredLengthLeavesTrailingBytes() {
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(fromTPKT: hexData("""
        03 00 00 3e 02 f0 80 68 00 05 03 eb 70 30
        2f 00 11 00 ee 03 ee 03 01 00 04 00 19 00 52 44 50 00
        03 00 00 00 01 00 04 00 1c 00 0c 00 52 00 00 00 00 00 00 00 1d 00 05 00 00
        00 00 00 00 00
        """))
    }
}

@Test func parsesDemandActiveServerVirtualChannelChunkSize() throws {
    let demandActive = try #require(try RDPDemandActivePDU.parseIfPresent(
        fromTPKT: demandActivePacket(capabilitySets: [
            capabilitySet(type: 0x0014, body: virtualChannelCapabilityBody(chunkSize: 4_096)),
        ])
    ))

    #expect(demandActive.serverVirtualChannelChunkSize == 4_096)
}

@Test func parsesDemandActiveServerInputFlags() throws {
    let demandActive = try #require(try RDPDemandActivePDU.parseIfPresent(
        fromTPKT: demandActivePacket(capabilitySets: [
            capabilitySet(type: 0x000D, body: inputCapabilityBody(inputFlags: 0x0115)),
        ])
    ))

    #expect(demandActive.serverInputFlags == 0x0115)
}

@Test func rejectsDemandActiveServerVirtualChannelChunkSizeOutsideSpecRange() {
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(
            fromTPKT: demandActivePacket(capabilitySets: [
                capabilitySet(type: 0x0014, body: virtualChannelCapabilityBody(chunkSize: 0xFFFF)),
            ])
        )
    }
}

@Test func rejectsDemandActiveWhenCapabilityCountDoesNotConsumeCombinedBlock() {
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(
            fromTPKT: demandActivePacket(
                capabilitySets: [
                    capabilitySet(type: 0x0001, body: Data()),
                    capabilitySet(type: 0x0002, body: Data()),
                ],
                declaredCapabilityCount: 1
            )
        )
    }
}

@Test func rejectsDemandActiveWithMalformedSessionIDSuffix() {
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(
            fromTPKT: demandActivePacket(
                capabilitySets: [capabilitySet(type: 0x0001, body: Data())],
                sessionIDSuffix: Data()
            )
        )
    }
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(
            fromTPKT: demandActivePacket(
                capabilitySets: [capabilitySet(type: 0x0001, body: Data())],
                sessionIDSuffix: Data([0x00])
            )
        )
    }
    #expect(throws: RDPDecodeError.invalidDemandActivePDU) {
        try RDPDemandActivePDU.parseIfPresent(
            fromTPKT: demandActivePacket(
                capabilitySets: [capabilitySet(type: 0x0001, body: Data())],
                sessionIDSuffix: Data([0x00, 0x00, 0x00, 0x00, 0x00])
            )
        )
    }
}

@Test func confirmActiveUsesDemandShareAndAdvertisesGraphicsFriendlyCapabilities() {
    let confirmActive = RDPClientConfirmActivePDU(
        shareID: 0x0001_03EE,
        desktopWidth: 1440,
        desktopHeight: 900
    )
    let userData = confirmActive.encodedPDUData(userChannelID: 1006)
    let packet = confirmActive.encodedTPKT(userChannelID: 1006, ioChannelID: 1003)
    let declaredTotalLength = Int(userData.littleEndianUInt16(at: 0))
    let sourceDescriptorLength = Int(userData.littleEndianUInt16(at: 12))
    let combinedCapabilitiesLength = Int(userData.littleEndianUInt16(at: 14))

    #expect(declaredTotalLength == userData.count)
    #expect(combinedCapabilitiesLength == userData.count - 16 - sourceDescriptorLength)
    #expect(packet.prefix(4) == Data([
        0x03, 0x00,
        UInt8(packet.count >> 8),
        UInt8(packet.count & 0xFF),
    ]))
    #expect(packet.containsSubsequence(Data([
        0xEE, 0x03, 0x01, 0x00,
        0xEA, 0x03, 0x09, 0x00,
    ])))
    #expect(confirmActive.capabilitySets.map(\.name) == [
        "general",
        "bitmap",
        "order",
        "bitmap-cache",
        "activation",
        "control",
        "pointer",
        "share",
        "input",
        "font",
        "brush",
        "glyph-cache",
        "offscreen-cache",
        "virtual-channel",
        "sound",
        "multifragment-update",
        "large-pointer",
        "surface-commands",
        "bitmap-codecs",
        "frame-acknowledge",
    ])
    #expect(packet.containsSubsequence(Data([
        0x02, 0x00, 0x1C, 0x00,
        0x20, 0x00, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00,
        0xA0, 0x05, 0x84, 0x03,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x07, 0x00, 0x0C, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x05, 0x00, 0x0C, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x02, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x08, 0x00, 0x0A, 0x00,
        0x01, 0x00, 0x20, 0x00,
        0x20, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x09, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x0D, 0x00, 0x58, 0x00,
        0x35, 0x01, 0x00, 0x00,
        0x09, 0x04, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x0C, 0x00, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x01, 0x00, 0x18, 0x00,
        0x06, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x05, 0x04,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1A, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x80, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x14, 0x00, 0x0C, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x40, 0x06, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1B, 0x00, 0x06, 0x00,
        0x03, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1C, 0x00, 0x0C, 0x00,
        0x52, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1D, 0x00, 0x5F, 0x00,
        0x02,
        0x12, 0x2F, 0x77, 0x76,
        0x72, 0xBD, 0x63, 0x44,
        0xAF, 0xB3, 0xB7, 0x3C,
        0x9C, 0x6F, 0x78, 0x86,
    ])))
    #expect(packet.containsSubsequence(Data([
        0x1E, 0x00, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ])))
}

@Test func confirmActiveCapabilityFlagsSatisfyGraphicsAndPointerRequirements() throws {
    let confirmActive = RDPClientConfirmActivePDU(shareID: 0x0001_03EE)
    let capabilities = try confirmActive.capabilityBodies(userChannelID: 1006)

    let general = try #require(capabilities[0x0001])
    let extraFlags = general.littleEndianUInt16(at: 10)
    #expect(general.littleEndianUInt16(at: 8) == 0)
    #expect(general.littleEndianUInt16(at: 16) == 0)
    #expect(extraFlags & 0x0001 != 0)
    #expect(extraFlags & 0x0004 != 0)
    #expect(extraFlags & 0x0400 != 0)

    let bitmap = try #require(capabilities[0x0002])
    #expect(bitmap[19] == 0x0E)

    let multifragmentUpdate = try #require(capabilities[0x001A])
    #expect(multifragmentUpdate.littleEndianUInt32(at: 0) >= 608_299)

    let largePointer = try #require(capabilities[0x001B])
    #expect(largePointer.littleEndianUInt16(at: 0) == 0x0003)

    let surfaceCommands = try #require(capabilities[0x001C])
    #expect(surfaceCommands.littleEndianUInt32(at: 0) & 0x0000_0040 != 0)

    let bitmapCodecs = try #require(capabilities[0x001D])
    #expect(bitmapCodecs.count == 91)
    #expect(bitmapCodecs[0] == 2)
    #expect(bitmapCodecs.containsSubsequence(Data([
        0xB9, 0x1B, 0x8D, 0xCA,
        0x0F, 0x00, 0x4F, 0x15,
        0x58, 0x9F, 0xAE, 0x2D,
        0x1A, 0x87, 0xE2, 0xD6,
        0x01, 0x03, 0x00,
        0x01, 0x01, 0x03,
    ])))
}

@Test func confirmActiveExposesItsAdvertisedMultifragmentBufferSize() throws {
    let full = RDPClientConfirmActivePDU(shareID: 1)
    let compact = RDPClientConfirmActivePDU(
        shareID: 1,
        includeActivationControlShareCapabilities: false
    )

    #expect(full.multifragmentUpdateMaxRequestSize == 0x0080_0000)
    #expect(compact.multifragmentUpdateMaxRequestSize == 0x0001_0000)
    #expect(try #require(full.capabilityBodies(userChannelID: 1006)[0x001A]).littleEndianUInt32(at: 0)
        == UInt32(full.multifragmentUpdateMaxRequestSize))
    #expect(try #require(compact.capabilityBodies(userChannelID: 1006)[0x001A]).littleEndianUInt32(at: 0)
        == UInt32(compact.multifragmentUpdateMaxRequestSize))
}

@Test func confirmActiveCanUseCompactCapabilitySetForKRDPCompatibility() throws {
    let confirmActive = RDPClientConfirmActivePDU(
        shareID: 0x0001_03EE,
        includeActivationControlShareCapabilities: false
    )

    // Compact Confirm Active retains every mandatory capability set while
    // omitting optional sets that are not needed by minimal Demand Active servers.
    #expect(confirmActive.capabilitySets.map(\.name) == [
        "general",
        "bitmap",
        "order",
        "bitmap-cache",
        "pointer",
        "input",
        "font",
        "brush",
        "glyph-cache",
        "offscreen-cache",
        "virtual-channel",
        "multifragment-update",
        "large-pointer",
        "surface-commands",
    ])
    let userData = confirmActive.encodedPDUData(userChannelID: 1006)
    let declaredTotalLength = Int(userData.littleEndianUInt16(at: 0))
    // MS-RDPBCGR 2.2.8.1.1.1.1: totalLength includes the Share Control Header.
    #expect(declaredTotalLength == userData.count)
    // originatorID MUST be server channel ID 0x03EA (2.2.1.13.2.1).
    #expect(userData.littleEndianUInt16(at: 10) == RDPServerChannelID.fixed)

    let capabilities = try confirmActive.capabilityBodies(userChannelID: 1006)
    let virtualChannel = try #require(capabilities[0x0014])
    // MS-RDPBCGR 2.2.7.1.10: VCChunkSize MUST be in 1,600...16,256.
    #expect(virtualChannel.littleEndianUInt32(at: 4) == UInt32(RDPStaticVirtualChannelPDU.maximumPayloadByteCount))
}

@Test func confirmActiveTotalLengthMatchesEncodedUserDataForFullAndCompactPaths() {
    for includeExtras in [true, false] {
        let confirmActive = RDPClientConfirmActivePDU(
            shareID: 0x0001_03EE,
            includeActivationControlShareCapabilities: includeExtras
        )
        let userData = confirmActive.encodedPDUData(userChannelID: 1006)
        #expect(Int(userData.littleEndianUInt16(at: 0)) == userData.count)
    }
}

@Test func parsesServerSynchronizeShareData() throws {
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(fromTPKT: hexData("""
    03 00 00 25 02 f0 80 68 00 05 03 eb 70 80 16 16 00 17 00 ee 03 ee 03 01
    00 00 01 04 00 1f 00 00 00 01 00 ee 03
    """)))

    #expect(shareData.channelID == 1003)
    #expect(shareData.shareID == 0x0001_03EE)
    #expect(shareData.pduSource == 1006)
    #expect(shareData.pduType2 == 0x1F)
    #expect(shareData.typeName == "server-synchronize")
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}

private func demandActivePacket(
    capabilitySets: [Data],
    declaredCapabilityCount: UInt16? = nil,
    sessionIDSuffix: Data = Data([0x00, 0x00, 0x00, 0x00])
) -> Data {
    let sourceDescriptor = Data("RDP\u{0}".utf8)
    let capabilityBytes = capabilitySets.reduce(into: Data()) { $0.append($1) }
    let combinedCapabilitiesLength = 4 + capabilityBytes.count
    let totalLength = 6 + 4 + 2 + 2 + sourceDescriptor.count + combinedCapabilitiesLength + sessionIDSuffix.count

    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(totalLength))
    userData.appendLittleEndianUInt16(0x0011)
    userData.appendLittleEndianUInt16(1006)
    userData.appendLittleEndianUInt32(0x0001_03EE)
    userData.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
    userData.appendLittleEndianUInt16(UInt16(combinedCapabilitiesLength))
    userData.append(sourceDescriptor)
    userData.appendLittleEndianUInt16(declaredCapabilityCount ?? UInt16(capabilitySets.count))
    userData.appendLittleEndianUInt16(0)
    userData.append(capabilityBytes)
    userData.append(sessionIDSuffix)

    var mcsData = Data()
    mcsData.appendUInt8(0x68)
    mcsData.appendBigEndianUInt16(1006 - 1001)
    mcsData.appendBigEndianUInt16(1003)
    mcsData.appendUInt8(0x70)
    mcsData.appendPERLength(userData.count)
    mcsData.append(userData)
    return X224DataTPDU.wrap(mcsData)
}

private func capabilitySet(type: UInt16, body: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(type)
    data.appendLittleEndianUInt16(UInt16(body.count + 4))
    data.append(body)
    return data
}

private func virtualChannelCapabilityBody(chunkSize: UInt32) -> Data {
    var data = Data()
    data.appendLittleEndianUInt32(0)
    data.appendLittleEndianUInt32(chunkSize)
    return data
}

private func inputCapabilityBody(inputFlags: UInt16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(inputFlags)
    data.append(Data(repeating: 0, count: 82))
    return data
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
}

private extension RDPClientConfirmActivePDU {
    func capabilityBodies(userChannelID: UInt16) throws -> [UInt16: Data] {
        let userData = encodedPDUData(userChannelID: userChannelID)
        let sourceDescriptorLength = Int(userData.littleEndianUInt16(at: 12))
        var offset = 16 + sourceDescriptorLength
        let capabilityCount = Int(userData.littleEndianUInt16(at: offset))
        offset += 4

        var capabilities: [UInt16: Data] = [:]
        for _ in 0 ..< capabilityCount {
            let type = userData.littleEndianUInt16(at: offset)
            let length = Int(userData.littleEndianUInt16(at: offset + 2))
            capabilities[type] = Data(userData[(offset + 4) ..< (offset + length)])
            offset += length
        }
        return capabilities
    }
}
