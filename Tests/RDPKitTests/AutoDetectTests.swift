import Foundation
@testable import RDPKit
import Testing

@Test func parsesConnectTimeRTTMeasureRequest() throws {
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x19,
        0x02, 0xF0, 0x80,
        0x68, 0x00, 0x04, 0x00, 0x00, 0x70, 0x80, 0x0A,
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00, 0x23, 0x00, 0x01, 0x10,
    ])))

    #expect(request.channelID == 0)
    #expect(request.sequenceNumber == 0x0023)
    #expect(request.requestType == 0x1001)
    #expect(request.requestTypeName == "connect-time-rtt-measure-request")
}

@Test func ignoresNonAutoDetectSendDataIndication() throws {
    let packet = MCSSendDataRequestPDU(
        initiator: 1005,
        channelID: 1003,
        userData: Data([0x40, 0x00, 0x00, 0x00])
    ).encodedTPKT()

    #expect(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: packet) == nil)
}

@Test func autoDetectRTTResponseMatchesExpectedBytes() {
    let response = RDPClientAutoDetectResponsePDU(sequenceNumber: 0x0023)

    #expect(response.encodedTPKT(userChannelID: 1005, messageChannelID: 0) == Data([
        0x03, 0x00, 0x00, 0x18,
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x04, 0x00, 0x00, 0x70, 0x0A,
        0x00, 0x20, 0x00, 0x00,
        0x06, 0x01, 0x23, 0x00, 0x00, 0x00,
    ]))
}
