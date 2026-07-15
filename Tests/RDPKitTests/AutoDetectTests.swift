import Foundation
@testable import RDPKit
import Testing

@Test func autoDetectResponseTypeConstantsMatchSpecValues() {
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.rtt == 0x0000)
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.bandwidthMeasureResults == 0x0003)
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.continuousBandwidthMeasureResults == 0x000B)
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.networkCharacteristicsSync == 0x0018)
}

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
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func postConnectRTTMeasureRequestBuildsRTTResponse() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x0A)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00,
        0x23, 0x00,
        0x01, 0x00,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.requestTypeName == "rtt-measure-request")
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func parsesBandwidthMeasureStopRequestWithPayload() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x10)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x08, 0x00,
        0x23, 0x00,
        0x2B, 0x00,
        0x04, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD,
    ])
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.channelID == 1005)
    #expect(request.sequenceNumber == 0x0023)
    #expect(request.requestType == 0x002B)
    #expect(request.requestTypeName == "bandwidth-measure-stop")
    #expect(request.payloadByteCount == 4)
    #expect(request.measuredByteCountContribution == 12)
}

@Test func rejectsAutoDetectRequestWhenDeclaredHeaderLengthExceedsPayload() {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x0A)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x08, 0x00,
        0x23, 0x00,
        0x2B, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidAutoDetectRequest) {
        try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu))
    }
}

@Test func rejectsBandwidthMeasureStopWithoutRequiredPayload() {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x0C)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x08, 0x00,
        0x23, 0x00,
        0x2B, 0x00,
        0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidAutoDetectRequest) {
        try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu))
    }
}

@Test func parsesBandwidthMeasurePayloadWithoutResponse() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x0D)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x08, 0x00,
        0x23, 0x00,
        0x02, 0x00,
        0x01, 0x00,
        0xAA,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.requestTypeName == "bandwidth-measure-payload")
    #expect(request.payloadByteCount == 1)
    #expect(request.measuredByteCountContribution == 9)
    #expect(request.response() == nil)
}

@Test func parsesConnectTimeBandwidthMeasureStartWithNetworkCharacteristicsSyncResponse() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x0A)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x06, 0x00,
        0x23, 0x00,
        0x14, 0x10,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.requestTypeName == "connect-time-bandwidth-measure-start")
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.networkCharacteristicsSync)
    #expect(request.resetsMeasuredByteCount)
}

@Test func bandwidthMeasureStartRequestsResetMeasuredByteCount() {
    #expect(RDPServerAutoDetectRequest(
        channelID: 1005,
        sequenceNumber: 1,
        requestType: 0x0014,
        payloadByteCount: 0
    ).resetsMeasuredByteCount)
    #expect(RDPServerAutoDetectRequest(
        channelID: 1005,
        sequenceNumber: 1,
        requestType: 0x0114,
        payloadByteCount: 0
    ).resetsMeasuredByteCount)
    #expect(!RDPServerAutoDetectRequest(
        channelID: 1005,
        sequenceNumber: 1,
        requestType: 0x0002,
        payloadByteCount: 4
    ).resetsMeasuredByteCount)
}

@Test func parsesNetworkCharacteristicsBandwidthResultWithCompatibilityResponse() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x12)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x0E, 0x00,
        0x23, 0x00,
        0x80, 0x08,
        0x40, 0x42, 0x0F, 0x00,
        0x20, 0x00, 0x00, 0x00,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.requestTypeName == "network-characteristics-bandwidth")
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func parsesNetworkCharacteristicsRTTBandwidthResultWithCompatibilityResponse() throws {
    var pdu = Data()
    pdu.appendUInt8(0x68)
    pdu.appendBigEndianUInt16(5)
    pdu.appendBigEndianUInt16(1005)
    pdu.appendUInt8(0x70)
    pdu.appendUInt8(0x16)
    pdu.append(contentsOf: [
        0x00, 0x10, 0x00, 0x00,
        0x12, 0x00,
        0x23, 0x00,
        0xC0, 0x08,
        0x10, 0x00, 0x00, 0x00,
        0x40, 0x42, 0x0F, 0x00,
        0x20, 0x00, 0x00, 0x00,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.requestTypeName == "network-characteristics-rtt-bandwidth")
    #expect(request.response()?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
}

@Test func bandwidthMeasureStopRequestBuildsResultResponseFromPayloadLength() throws {
    let request = RDPServerAutoDetectRequest(
        channelID: 1005,
        sequenceNumber: 0x0023,
        requestType: 0x002B,
        payloadByteCount: 4
    )

    #expect(request.response()?.encodedPDUData() == Data([
        0x00, 0x20, 0x00, 0x00,
        0x0E, 0x01, 0x23, 0x00, 0x03, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x0C, 0x00, 0x00, 0x00,
    ]))
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

@Test func autoDetectBandwidthResultResponseMatchesExpectedBytes() {
    let response = RDPClientAutoDetectResponsePDU(
        sequenceNumber: 0x0023,
        responseType: 0x0003,
        bandwidthByteCount: 4,
        bandwidthMilliseconds: 7
    )

    #expect(response.encodedTPKT(userChannelID: 1005, messageChannelID: 1006) == Data([
        0x03, 0x00, 0x00, 0x20,
        0x02, 0xF0, 0x80,
        0x64, 0x00, 0x04, 0x03, 0xEE, 0x70, 0x12,
        0x00, 0x20, 0x00, 0x00,
        0x0E, 0x01, 0x23, 0x00, 0x03, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
    ]))
}

@Test func autoDetectNetworkCharacteristicsSyncResponseMatchesExpectedBytes() {
    let response = RDPClientAutoDetectResponsePDU.networkCharacteristicsSync(sequenceNumber: 0x0023)

    #expect(response.encodedPDUData() == Data([
        0x00, 0x20, 0x00, 0x00,
        0x0E, 0x01, 0x23, 0x00, 0x18, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]))
}
