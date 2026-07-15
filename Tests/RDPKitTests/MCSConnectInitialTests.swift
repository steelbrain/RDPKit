import Foundation
@testable import RDPKit
import Testing

@Test func mcsConnectInitialWrapsInTPKTAndX224Data() throws {
    let packet = MCSConnectInitialPDU().encodedTPKT()
    let payload = try TPKT.unwrap(packet)

    #expect(packet.count == Int(UInt16(packet[2]) << 8 | UInt16(packet[3])))
    #expect(payload.prefix(5) == Data([0x02, 0xF0, 0x80, 0x7F, 0x65]))
}

@Test func mcsConnectInitialUsesExpectedDomainParameters() throws {
    let packet = MCSConnectInitialPDU().encodedTPKT()
    let payload = try TPKT.unwrap(packet)

    #expect(payload.containsSubsequence(Data([
        0x30, 0x19,
        0x02, 0x01, 0x22,
        0x02, 0x01, 0x02,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x02, 0xFF, 0xFF,
        0x02, 0x01, 0x02,
    ])))
}

@Test func gccConferenceCreateRequestContainsDucaAndClientBlocks() {
    let pdu = MCSConnectInitialPDU()
    let gcc = pdu.encodedGCCConnectData()

    #expect(gcc.prefix(7) == Data([0x00, 0x05, 0x00, 0x14, 0x7C, 0x00, 0x01]))
    #expect(gcc.containsSubsequence(Data([0x44, 0x75, 0x63, 0x61])))
    // CS_CORE with full optional tail: type 0xC001, length 234 (0x00EA).
    #expect(gcc.containsSubsequence(Data([0x01, 0xC0, 0xEA, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x04, 0xC0, 0x0C, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x02, 0xC0, 0x0C, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x03, 0xC0, 0x14, 0x00])))
    #expect(!gcc.containsSubsequence(Data([0x06, 0xC0, 0x08, 0x00])))
}

@Test func clientDataBlocksFollowBasicSettingsOrder() {
    let blocks = MCSConnectInitialPDU().encodedClientDataBlocks()

    // core → cluster → security → network
    #expect(blockTypes(in: blocks) == [
        0xC001,
        0xC004,
        0xC002,
        0xC003,
    ])
}

@Test func clientCoreDataCarriesSelectedProtocolAndScreenSize() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        desktopWidth: 1440,
        desktopHeight: 900,
        selectedProtocol: .tls
    ))
    let core = pdu.encodedClientCoreData()

    // MS-RDPBCGR 2.2.1.3.2 full optional tail through deviceScaleFactor.
    #expect(core.count == 234)
    #expect(core.prefix(4) == Data([0x01, 0xC0, 0xEA, 0x00]))
    #expect(core[8] == 0xA0)
    #expect(core[9] == 0x05)
    #expect(core[10] == 0x84)
    #expect(core[11] == 0x03)
    #expect(core.littleEndianUInt16(at: 144) == 0x01AF)
    // CONNECTION_TYPE_AUTODETECT when VALID_CONNECTION_TYPE + NETCHAR_AUTODETECT.
    #expect(core[210] == 0x07)
    #expect(core.littleEndianUInt32(at: 212) == 0x0000_0001)
    #expect(core.littleEndianUInt32(at: 216) == 0)
    #expect(core.littleEndianUInt32(at: 220) == 0)
    #expect(core.littleEndianUInt16(at: 224) == 0)
    #expect(core.littleEndianUInt32(at: 226) == 100)
    #expect(core.littleEndianUInt32(at: 230) == 100)
}

@Test func clientCoreDataNullTerminatesMaximumLengthClientName() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        clientName: "ABCDEFGHIJKLMNO"
    ))
    let core = pdu.encodedClientCoreData()

    #expect(core.littleEndianUInt16(at: 52) == 0x004F)
    #expect(core.littleEndianUInt16(at: 54) == 0)
}

@Test func clientCoreDataTruncatesOverlongClientNameBeforeNullTerminator() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        clientName: "ABCDEFGHIJKLMNOP"
    ))
    let core = pdu.encodedClientCoreData()

    #expect(core.littleEndianUInt16(at: 52) == 0x004F)
    #expect(core.littleEndianUInt16(at: 54) == 0)
}

@Test func clientCoreDataAdvertisesDynamicGraphicsOnlyWithDrdynvcChannel() {
    let defaultCore = MCSConnectInitialPDU().encodedClientCoreData()
    let clipboardOnlyCore = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        channels: [.cliprdr]
    )).encodedClientCoreData()

    #expect(defaultCore.littleEndianUInt16(at: 144) & 0x0100 != 0)
    #expect(clipboardOnlyCore.littleEndianUInt16(at: 144) & 0x0100 == 0)
    #expect(clipboardOnlyCore.littleEndianUInt16(at: 144) & 0x0080 != 0)
}

@Test func clientCoreDataDoesNotAdvertiseProblematicEarlyCapabilityFlags() {
    let core = MCSConnectInitialPDU().encodedClientCoreData()
    let earlyCapabilityFlags = core.littleEndianUInt16(at: 144)

    #expect(earlyCapabilityFlags & 0x0040 == 0)
    #expect(earlyCapabilityFlags & 0x0800 == 0)
}

@Test func clientCoreDataAvoidsProblematicFlagsAcrossChannelConfigurations() {
    let configurations = [
        MCSConnectInitialConfiguration(channels: [.drdynvc]),
        MCSConnectInitialConfiguration(channels: [.cliprdr]),
        MCSConnectInitialConfiguration(channels: [.drdynvc, .cliprdr]),
        MCSConnectInitialConfiguration(channels: [.drdynvc, .cliprdr, .rdpdr, .rdpsnd]),
    ]

    for configuration in configurations {
        let core = MCSConnectInitialPDU(configuration: configuration).encodedClientCoreData()
        let earlyCapabilityFlags = core.littleEndianUInt16(at: 144)

        #expect(earlyCapabilityFlags & 0x0040 == 0)
        #expect(earlyCapabilityFlags & 0x0800 == 0)
    }
}

@Test func clientNetworkDataAdvertisesStaticVirtualChannels() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        channels: [.drdynvc, .cliprdr]
    ))
    let network = pdu.encodedClientNetworkData()

    #expect(network == Data([
        0x03, 0xC0, 0x20, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x64, 0x72, 0x64, 0x79, 0x6E, 0x76, 0x63, 0x00,
        0x00, 0x00, 0x80, 0xC0,
        0x63, 0x6C, 0x69, 0x70, 0x72, 0x64, 0x72, 0x00,
        0x00, 0x00, 0x80, 0xC0,
    ]))
}

@Test func clientSecurityDataAdvertisesValidEncryptionMethods() {
    let security = MCSConnectInitialPDU().encodedClientSecurityData()

    #expect(security == Data([
        0x02, 0xC0, 0x0C, 0x00,
        0x1B, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))
}

@Test func clientClusterDataAdvertisesRedirectionSupportWithoutSessionID() {
    let cluster = MCSConnectInitialPDU().encodedClientClusterData()

    #expect(cluster == Data([
        0x04, 0xC0, 0x0C, 0x00,
        0x0D, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(cluster.littleEndianUInt32(at: 4) & 0x0000_0001 != 0)
    #expect(cluster.littleEndianUInt32(at: 4) & 0x0000_003C == 0x0000_000C)
    #expect(cluster.littleEndianUInt32(at: 8) == 0)
}

@Test func clientClusterDataCarriesRedirectedSessionIDOnReconnect() {
    let cluster = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        redirectedSessionID: 0x1234_5678
    )).encodedClientClusterData()

    #expect(cluster == Data([
        0x04, 0xC0, 0x0C, 0x00,
        0x0F, 0x00, 0x00, 0x00,
        0x78, 0x56, 0x34, 0x12,
    ]))
    #expect(cluster.littleEndianUInt32(at: 4) & 0x0000_0001 != 0)
    #expect(cluster.littleEndianUInt32(at: 4) & 0x0000_0002 != 0)
    #expect(cluster.littleEndianUInt32(at: 4) & 0x0000_003C == 0x0000_000C)
    #expect(cluster.littleEndianUInt32(at: 8) == 0x1234_5678)
}

@Test func staticVirtualChannelOptionsMatchWindowsCompatibleDefaults() {
    #expect(RDPStaticVirtualChannel.drdynvc.options == 0xC080_0000)
    // 0.1.0 cliprdr: initialized | encryptRDP | compressRDP
    #expect(RDPStaticVirtualChannel.cliprdr.options == 0xC080_0000)
    #expect(RDPStaticVirtualChannel.rdpdr.options == 0x8000_0000)
    #expect(RDPStaticVirtualChannel.rdpsnd.options == 0xC000_0000)
}

@Test func staticVirtualChannelOptionsDoNotAdvertiseRawCompression() {
    for channel in [
        RDPStaticVirtualChannel.drdynvc,
        RDPStaticVirtualChannel.cliprdr,
        RDPStaticVirtualChannel.rdpdr,
        RDPStaticVirtualChannel.rdpsnd,
    ] {
        #expect(channel.options & ChannelOptions.compress == 0)
    }
}

@Test func clientNetworkDataAdvertisesAudioStaticVirtualChannel() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        channels: [.drdynvc, .cliprdr, .rdpdr, .rdpsnd]
    ))
    let network = pdu.encodedClientNetworkData()

    #expect(network == Data([
        0x03, 0xC0, 0x38, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x64, 0x72, 0x64, 0x79, 0x6E, 0x76, 0x63, 0x00,
        0x00, 0x00, 0x80, 0xC0,
        0x63, 0x6C, 0x69, 0x70, 0x72, 0x64, 0x72, 0x00,
        0x00, 0x00, 0x80, 0xC0,
        0x72, 0x64, 0x70, 0x64, 0x72, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x80,
        0x72, 0x64, 0x70, 0x73, 0x6E, 0x64, 0x00, 0x00,
        0x00, 0x00, 0x00, 0xC0,
    ]))
}

@Test func clientMessageChannelDataIsAdvertisedWhenExtendedDataIsSupported() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        advertiseMessageChannel: true
    ))

    #expect(pdu.encodedClientMessageChannelData() == Data([
        0x06, 0xC0, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(pdu.encodedGCCConnectData().containsSubsequence(Data([
        0x06, 0xC0, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])))
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }

    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

private func blockTypes(in data: Data) -> [UInt16] {
    var offset = 0
    var types: [UInt16] = []
    while offset + 4 <= data.count {
        let type = data.littleEndianUInt16(at: offset)
        let length = Int(data.littleEndianUInt16(at: offset + 2))
        types.append(type)
        offset += length
    }
    return types
}
