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

    init(routingToken: Data? = nil, negotiationRequest: RDPNegotiationRequest = RDPNegotiationRequest()) {
        self.routingToken = routingToken
        self.negotiationRequest = negotiationRequest
    }

    func encodedTPKT() -> Data {
        var trailing = routingToken.map(Self.terminated) ?? Data()
        trailing.append(negotiationRequest.encoded())
        precondition(trailing.count <= Self.maximumTrailingByteCount)

        var tpdu = Data()
        tpdu.appendUInt8(UInt8(6 + trailing.count))
        tpdu.appendUInt8(X224TPDUType.connectionRequest.rawValue)
        tpdu.appendBigEndianUInt16(0)
        tpdu.appendBigEndianUInt16(0)
        tpdu.appendUInt8(0)
        tpdu.append(trailing)
        return TPKT.wrap(tpdu)
    }

    /// Whether a (server-supplied) routing token fits next to the 8-byte RDP_NEG_REQ.
    static func canCarry(routingToken: Data) -> Bool {
        terminated(routingToken).count + 8 <= maximumTrailingByteCount
    }

    /// X.224 length indicators stop at 254 and cover the 6 fixed bytes after them.
    private static let maximumTrailingByteCount = 254 - 6

    private static func terminated(_ routingToken: Data) -> Data {
        let terminator = Data([0x0D, 0x0A])
        return routingToken.suffix(terminator.count) == terminator ? routingToken : routingToken + terminator
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

        // Servers that predate RDP negotiation send no RDP_NEG_RSP/RDP_NEG_FAILURE.
        let response = cursor.remaining > 0
            ? try RDPNegotiationResponse.parse(cursor.readRemainingData())
            : nil
        return X224ConnectionConfirm(
            destinationReference: destinationReference,
            sourceReference: sourceReference,
            classAndOptions: classAndOptions,
            negotiationFlags: response?.flags,
            negotiationResult: response?.result
        )
    }
}
