import Foundation

private enum RDPFinalizationPDUType {
    static let control: UInt8 = 0x14
    static let synchronize: UInt8 = 0x1F
    static let fontList: UInt8 = 0x27
    static let frameAcknowledge: UInt8 = 0x38
}

private enum RDPControlAction {
    static let requestControl: UInt16 = 0x0001
    static let cooperate: UInt16 = 0x0004
}

private enum RDPFontListFlags {
    static let firstAndLast: UInt16 = 0x0003
}

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

/// Tracks server Share Data PDUs observed during Connection Finalization
/// ([MS-RDPBCGR] 1.3.1.1 / 2.2.1.19–2.2.1.22).
///
/// Client-to-server finalization PDUs have **no** dependencies on server PDUs and
/// may be sent as a single batch after Confirm Active. Server orderings vary
/// across Windows, KRDP, and GNOME (optional Monitor Layout / Save Session Info,
/// Synchronize/Cooperate ordering, interleaving with client Font List). This
/// tracker accepts the MS-legal superset without server-family branching.
struct RDPConnectionFinalizationTracker: Equatable, Sendable {
    private(set) var observedTypeNames: [String] = []

    mutating func observe(_ shareData: RDPShareDataPDU) {
        observedTypeNames.append(shareData.typeName)
    }

    mutating func observe(typeName: String) {
        observedTypeNames.append(typeName)
    }

    var receivedServerSynchronize: Bool {
        observedTypeNames.contains("server-synchronize")
    }

    var receivedControlCooperate: Bool {
        observedTypeNames.contains("control-cooperate")
    }

    var receivedControlGranted: Bool {
        observedTypeNames.contains("control-granted-control")
    }

    var receivedFontMap: Bool {
        observedTypeNames.contains("font-map")
    }

    /// Font Map ends connection finalization ([MS-RDPBCGR] 2.2.1.22).
    var isComplete: Bool {
        receivedFontMap
    }

    /// Optional intervening PDUs (Save Session Info, Monitor Layout, status, etc.)
    /// must not alone satisfy finalization; only Font Map (or an explicit grant
    /// path that still ends at Font Map) completes the phase.
    static func isConnectionFinalizationShareDataType(_ typeName: String) -> Bool {
        switch typeName {
        case "server-synchronize",
             "control-cooperate",
             "control-granted-control",
             "font-map":
            true
        default:
            false
        }
    }

    /// Whether a server Share Data type is a non-releasing intervening PDU that
    /// may legally appear before or during finalization without completing it.
    static func isOptionalInterveningShareDataType(_ typeName: String) -> Bool {
        switch typeName {
        case "save-session-info",
             "monitor-layout",
             "set-error-info",
             "status-info",
             "play-sound",
             "set-keyboard-indicators",
             "set-keyboard-ime-status",
             "auto-reconnect-status",
             "update",
             "pointer",
             "input":
            true
        default:
            false
        }
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
