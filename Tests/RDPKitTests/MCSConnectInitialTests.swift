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
    #expect(gcc.containsSubsequence(Data([0x01, 0xC0, 0xD8, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x04, 0xC0, 0x0C, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x02, 0xC0, 0x0C, 0x00])))
    #expect(gcc.containsSubsequence(Data([0x03, 0xC0, 0x14, 0x00])))
    #expect(!gcc.containsSubsequence(Data([0x06, 0xC0, 0x08, 0x00])))
}

@Test func clientCoreDataCarriesSelectedProtocolAndScreenSize() {
    let pdu = MCSConnectInitialPDU(configuration: MCSConnectInitialConfiguration(
        desktopWidth: 1440,
        desktopHeight: 900,
        selectedProtocol: [.tls, .credSSP]
    ))
    let core = pdu.encodedClientCoreData()

    #expect(core.prefix(4) == Data([0x01, 0xC0, 0xD8, 0x00]))
    #expect(core[8] == 0xA0)
    #expect(core[9] == 0x05)
    #expect(core[10] == 0x84)
    #expect(core[11] == 0x03)
    #expect(core.suffix(4) == Data([0x03, 0x00, 0x00, 0x00]))
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
        0x00, 0x00, 0xA0, 0xC0,
        0x63, 0x6C, 0x69, 0x70, 0x72, 0x64, 0x72, 0x00,
        0x00, 0x00, 0xA0, 0xC0,
    ]))
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
        0x00, 0x00, 0xA0, 0xC0,
        0x63, 0x6C, 0x69, 0x70, 0x72, 0x64, 0x72, 0x00,
        0x00, 0x00, 0xA0, 0xC0,
        0x72, 0x64, 0x70, 0x64, 0x72, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x80, 0xC0,
        0x72, 0x64, 0x70, 0x73, 0x6E, 0x64, 0x00, 0x00,
        0x00, 0x00, 0x80, 0xC0,
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
}
