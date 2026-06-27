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
        case 0x1014:
            "bandwidth-measure-start"
        case 0x002B:
            "bandwidth-measure-stop"
        default:
            "request-0x\(String(format: "%04x", requestType))"
        }
    }

    var response: RDPClientAutoDetectResponsePDU {
        switch requestType {
        case 0x002B:
            RDPClientAutoDetectResponsePDU(
                sequenceNumber: sequenceNumber,
                responseType: 0x0003,
                bandwidthByteCount: UInt32(min(payloadByteCount, Int(UInt32.max)))
            )
        default:
            RDPClientAutoDetectResponsePDU(sequenceNumber: sequenceNumber)
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
        guard headerLength >= 0x06,
              headerTypeID == 0x00,
              Int(headerLength) - 6 <= cursor.remaining
        else {
            throw RDPDecodeError.invalidAutoDetectRequest
        }

        let sequenceNumber = try cursor.readLittleEndianUInt16()
        let requestType = try cursor.readLittleEndianUInt16()
        let payloadByteCount = Int(headerLength) - 6
        if payloadByteCount > 0 {
            _ = try cursor.readData(count: payloadByteCount)
        }

        return RDPServerAutoDetectRequest(
            channelID: indication.channelID,
            sequenceNumber: sequenceNumber,
            requestType: requestType,
            payloadByteCount: cursor.remaining
        )
    }
}

struct RDPClientAutoDetectResponsePDU: Equatable, Sendable {
    var sequenceNumber: UInt16
    var responseType: UInt16
    var bandwidthByteCount: UInt32?
    var bandwidthMilliseconds: UInt32

    init(
        sequenceNumber: UInt16,
        responseType: UInt16 = 0x0000,
        bandwidthByteCount: UInt32? = nil,
        bandwidthMilliseconds: UInt32 = 1
    ) {
        self.sequenceNumber = sequenceNumber
        self.responseType = responseType
        self.bandwidthByteCount = bandwidthByteCount
        self.bandwidthMilliseconds = bandwidthMilliseconds
    }

    func encodedPDUData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x2000)
        data.appendLittleEndianUInt16(0x0000)
        data.appendUInt8(bandwidthByteCount == nil ? 0x06 : 0x0E)
        data.appendUInt8(0x01)
        data.appendLittleEndianUInt16(sequenceNumber)
        data.appendLittleEndianUInt16(responseType)
        if let bandwidthByteCount {
            data.appendLittleEndianUInt32(bandwidthByteCount)
            data.appendLittleEndianUInt32(max(1, bandwidthMilliseconds))
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
}
