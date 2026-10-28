import Foundation

struct RDPServerAutoDetectRequest: Equatable, Sendable {
    var channelID: UInt16
    var sequenceNumber: UInt16
    var requestType: UInt16
    var payloadByteCount: Int

    var requestTypeName: String {
        switch requestType {
        case 0x0001:
            "rtt-measure-request"
        case 0x1001:
            "connect-time-rtt-measure-request"
        case 0x0014:
            "bandwidth-measure-start"
        case 0x0114:
            "lossy-bandwidth-measure-start"
        case 0x1014:
            "connect-time-bandwidth-measure-start"
        case 0x0002:
            "bandwidth-measure-payload"
        case 0x002B:
            "bandwidth-measure-stop"
        case 0x0429:
            "post-connect-bandwidth-measure-stop"
        case 0x0629:
            "lossy-bandwidth-measure-stop"
        case 0x0840:
            "network-characteristics-rtt"
        case 0x0880:
            "network-characteristics-bandwidth"
        case 0x08C0:
            "network-characteristics-rtt-bandwidth"
        default:
            "request-0x\(String(format: "%04x", requestType))"
        }
    }

    var measuredByteCountContribution: UInt32 {
        switch requestType {
        case 0x0002, 0x002B:
            UInt32(min(payloadByteCount + 8, Int(UInt32.max)))
        default:
            0
        }
    }

    var resetsMeasuredByteCount: Bool {
        switch requestType {
        case 0x0014, 0x0114, 0x1014:
            true
        default:
            false
        }
    }

    /// The client's reply, if the request has one ([MS-RDPBCGR] 2.2.14.2).
    /// Bandwidth Measure Start/Payload and Network Characteristics Result
    /// have none; the Network Characteristics Sync response is reserved for
    /// auto-reconnect with previously measured values (2.2.14.2.3).
    func response(
        measuredByteCount: UInt32? = nil,
        measuredMilliseconds: UInt32 = 1
    ) -> RDPClientAutoDetectResponsePDU? {
        switch requestType {
        case 0x0001, 0x1001:
            return RDPClientAutoDetectResponsePDU(sequenceNumber: sequenceNumber)
        case 0x002B:
            return RDPClientAutoDetectResponsePDU(
                sequenceNumber: sequenceNumber,
                responseType: RDPClientAutoDetectResponsePDU.ResponseType.bandwidthMeasureResults,
                bandwidthByteCount: measuredByteCount ?? measuredByteCountContribution,
                bandwidthMilliseconds: measuredMilliseconds
            )
        case 0x0429:
            return RDPClientAutoDetectResponsePDU(
                sequenceNumber: sequenceNumber,
                responseType: RDPClientAutoDetectResponsePDU.ResponseType.continuousBandwidthMeasureResults,
                bandwidthByteCount: measuredByteCount ?? measuredByteCountContribution,
                bandwidthMilliseconds: measuredMilliseconds
            )
        default:
            return nil
        }
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPServerAutoDetectRequest? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 10 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let securityFlags = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        guard securityFlags & 0x1000 != 0 else {
            return nil
        }

        let headerLength = try cursor.readUInt8()
        let headerTypeID = try cursor.readUInt8()
        guard headerTypeID == 0x00,
              cursor.remaining >= 4
        else {
            throw RDPDecodeError.invalidAutoDetectRequest
        }

        let sequenceNumber = try cursor.readLittleEndianUInt16()
        let requestType = try cursor.readLittleEndianUInt16()
        let payloadByteCount = try cursor.readAutoDetectPayloadByteCount(
            headerLength: headerLength,
            requestType: requestType
        )

        return RDPServerAutoDetectRequest(
            channelID: indication.channelID,
            sequenceNumber: sequenceNumber,
            requestType: requestType,
            payloadByteCount: payloadByteCount
        )
    }
}

/// Answers a run of auto-detect requests, measuring each bandwidth test:
/// Bandwidth Measure Results report the bytes and the milliseconds between
/// receipt of the Start and Stop requests ([MS-RDPBCGR] 2.2.14.2.2).
struct RDPAutoDetectBandwidthMeter: Sendable {
    private var startedAt: ContinuousClock.Instant?
    private var byteCount: UInt32 = 0

    mutating func response(
        to request: RDPServerAutoDetectRequest,
        receivedAt now: ContinuousClock.Instant = .now
    ) -> RDPClientAutoDetectResponsePDU? {
        if request.resetsMeasuredByteCount {
            startedAt = now
            byteCount = 0
        }
        let (total, overflow) = byteCount.addingReportingOverflow(request.measuredByteCountContribution)
        byteCount = overflow ? .max : total

        guard let response = request.response(
            measuredByteCount: byteCount,
            measuredMilliseconds: startedAt.map { Self.milliseconds(now - $0) } ?? 1
        ) else {
            return nil
        }
        if case .bandwidth = response.payload {
            startedAt = nil
            byteCount = 0
        }
        return response
    }

    private static func milliseconds(_ duration: Duration) -> UInt32 {
        let (seconds, attoseconds) = duration.components
        let milliseconds = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return UInt32(clamping: milliseconds)
    }
}

private extension ByteCursor {
    mutating func readAutoDetectPayloadByteCount(headerLength: UInt8, requestType: UInt16) throws -> Int {
        switch requestType {
        case 0x0001, 0x1001, 0x0014, 0x0114, 0x1014, 0x0429, 0x0629:
            guard headerLength == 0x06, remaining == 0 else {
                throw RDPDecodeError.invalidAutoDetectRequest
            }
            return 0

        case 0x0002:
            return try readPayloadLength(headerLength: headerLength, requiresNonzeroPayload: false)

        case 0x002B:
            return try readPayloadLength(headerLength: headerLength, requiresNonzeroPayload: true)

        case 0x0840, 0x0880:
            guard headerLength == 0x0E, remaining == 8 else {
                throw RDPDecodeError.invalidAutoDetectRequest
            }
            _ = try readLittleEndianUInt32()
            _ = try readLittleEndianUInt32()
            return 0

        case 0x08C0:
            guard headerLength == 0x12, remaining == 12 else {
                throw RDPDecodeError.invalidAutoDetectRequest
            }
            _ = try readLittleEndianUInt32()
            _ = try readLittleEndianUInt32()
            _ = try readLittleEndianUInt32()
            return 0

        default:
            throw RDPDecodeError.invalidAutoDetectRequest
        }
    }

    private mutating func readPayloadLength(
        headerLength: UInt8,
        requiresNonzeroPayload: Bool
    ) throws -> Int {
        guard headerLength == 0x08, remaining >= 2 else {
            throw RDPDecodeError.invalidAutoDetectRequest
        }
        let payloadByteCount = Int(try readLittleEndianUInt16())
        guard remaining == payloadByteCount,
              requiresNonzeroPayload == false || payloadByteCount > 0
        else {
            throw RDPDecodeError.invalidAutoDetectRequest
        }
        _ = try readData(count: payloadByteCount)
        return payloadByteCount
    }
}

struct RDPClientAutoDetectResponsePDU: Equatable, Sendable {
    enum ResponseType {
        static let rtt: UInt16 = 0x0000
        static let bandwidthMeasureResults: UInt16 = 0x0003
        static let continuousBandwidthMeasureResults: UInt16 = 0x000B
    }

    enum Payload: Equatable, Sendable {
        case rtt
        case bandwidth(byteCount: UInt32, milliseconds: UInt32)
    }

    var sequenceNumber: UInt16
    var responseType: UInt16
    var payload: Payload

    init(
        sequenceNumber: UInt16,
        responseType: UInt16 = ResponseType.rtt,
        bandwidthByteCount: UInt32? = nil,
        bandwidthMilliseconds: UInt32 = 1
    ) {
        if bandwidthByteCount == nil {
            precondition(responseType == ResponseType.rtt)
        } else {
            precondition(
                responseType == ResponseType.bandwidthMeasureResults
                    || responseType == ResponseType.continuousBandwidthMeasureResults
            )
        }

        self.sequenceNumber = sequenceNumber
        self.responseType = responseType
        if let bandwidthByteCount {
            payload = .bandwidth(byteCount: bandwidthByteCount, milliseconds: bandwidthMilliseconds)
        } else {
            payload = .rtt
        }
    }

    func encodedPDUData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x2000)
        data.appendLittleEndianUInt16(0x0000)
        data.appendUInt8(headerLength)
        data.appendUInt8(0x01)
        data.appendLittleEndianUInt16(sequenceNumber)
        data.appendLittleEndianUInt16(responseType)
        switch payload {
        case .rtt:
            break
        case let .bandwidth(byteCount, milliseconds):
            data.appendLittleEndianUInt32(max(1, milliseconds))
            data.appendLittleEndianUInt32(byteCount)
        }
        return data
    }

    func encodedTPKT(userChannelID: UInt16, messageChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: messageChannelID,
            userData: encodedPDUData()
        ).encodedTPKT()
    }

    private var headerLength: UInt8 {
        switch payload {
        case .rtt:
            0x06
        case .bandwidth:
            0x0E
        }
    }
}
