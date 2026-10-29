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

/// MS-RDPBCGR 2.2.1.3.2: keyboardLayout follows SASSequence, 16 bytes into the block;
/// keyboardType, keyboardSubType and keyboardFunctionKey follow clientName, then imeFileName.
@Test func clientCoreDataCarriesTheKeyboard() {
    let defaultCore = MCSConnectInitialPDU().encodedClientCoreData()
    let japaneseCore = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        keyboard: RDPClientKeyboard(layout: RDPKeyboardLayout(rawValue: 0xE001_0411), type: .japanese, subType: 2, functionKeyCount: 12)
    )).encodedClientCoreData()

    #expect(defaultCore[16 ..< 20] == hexData("09 04 00 00"))
    #expect(defaultCore[56 ..< 132] == hexData("04 00 00 00 00 00 00 00 0c 00 00 00") + Data(repeating: 0, count: 64))
    #expect(japaneseCore[16 ..< 20] == hexData("11 04 01 e0"))
    #expect(japaneseCore[56 ..< 132] == hexData("07 00 00 00 02 00 00 00 0c 00 00 00") + Data(repeating: 0, count: 64))
    // Nothing else moves.
    #expect(japaneseCore[..<16] == defaultCore[..<16])
    #expect(japaneseCore[20 ..< 56] == defaultCore[20 ..< 56])
    #expect(japaneseCore[132...] == defaultCore[132...])
}

/// MS-RDPBCGR 2.2.1.3.2: desktopPhysicalWidth and desktopPhysicalHeight at 216 and 220,
/// desktopOrientation at 224, desktopScaleFactor and deviceScaleFactor at 226 and 230.
@Test func clientCoreDataCarriesScaleFactorsAndPhysicalSize() {
    let defaultCore = MCSConnectInitialPDU().encodedClientCoreData()
    let scaledCore = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 200, deviceScaleFactor: 180),
        physicalSize: RDPDisplayPhysicalSize(widthMillimeters: 600, heightMillimeters: 340)
    )).encodedClientCoreData()

    #expect(defaultCore[216...] == hexData("00 00 00 00 00 00 00 00 00 00 64 00 00 00 64 00 00 00"))
    #expect(scaledCore[216...] == hexData("58 02 00 00 54 01 00 00 00 00 c8 00 00 00 b4 00 00 00"))
    // Nothing else moves, the early capability flags included.
    #expect(scaledCore[..<216] == defaultCore[..<216])
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

@Test func clientCoreDataDoesNotSplitSurrogatePairWhenTruncatingClientName() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        clientName: "ABCDEFGHIJKLMN\u{1F600}"
    ))
    let core = pdu.encodedClientCoreData()

    #expect(core.littleEndianUInt16(at: 50) == 0x004E)
    #expect(core.littleEndianUInt16(at: 52) == 0)
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
        #expect(channel.options & 0x0040_0000 == 0) // CHANNEL_OPTION_COMPRESS
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

/// A primary monitor with one left of it, lower down, so the second has a negative left.
private func twoMonitorLayout() throws -> RDPMonitorLayout {
    try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 1920, height: 1080),
        RDPDisplayControlMonitorLayout(
            left: -1280,
            top: 120,
            width: 1280,
            height: 1024,
            physicalWidth: 380,
            physicalHeight: 300,
            orientation: 90,
            desktopScaleFactor: 150,
            deviceScaleFactor: 140
        ),
    ])
}

/// MS-RDPBCGR 2.2.1.3.6: CS_MONITOR (0xC005), flags 0, monitorCount, then a TS_MONITOR_DEF for
/// each monitor with right and bottom inclusive and TS_MONITOR_PRIMARY on the primary one.
@Test func clientMonitorDataDefinesEachMonitor() throws {
    #expect(try MCSConnectInitialPDU().encodedClientMonitorData(twoMonitorLayout()) == hexData("""
    05 c0 34 00
    00 00 00 00 02 00 00 00
    00 00 00 00 00 00 00 00 7f 07 00 00 37 04 00 00 01 00 00 00
    00 fb ff ff 78 00 00 00 ff ff ff ff 77 04 00 00 00 00 00 00
    """))
}

/// MS-RDPBCGR 2.2.1.3.9: CS_MONITOR_EX (0xC008), flags 0, monitorAttributeSize 20,
/// monitorCount, then each monitor's physical size, orientation and scale factors.
@Test func clientMonitorExtendedDataCarriesEachMonitorsAttributes() throws {
    #expect(try MCSConnectInitialPDU().encodedClientMonitorExtendedData(twoMonitorLayout()) == hexData("""
    08 c0 38 00
    00 00 00 00 14 00 00 00 02 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 64 00 00 00 64 00 00 00
    7c 01 00 00 2c 01 00 00 5a 00 00 00 96 00 00 00 8c 00 00 00
    """))
}

/// With a monitor layout the desktop is its bounding box, and the client says it reads the
/// Monitor Layout PDU (RNS_UD_CS_SUPPORT_MONITOR_LAYOUT_PDU, MS-RDPBCGR 2.2.1.3.2). Nothing
/// else in the Client Core Data moves.
@Test func clientCoreDataWithMonitorsRequestsTheirBoundingBox() throws {
    let defaultCore = MCSConnectInitialPDU().encodedClientCoreData()
    let core = try MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        desktopWidth: 1440,
        desktopHeight: 900,
        monitorLayout: twoMonitorLayout()
    )).encodedClientCoreData()

    #expect(core[8 ..< 12] == hexData("80 0c 78 04"))
    #expect(core.littleEndianUInt16(at: 144) == 0x01EF)
    #expect(core[..<8] == defaultCore[..<8])
    #expect(core[12 ..< 144] == defaultCore[12 ..< 144])
    #expect(core[146...] == defaultCore[146...])
}

/// Client Core Data requests a bounding box wider than 8192 pixels as it is: a server takes a
/// desktop past its largest as that largest (MS-RDPBCGR 3.3.5.3.3), and Windows 11 and
/// gnome-remote-desktop 51 make the desktop of the monitors (observed live). Client Monitor
/// Data allows 32,766 pixels each way (2.2.1.3.6).
@Test func clientCoreDataRequestsABoundingBoxWiderThan8192Pixels() throws {
    let layout = try RDPMonitorLayout(monitors: [
        .singlePrimary(width: 3840, height: 2160),
        RDPDisplayControlMonitorLayout(left: 3840, width: 3840, height: 2160),
        RDPDisplayControlMonitorLayout(left: 7680, width: 3840, height: 2160),
    ])
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(monitorLayout: layout))

    #expect(pdu.encodedClientCoreData()[8 ..< 12] == hexData("00 2d 70 08"))
    #expect(pdu.encodedClientMonitorData(layout) == hexData("""
    05 c0 48 00
    00 00 00 00 03 00 00 00
    00 00 00 00 00 00 00 00 ff 0e 00 00 6f 08 00 00 01 00 00 00
    00 0f 00 00 00 00 00 00 ff 1d 00 00 6f 08 00 00 00 00 00 00
    00 1e 00 00 00 00 00 00 ff 2c 00 00 6f 08 00 00 00 00 00 00
    """))
}

/// The monitor blocks follow the network block and go before the message channel's.
@Test func clientDataBlocksCarryTheMonitorLayout() throws {
    let blocks = try MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        advertiseMessageChannel: true,
        monitorLayout: twoMonitorLayout()
    )).encodedClientDataBlocks()

    #expect(blockTypes(in: blocks) == [0xC001, 0xC004, 0xC002, 0xC003, 0xC005, 0xC008, 0xC006])
}

/// Without a layout nothing changes: no monitor blocks, and no Monitor Layout PDU flag.
@Test func clientDataBlocksWithoutAMonitorLayoutAreUnchanged() {
    let blocks = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        advertiseMessageChannel: true
    )).encodedClientDataBlocks()

    #expect(blockTypes(in: blocks) == [0xC001, 0xC004, 0xC002, 0xC003, 0xC006])
    #expect(blocks.littleEndianUInt16(at: 144) == 0x01AF)
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
