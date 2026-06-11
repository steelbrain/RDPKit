import Foundation
@testable import RDPKit
import Testing

@Test func parsesSuccessfulMCSConnectResponseServerChannels() throws {
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(),
        requestedChannels: [.drdynvc]
    )

    #expect(response.result == 0)
    #expect(response.resultName == "rt-successful")
    #expect(response.calledConnectID == 0)
    #expect(response.serverUserDataKey == "McDn")
    #expect(response.ioChannelID == 1003)
    #expect(response.messageChannelID == 1005)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
}

@Test func rejectsMCSConnectResponseWithWrongApplicationType() throws {
    let packet = TPKT.wrap(Data([0x02, 0xF0, 0x80, 0x7F, 0x65, 0x00]))

    do {
        _ = try MCSConnectResponse.parse(fromTPKT: packet)
        Issue.record("expected invalid MCS Connect Response header")
    } catch RDPDecodeError.invalidMCSConnectResponseHeader {
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func sampleMCSConnectResponse() -> Data {
    let domainParameters = Data([
        0x30, 0x1A,
        0x02, 0x01, 0x22,
        0x02, 0x01, 0x03,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x03, 0x00, 0xFF, 0xF8,
        0x02, 0x01, 0x02,
    ])
    let serverNetworkData = Data([
        0x03, 0x0C, 0x0C, 0x00,
        0xEB, 0x03,
        0x01, 0x00,
        0xEC, 0x03,
        0x00, 0x00,
    ])
    let serverMessageChannelData = Data([
        0x04, 0x0C, 0x06, 0x00,
        0xED, 0x03,
    ])
    let serverBlocks = serverNetworkData + serverMessageChannelData
    let gccConnectData = Data([
        0x00, 0x05,
        0x00, 0x14, 0x7C, 0x00, 0x01,
        0x2A,
        0x14, 0x76, 0x0A, 0x01, 0x01, 0x00, 0x01, 0xC0, 0x00,
        0x4D, 0x63, 0x44, 0x6E,
        UInt8(serverBlocks.count),
    ]) + serverBlocks

    var mcsFields = Data()
    mcsFields.append(contentsOf: [0x0A, 0x01, 0x00])
    mcsFields.append(contentsOf: [0x02, 0x01, 0x00])
    mcsFields.append(domainParameters)
    mcsFields.append(berOctetString(gccConnectData))

    var mcs = Data()
    mcs.append(contentsOf: [0x7F, 0x66])
    mcs.append(berLength(mcsFields.count))
    mcs.append(mcsFields)

    return TPKT.wrap(Data([0x02, 0xF0, 0x80]) + mcs)
}

private func berOctetString(_ value: Data) -> Data {
    var data = Data([0x04])
    data.append(berLength(value.count))
    data.append(value)
    return data
}

private func berLength(_ length: Int) -> Data {
    if length < 0x80 {
        return Data([UInt8(length)])
    }

    return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
}
