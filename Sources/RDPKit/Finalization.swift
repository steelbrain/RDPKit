import Foundation

struct RDPClientSynchronizePDU: Equatable, Sendable {
    var shareID: UInt32
    var targetUser: UInt16

    init(shareID: UInt32, targetUser: UInt16 = 1002) {
        self.shareID = shareID
        self.targetUser = targetUser
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0x0001)
        payload.appendLittleEndianUInt16(targetUser)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: 0x1F,
            payload: payload
        )
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData(userChannelID: userChannelID)
        ).encodedTPKT()
    }
}

struct RDPClientControlPDU: Equatable, Sendable {
    var shareID: UInt32
    var action: UInt16
    var grantID: UInt16
    var controlID: UInt32

    init(
        shareID: UInt32,
        action: UInt16,
        grantID: UInt16 = 0,
        controlID: UInt32 = 0
    ) {
        self.shareID = shareID
        self.action = action
        self.grantID = grantID
        self.controlID = controlID
    }

    static func cooperate(shareID: UInt32) -> RDPClientControlPDU {
        RDPClientControlPDU(shareID: shareID, action: 0x0004)
    }

    static func requestControl(shareID: UInt32) -> RDPClientControlPDU {
        RDPClientControlPDU(shareID: shareID, action: 0x0001)
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(action)
        payload.appendLittleEndianUInt16(grantID)
        payload.appendLittleEndianUInt32(controlID)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: 0x14,
            payload: payload
        )
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData(userChannelID: userChannelID)
        ).encodedTPKT()
    }
}

struct RDPClientFontListPDU: Equatable, Sendable {
    var shareID: UInt32

    init(shareID: UInt32) {
        self.shareID = shareID
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(0x0003)
        payload.appendLittleEndianUInt16(0x0032)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: 0x27,
            payload: payload
        )
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData(userChannelID: userChannelID)
        ).encodedTPKT()
    }
}

func rdpShareDataPDUData(
    shareID: UInt32,
    pduSource: UInt16,
    pduType2: UInt8,
    payload: Data,
    streamID: UInt8 = 0x01
) -> Data {
    let totalLength = 18 + payload.count
    precondition(totalLength <= Int(UInt16.max))
    precondition(payload.count + 4 <= Int(UInt16.max))

    var data = Data()
    data.appendLittleEndianUInt16(UInt16(totalLength))
    data.appendLittleEndianUInt16(0x0017)
    data.appendLittleEndianUInt16(pduSource)
    data.appendLittleEndianUInt32(shareID)
    data.appendUInt8(0)
    data.appendUInt8(streamID)
    data.appendLittleEndianUInt16(UInt16(payload.count + 4))
    data.appendUInt8(pduType2)
    data.appendUInt8(0)
    data.appendLittleEndianUInt16(0)
    data.append(payload)
    return data
}
