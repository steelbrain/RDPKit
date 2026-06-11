import Foundation

struct MCSErectDomainRequestPDU: Equatable, Sendable {
    init() {}

    func encodedTPKT() -> Data {
        X224DataTPDU.wrap(Data([0x04, 0x01, 0x00, 0x01, 0x00]))
    }
}

struct MCSAttachUserRequestPDU: Equatable, Sendable {
    init() {}

    func encodedTPKT() -> Data {
        X224DataTPDU.wrap(Data([0x28]))
    }
}

struct MCSAttachUserConfirm: Equatable, Sendable {
    var result: UInt8
    var userChannelID: UInt16?

    var resultName: String {
        result == 0 ? "rt-successful" : "rt-\(result)"
    }

    static func parse(fromTPKT packet: Data) throws -> MCSAttachUserConfirm {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let header = try cursor.readUInt8()
        guard header == 0x2E else {
            throw RDPDecodeError.invalidMCSAttachUserConfirm
        }

        let result = try cursor.readUInt8()
        guard cursor.remaining >= 2 else {
            return MCSAttachUserConfirm(result: result, userChannelID: nil)
        }

        let userIDOffset = try cursor.readBigEndianUInt16()
        return try MCSAttachUserConfirm(
            result: result,
            userChannelID: mcsUserID(fromOffset: userIDOffset)
        )
    }
}

struct MCSChannelJoinRequestPDU: Equatable, Sendable {
    var initiator: UInt16
    var channelID: UInt16

    init(initiator: UInt16, channelID: UInt16) {
        precondition(initiator >= 1001)

        self.initiator = initiator
        self.channelID = channelID
    }

    func encodedTPKT() -> Data {
        var data = Data()
        data.appendUInt8(0x38)
        data.appendBigEndianUInt16(initiator - 1001)
        data.appendBigEndianUInt16(channelID)
        return X224DataTPDU.wrap(data)
    }
}

struct MCSChannelJoinConfirm: Equatable, Sendable {
    var result: UInt8
    var initiator: UInt16
    var requestedChannelID: UInt16
    var channelID: UInt16

    var resultName: String {
        result == 0 ? "rt-successful" : "rt-\(result)"
    }

    static func parse(fromTPKT packet: Data) throws -> MCSChannelJoinConfirm {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let header = try cursor.readUInt8()
        guard header == 0x3E else {
            throw RDPDecodeError.invalidMCSChannelJoinConfirm
        }

        let result = try cursor.readUInt8()
        let initiatorOffset = try cursor.readBigEndianUInt16()
        let requestedChannelID = try cursor.readBigEndianUInt16()
        let channelID = try cursor.readBigEndianUInt16()

        return try MCSChannelJoinConfirm(
            result: result,
            initiator: mcsUserID(fromOffset: initiatorOffset),
            requestedChannelID: requestedChannelID,
            channelID: channelID
        )
    }
}

private func mcsUserID(fromOffset offset: UInt16) throws -> UInt16 {
    guard offset <= UInt16.max - 1001 else {
        throw RDPDecodeError.invalidBERLength
    }
    return 1001 + offset
}

public struct RDPChannelJoinReport: Encodable, Equatable, Sendable {
    public var name: String
    public var channelID: UInt16
    public var requestHex: String
    public var confirmHex: String
    public var result: String

    public init(
        name: String,
        channelID: UInt16,
        requestHex: String,
        confirmHex: String,
        result: String
    ) {
        self.name = name
        self.channelID = channelID
        self.requestHex = requestHex
        self.confirmHex = confirmHex
        self.result = result
    }
}
