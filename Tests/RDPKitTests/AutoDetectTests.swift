import Foundation
@testable import RDPKit
import Testing

@Test func autoDetectResponseTypeConstantsMatchSpecValues() {
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.rtt == 0x0000)
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.bandwidthMeasureResults == 0x0003)
    #expect(RDPClientAutoDetectResponsePDU.ResponseType.continuousBandwidthMeasureResults == 0x000B)
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
    #expect(meterResponse(to: request)?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
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
    #expect(meterResponse(to: request)?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.rtt)
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

/// FreeRDP 3.32 sends a connect-time Stop with payloadLength 0 when asked for
/// fewer than 4 bytes, and its client answers it (libfreerdp/core/autodetect.c).
@Test func answersBandwidthMeasureStopWithoutPayload() throws {
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
    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))

    #expect(request.payloadByteCount == 0)
    #expect(meterResponse(to: request)?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.bandwidthMeasureResults)
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
    #expect(meterResponse(to: request) == nil)
}

@Test func parsesConnectTimeBandwidthMeasureStartWithoutResponse() throws {
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
    #expect(meterResponse(to: request) == nil)
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

@Test func parsesNetworkCharacteristicsBandwidthResultWithoutResponse() throws {
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
    #expect(meterResponse(to: request) == nil)
}

@Test func parsesNetworkCharacteristicsRTTBandwidthResultWithoutResponse() throws {
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
    #expect(meterResponse(to: request) == nil)
}

@Test func bandwidthMeasureStopRequestBuildsResultResponseFromPayloadLength() throws {
    let request = RDPServerAutoDetectRequest(
        channelID: 1005,
        sequenceNumber: 0x0023,
        requestType: 0x002B,
        payloadByteCount: 4
    )

    #expect(meterResponse(to: request)?.encodedPDUData() == Data([
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

@Test func bandwidthMeterReportsBytesAndTimeBetweenStartAndStop() {
    func request(_ type: UInt16, payload: Int = 0) -> RDPServerAutoDetectRequest {
        RDPServerAutoDetectRequest(channelID: 1005, sequenceNumber: 7, requestType: type, payloadByteCount: payload)
    }
    let start = ContinuousClock.now
    var meter = RDPAutoDetectBandwidthMeter()

    #expect(meter.response(to: request(0x1014), receivedAt: start) == nil)
    #expect(meter.response(to: request(0x0002, payload: 1000), receivedAt: start + .milliseconds(40)) == nil)
    // Only Bandwidth Measure Payload and Stop count ([MS-RDPBCGR] 2.2.14.1.3-4),
    // not an RTT request's bytes.
    #expect(meter.response(to: request(0x1001, payload: 64), receivedAt: start + .milliseconds(100))?.payload == .rtt)
    let results = meter.response(to: request(0x002B, payload: 500), receivedAt: start + .milliseconds(250))
    #expect(results?.payload == .bandwidth(byteCount: 1516, milliseconds: 250))

    let unstarted = meter.response(to: request(0x002B, payload: 4), receivedAt: start + .seconds(5))
    #expect(unstarted?.payload == .bandwidth(byteCount: 12, milliseconds: 1))
    #expect(meter.response(to: request(0x1001), receivedAt: start)?.payload == .rtt)
}

/// Continuous detection measures the session's own traffic between Start and
/// Stop ([MS-RDPBCGR] 1.3.9, 2.2.14.2.2). KRdp sends 0x0014 then 0x0429
/// mid-session (krdp fixture events 38 and 44).
@Test func bandwidthMeterReportsSessionBytesForContinuousMeasurement() {
    func request(_ type: UInt16) -> RDPServerAutoDetectRequest {
        RDPServerAutoDetectRequest(channelID: 1005, sequenceNumber: 9, requestType: type, payloadByteCount: 0)
    }
    let start = ContinuousClock.now
    var meter = RDPAutoDetectBandwidthMeter()

    meter.countReceivedBytes(5000)
    #expect(meter.response(to: request(0x0014), receivedAt: start) == nil)
    meter.countReceivedBytes(1000)
    meter.countReceivedBytes(234)
    let results = meter.response(to: request(0x0429), receivedAt: start + .milliseconds(120))

    #expect(results?.responseType == RDPClientAutoDetectResponsePDU.ResponseType.continuousBandwidthMeasureResults)
    #expect(results?.payload == .bandwidth(byteCount: 1234, milliseconds: 120))
    meter.countReceivedBytes(77)
    let unstarted = meter.response(to: request(0x0429), receivedAt: start + .seconds(1))
    #expect(unstarted?.payload == .bandwidth(byteCount: 0, milliseconds: 1))
}

/// Answers `request` as the client does, with a meter that has seen nothing else.
func meterResponse(to request: RDPServerAutoDetectRequest) -> RDPClientAutoDetectResponsePDU? {
    var meter = RDPAutoDetectBandwidthMeter()
    return meter.response(to: request)
}

@Test func unknownAutoDetectRequestTypeParsesWithoutResponse() throws {
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
        0x77, 0x77,
        0x01, 0x02,
    ])

    let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: X224DataTPDU.wrap(pdu)))
    var meter = RDPAutoDetectBandwidthMeter()
    #expect(request.requestType == 0x7777)
    #expect(meter.response(to: request) == nil)
}

// TPKT entry point for tests; the client parses the indication routed from
// the message channel.
extension RDPServerAutoDetectRequest {
    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPServerAutoDetectRequest? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        return try parseIfPresent(from: indication)
    }
}
