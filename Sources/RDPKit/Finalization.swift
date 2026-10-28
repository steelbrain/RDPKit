import Foundation

private enum RDPFinalizationPDUType {
    static let control: UInt8 = 0x14
    static let synchronize: UInt8 = 0x1F
    static let fontList: UInt8 = 0x27
    static let fontMap: UInt8 = 0x28
    static let frameAcknowledge: UInt8 = 0x38
}

private enum RDPControlAction {
    static let requestControl: UInt16 = 0x0001
    static let grantedControl: UInt16 = 0x0002
    static let cooperate: UInt16 = 0x0004
}

private enum RDPFontListFlags {
    static let firstAndLast: UInt16 = 0x0003
}

struct RDPClientSynchronizePDU: Equatable, Sendable {
    var shareID: UInt32
    var targetUser: UInt16

    init(shareID: UInt32, targetUser: UInt16 = RDPServerChannelID.fixed) {
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
            pduType2: RDPFinalizationPDUType.synchronize,
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
        RDPClientControlPDU(shareID: shareID, action: RDPControlAction.cooperate)
    }

    static func requestControl(shareID: UInt32) -> RDPClientControlPDU {
        RDPClientControlPDU(shareID: shareID, action: RDPControlAction.requestControl)
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(action)
        payload.appendLittleEndianUInt16(grantID)
        payload.appendLittleEndianUInt32(controlID)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: RDPFinalizationPDUType.control,
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
        payload.appendLittleEndianUInt16(RDPFontListFlags.firstAndLast)
        payload.appendLittleEndianUInt16(0x0032)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: RDPFinalizationPDUType.fontList,
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

struct RDPClientFrameAcknowledgePDU: Equatable, Sendable {
    var shareID: UInt32
    var frameID: UInt32

    func encodedPDUData(userChannelID: UInt16) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(frameID)
        return rdpShareDataPDUData(
            shareID: shareID,
            pduSource: userChannelID,
            pduType2: RDPFinalizationPDUType.frameAcknowledge,
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

/// Server Share Data PDUs seen during Connection Finalization ([MS-RDPBCGR]
/// 1.3.1.1, 2.2.1.19-2.2.1.22). Servers order Synchronize and Cooperate
/// differently and may interleave Monitor Layout or Save Session Info; only
/// Font Map ends the phase.
struct RDPConnectionFinalizationTracker: Equatable, Sendable {
    private(set) var receivedServerSynchronize = false
    private(set) var receivedControlCooperate = false
    private(set) var receivedControlGranted = false
    private(set) var receivedFontMap = false

    mutating func observe(_ shareData: RDPShareDataPDU) {
        switch (shareData.pduType2, shareData.controlAction) {
        case (RDPFinalizationPDUType.synchronize, _):
            receivedServerSynchronize = true
        case (RDPFinalizationPDUType.control, RDPControlAction.cooperate):
            receivedControlCooperate = true
        case (RDPFinalizationPDUType.control, RDPControlAction.grantedControl):
            receivedControlGranted = true
        case (RDPFinalizationPDUType.fontMap, _):
            receivedFontMap = true
        default:
            break
        }
    }

    var isComplete: Bool {
        receivedFontMap
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
