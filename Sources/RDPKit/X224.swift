import Foundation

enum X224TPDUType: UInt8, Sendable {
    case connectionRequest = 0xE0
    case connectionConfirm = 0xD0
    case data = 0xF0
}

enum X224DataTPDU {
    static func wrap(_ payload: Data) -> Data {
        var data = Data()
        data.appendUInt8(0x02)
        data.appendUInt8(X224TPDUType.data.rawValue)
        data.appendUInt8(0x80)
        data.append(payload)
        return TPKT.wrap(data)
    }

    static func unwrap(_ packet: Data) throws -> Data {
        let payload = try TPKT.unwrap(packet)
        var cursor = ByteCursor(payload)

        let length = try cursor.readUInt8()
        let type = try cursor.readUInt8()
        let eot = try cursor.readUInt8()
        guard length == 0x02, type == X224TPDUType.data.rawValue, eot == 0x80 else {
            throw RDPDecodeError.invalidX224DataTPDU
        }

        return cursor.readRemainingData()
    }
}

struct X224ConnectionRequest: Equatable, Sendable {
    var routingToken: Data?
    var negotiationRequest: RDPNegotiationRequest

    init(
        routingToken: Data? = nil,
        negotiationRequest: RDPNegotiationRequest = RDPNegotiationRequest()
    ) {
        self.routingToken = routingToken
        self.negotiationRequest = negotiationRequest
    }

    func encodedTPKT() -> Data {
        let negotiation = negotiationRequest.encoded()
        let trailingByteCount = (routingToken?.count ?? 0) + negotiation.count
        precondition(trailingByteCount <= Int(UInt8.max) - 6)

        var tpdu = Data()
        tpdu.appendUInt8(UInt8(6 + trailingByteCount))
        tpdu.appendUInt8(X224TPDUType.connectionRequest.rawValue)
        tpdu.appendBigEndianUInt16(0)
        tpdu.appendBigEndianUInt16(0)
        tpdu.appendUInt8(0)
        if let routingToken {
            tpdu.append(routingToken)
        }
        tpdu.append(negotiation)

        return TPKT.wrap(tpdu)
    }
}

struct X224ConnectionConfirm: Equatable, Sendable {
    var destinationReference: UInt16
    var sourceReference: UInt16
    var classAndOptions: UInt8
    var negotiationFlags: UInt8?
    var negotiationResult: RDPNegotiationResult?

    static func parse(fromTPKT packet: Data) throws -> X224ConnectionConfirm {
        let payload = try TPKT.unwrap(packet)
        var cursor = ByteCursor(payload)

        let lengthIndicator = try Int(cursor.readUInt8())
        guard payload.count == lengthIndicator + 1 else {
            throw RDPDecodeError.invalidX224Length(
                declared: lengthIndicator + 1,
                actual: payload.count
            )
        }

        let type = try cursor.readUInt8()
        guard type == X224TPDUType.connectionConfirm.rawValue else {
            throw RDPDecodeError.invalidX224Type(type)
        }

        let destinationReference = try cursor.readBigEndianUInt16()
        let sourceReference = try cursor.readBigEndianUInt16()
        let classAndOptions = try cursor.readUInt8()

        let trailingLength = lengthIndicator - 6
        guard trailingLength >= 0 else {
            throw RDPDecodeError.invalidX224Length(
                declared: lengthIndicator,
                actual: payload.count - 1
            )
        }

        let trailing = try cursor.readData(count: trailingLength)
        let negotiationFlags: UInt8?
        let negotiationResult: RDPNegotiationResult?
        if trailingLength > 0, !trailing.isEmpty {
            let response = try RDPNegotiationResponse.parseMessage(trailing)
            negotiationFlags = response.flags
            negotiationResult = response.result
        } else {
            negotiationFlags = nil
            negotiationResult = nil
        }

        return X224ConnectionConfirm(
            destinationReference: destinationReference,
            sourceReference: sourceReference,
            classAndOptions: classAndOptions,
            negotiationFlags: negotiationFlags,
            negotiationResult: negotiationResult
        )
    }
}
