import Foundation

struct RDPServerAutoDetectRequest: Equatable, Sendable {
    var channelID: UInt16
    var sequenceNumber: UInt16
    var requestType: UInt16

    var requestTypeName: String {
        switch requestType {
        case 0x0001:
            "rtt-measure-request"
        case 0x1001:
            "connect-time-rtt-measure-request"
        default:
            "request-0x\(String(format: "%04x", requestType))"
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
        guard headerLength == 0x06, headerTypeID == 0x00 else {
            throw RDPDecodeError.invalidAutoDetectRequest
        }

        return try RDPServerAutoDetectRequest(
            channelID: indication.channelID,
            sequenceNumber: cursor.readLittleEndianUInt16(),
            requestType: cursor.readLittleEndianUInt16()
        )
    }
}

struct RDPClientAutoDetectResponsePDU: Equatable, Sendable {
    var sequenceNumber: UInt16
    var responseType: UInt16

    init(sequenceNumber: UInt16, responseType: UInt16 = 0x0000) {
        self.sequenceNumber = sequenceNumber
        self.responseType = responseType
    }

    func encodedPDUData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x2000)
        data.appendLittleEndianUInt16(0x0000)
        data.appendUInt8(0x06)
        data.appendUInt8(0x01)
        data.appendLittleEndianUInt16(sequenceNumber)
        data.appendLittleEndianUInt16(responseType)
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
