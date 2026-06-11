import Foundation

enum RDPStaticVirtualChannelFlags {
    static let first: UInt32 = 0x0000_0001
    static let last: UInt32 = 0x0000_0002
    static let showProtocol: UInt32 = 0x0000_0010
}

struct RDPStaticVirtualChannelPDU: Equatable, Sendable {
    static let headerByteCount = 8
    static let maximumPayloadByteCount = MCSSendDataRequestPDU.maximumUserDataByteCount - headerByteCount

    var totalLength: UInt32
    var flags: UInt32
    var payload: Data

    init(
        payload: Data,
        flags: UInt32 = RDPStaticVirtualChannelFlags.first | RDPStaticVirtualChannelFlags.last
    ) {
        precondition(payload.count <= Int(UInt32.max))

        totalLength = UInt32(payload.count)
        self.flags = flags
        self.payload = payload
    }

    var isComplete: Bool {
        flags & RDPStaticVirtualChannelFlags.first != 0
            && flags & RDPStaticVirtualChannelFlags.last != 0
            && totalLength == payload.count
    }

    static func canEncodeSinglePayload(_ payload: Data) -> Bool {
        payload.count <= maximumPayloadByteCount
    }

    func encodedUserData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(totalLength)
        data.appendLittleEndianUInt32(flags)
        data.append(payload)
        return data
    }

    func encodedTPKT(initiator: UInt16, channelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: initiator,
            channelID: channelID,
            userData: encodedUserData()
        ).encodedTPKT()
    }

    static func parseIfPresent(
        fromTPKT packet: Data,
        channelID expectedChannelID: UInt16
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.channelID == expectedChannelID else {
            return nil
        }
        return try parse(fromUserData: indication.userData)
    }

    static func parse(fromUserData userData: Data) throws -> RDPStaticVirtualChannelPDU {
        guard userData.count >= 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(userData)
        let totalLength = try cursor.readLittleEndianUInt32()
        let flags = try cursor.readLittleEndianUInt32()
        let payload = cursor.readRemainingData()
        guard payload.count <= Int(UInt32.max), totalLength >= UInt32(payload.count) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        return RDPStaticVirtualChannelPDU(
            totalLength: totalLength,
            flags: flags,
            payload: payload
        )
    }

    private init(totalLength: UInt32, flags: UInt32, payload: Data) {
        self.totalLength = totalLength
        self.flags = flags
        self.payload = payload
    }
}
