import Foundation

struct MCSSendDataRequestPDU: Equatable, Sendable {
    static let maximumUserDataByteCount = 0x3fff

    var initiator: UInt16
    var channelID: UInt16
    var userData: Data

    init(initiator: UInt16, channelID: UInt16, userData: Data) {
        precondition(initiator >= 1001)
        precondition(userData.count <= Self.maximumUserDataByteCount)

        self.initiator = initiator
        self.channelID = channelID
        self.userData = userData
    }

    func encodedTPKT() -> Data {
        var data = Data()
        data.appendUInt8(0x64)
        data.appendBigEndianUInt16(initiator - 1001)
        data.appendBigEndianUInt16(channelID)
        data.appendUInt8(MCSSendDataFlags.highPriorityBeginEnd)
        data.appendPERLength(userData.count)
        data.append(userData)
        return X224DataTPDU.wrap(data)
    }
}

struct MCSSendDataIndicationPDU: Equatable, Sendable {
    var initiator: UInt16
    var channelID: UInt16
    var userData: Data

    static func parse(fromTPKT packet: Data) throws -> MCSSendDataIndicationPDU {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let header = try cursor.readUInt8()
        guard header == 0x68 else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }
        guard cursor.remaining >= 6 else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }

        let initiatorOffset = try cursor.readBigEndianUInt16()
        let channelID = try cursor.readBigEndianUInt16()
        let flags = try cursor.readUInt8()
        guard MCSSendDataFlags.isCompleteSinglePayload(flags) else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }
        let length = try cursor.readPERLength()
        let userData = try cursor.readData(count: length)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidMCSSendDataIndication
        }

        return try MCSSendDataIndicationPDU(
            initiator: mcsUserID(fromOffset: initiatorOffset),
            channelID: channelID,
            userData: userData
        )
    }
}

private enum MCSSendDataFlags {
    static let highPriorityBeginEnd: UInt8 = 0x70

    private static let segmentationMask: UInt8 = 0x30
    private static let beginEndSegmentation: UInt8 = 0x30
    private static let paddingMask: UInt8 = 0x0F

    static func isCompleteSinglePayload(_ flags: UInt8) -> Bool {
        flags & paddingMask == 0 && flags & segmentationMask == beginEndSegmentation
    }
}

private func mcsUserID(fromOffset offset: UInt16) throws -> UInt16 {
    guard offset <= UInt16.max - 1001 else {
        throw RDPDecodeError.invalidBERLength
    }
    return 1001 + offset
}

extension ByteCursor {
    mutating func readPERLength() throws -> Int {
        let first = try readUInt8()
        guard first & 0x80 != 0 else {
            return Int(first)
        }

        guard first & 0x40 == 0 else {
            throw RDPDecodeError.invalidBERLength
        }
        return try (Int(first & 0x3F) << 8) | Int(readUInt8())
    }
}

extension Data {
    mutating func appendPERLength(_ length: Int) {
        precondition(length >= 0)

        if length < 0x80 {
            appendUInt8(UInt8(length))
            return
        }

        precondition(length <= MCSSendDataRequestPDU.maximumUserDataByteCount)
        appendUInt8(0x80 | UInt8((length >> 8) & 0x3F))
        appendUInt8(UInt8(length & 0xFF))
    }
}
