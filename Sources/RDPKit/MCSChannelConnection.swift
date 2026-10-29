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
        let (initiatorPresent, result) = try readMCSConfirmHeader(
            &cursor,
            choice: 11,
            error: .invalidMCSAttachUserConfirm
        )
        let userChannelID = initiatorPresent ? try mcsUserID(fromOffset: cursor.readBigEndianUInt16()) : nil
        guard cursor.remaining == 0, result != 0 || userChannelID != nil else {
            throw RDPDecodeError.invalidMCSAttachUserConfirm
        }
        return MCSAttachUserConfirm(result: result, userChannelID: userChannelID)
    }
}

/// Reads the T.125 PER header shared by Attach User and Channel Join Confirm: a 6-bit
/// DomainMCSPDU choice, the bit flagging the trailing OPTIONAL field, then Result.
/// PER packs Result's top bit into the header and the rest into the next byte's high
/// bits; FreeRDP-based servers (KRdp, GRD) write it as that whole byte instead, so the
/// returned result is only exact for 0, and any nonzero value means failure.
private func readMCSConfirmHeader(
    _ cursor: inout ByteCursor,
    choice: UInt8,
    error: RDPDecodeError
) throws -> (optionalFieldPresent: Bool, result: UInt8) {
    let header = try cursor.readUInt8()
    guard header >> 2 == choice else {
        throw error
    }
    return try (header & 0x02 != 0, cursor.readUInt8() | (header & 0x01) << 7)
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
    /// 0 when the server omitted the OPTIONAL channelId, which only a failed join may do.
    var channelID: UInt16

    var resultName: String {
        result == 0 ? "rt-successful" : "rt-\(result)"
    }

    func validates(requestedChannelID: UInt16) -> Bool {
        result == 0
            && channelID == requestedChannelID
    }

    static func parse(fromTPKT packet: Data) throws -> MCSChannelJoinConfirm {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let (channelIDPresent, result) = try readMCSConfirmHeader(
            &cursor,
            choice: 15,
            error: .invalidMCSChannelJoinConfirm
        )
        let initiator = try mcsUserID(fromOffset: cursor.readBigEndianUInt16())
        let requestedChannelID = try cursor.readBigEndianUInt16()
        let channelID = channelIDPresent ? try cursor.readBigEndianUInt16() : nil
        guard cursor.remaining == 0, result != 0 || channelID != nil else {
            throw RDPDecodeError.invalidMCSChannelJoinConfirm
        }

        return MCSChannelJoinConfirm(
            result: result,
            initiator: initiator,
            requestedChannelID: requestedChannelID,
            channelID: channelID ?? 0
        )
    }
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
