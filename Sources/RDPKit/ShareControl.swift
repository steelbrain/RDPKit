import Foundation

private enum RDPShareHeaderLength {
    static let control = 6
    static let data = 18
}

struct RDPKeyboardIMEStatus: Equatable, Sendable {
    var unitID: UInt16
    var imeState: UInt32
    var imeConversionMode: UInt32
}

struct RDPPlaySoundPDU: Equatable, Sendable {
    var duration: UInt32
    var frequency: UInt32
}

enum RDPSaveSessionInfoType: UInt32, Sendable {
    case logon = 0x0000_0000
    case logonLong = 0x0000_0001
    case logonPlainNotify = 0x0000_0002
    case logonExtendedInfo = 0x0000_0003
}

struct RDPServerAutoReconnectPacket: Equatable, Sendable {
    var version: UInt32
    var logonID: UInt32
    var arcRandomBits: Data
}

struct RDPLogonErrorInfo: Equatable, Sendable {
    var errorNotificationType: UInt32
    var errorNotificationData: UInt32
}

struct RDPSaveSessionInfoPDU: Equatable, Sendable {
    var infoTypeRawValue: UInt32
    var autoReconnectPacket: RDPServerAutoReconnectPacket?
    var logonErrorInfo: RDPLogonErrorInfo?

    var infoType: RDPSaveSessionInfoType? {
        RDPSaveSessionInfoType(rawValue: infoTypeRawValue)
    }

    static func parsePayload(_ payload: Data) throws -> RDPSaveSessionInfoPDU {
        var cursor = ByteCursor(payload)
        let infoTypeRawValue = try cursor.readLittleEndianUInt32()
        var autoReconnectPacket: RDPServerAutoReconnectPacket?
        var logonErrorInfo: RDPLogonErrorInfo?

        switch RDPSaveSessionInfoType(rawValue: infoTypeRawValue) {
        case .logon:
            try validateLogonInfoVersion1Payload(&cursor)
        case .logonLong:
            try validateLogonInfoVersion2Payload(&cursor)
        case .logonPlainNotify:
            guard cursor.remaining == 576 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case .logonExtendedInfo:
            (autoReconnectPacket, logonErrorInfo) = try parseExtendedInfoPayload(&cursor)
        case nil:
            throw RDPDecodeError.invalidShareDataHeader
        }

        return RDPSaveSessionInfoPDU(
            infoTypeRawValue: infoTypeRawValue,
            autoReconnectPacket: autoReconnectPacket,
            logonErrorInfo: logonErrorInfo
        )
    }

    private static func validateLogonInfoVersion1Payload(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining == 576 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let domainByteCount = try cursor.readLittleEndianUInt32()
        guard domainByteCount <= 52, domainByteCount.isMultiple(of: 2) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let domain = try cursor.readData(count: 52)
        try validateDeclaredUTF16String(domain, byteCount: domainByteCount)
        let userNameByteCount = try cursor.readLittleEndianUInt32()
        guard userNameByteCount <= 512, userNameByteCount.isMultiple(of: 2) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let userName = try cursor.readData(count: 512)
        try validateDeclaredUTF16String(userName, byteCount: userNameByteCount)
        _ = try cursor.readLittleEndianUInt32()
    }

    private static func validateLogonInfoVersion2Payload(_ cursor: inout ByteCursor) throws {
        let payloadLength = cursor.remaining
        guard payloadLength >= 576 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let version = try cursor.readLittleEndianUInt16()
        let size = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        let domainByteCount = try cursor.readLittleEndianUInt32()
        let userNameByteCount = try cursor.readLittleEndianUInt32()
        let variableByteCount = UInt64(domainByteCount) + UInt64(userNameByteCount)
        guard version == 1,
              [18, 576].contains(size),
              domainByteCount.isMultiple(of: 2),
              userNameByteCount.isMultiple(of: 2),
              domainByteCount <= 52,
              userNameByteCount <= 512,
              variableByteCount <= UInt64(Int.max),
              variableByteCount <= UInt64(cursor.remaining - 558)
        else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        _ = try cursor.readData(count: 558)
        let domain = try cursor.readData(count: Int(domainByteCount))
        let userName = try cursor.readData(count: Int(userNameByteCount))
        try validateDeclaredUTF16String(domain, byteCount: domainByteCount)
        try validateDeclaredUTF16String(userName, byteCount: userNameByteCount)
        let trailingPadding = try cursor.readData(count: cursor.remaining)
        guard trailingPadding.allSatisfy({ $0 == 0 }) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateDeclaredUTF16String(_ data: Data, byteCount: UInt32) throws {
        guard byteCount <= data.count, byteCount.isMultiple(of: 2) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        guard byteCount == 0 || data.littleEndianUInt16(at: Int(byteCount) - 2) == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func parseExtendedInfoPayload(
        _ cursor: inout ByteCursor
    ) throws -> (RDPServerAutoReconnectPacket?, RDPLogonErrorInfo?) {
        let payloadLength = cursor.remaining
        let length = try cursor.readLittleEndianUInt16()
        let fieldsPresent = try cursor.readLittleEndianUInt32()
        guard length >= 6,
              Int(length) - 6 <= cursor.remaining,
              Int(length) + 570 == payloadLength
        else {
            throw RDPDecodeError.invalidShareDataHeader
        }

        let fieldsPayload = try cursor.readData(count: Int(length) - 6)
        var fieldsCursor = ByteCursor(fieldsPayload)
        var autoReconnectPacket: RDPServerAutoReconnectPacket?
        var logonErrorInfo: RDPLogonErrorInfo?

        if fieldsPresent & 0x0000_0001 != 0 {
            autoReconnectPacket = try parseAutoReconnectField(&fieldsCursor)
        }
        if fieldsPresent & 0x0000_0002 != 0 {
            logonErrorInfo = try parseLogonErrorField(&fieldsCursor)
        }

        return (autoReconnectPacket, logonErrorInfo)
    }

    private static func parseAutoReconnectField(_ cursor: inout ByteCursor) throws -> RDPServerAutoReconnectPacket {
        let fieldData = try readLogonFieldData(&cursor)
        var fieldCursor = ByteCursor(fieldData)
        let cbLen = try fieldCursor.readLittleEndianUInt32()
        let version = try fieldCursor.readLittleEndianUInt32()
        let logonID = try fieldCursor.readLittleEndianUInt32()
        let arcRandomBits = try fieldCursor.readData(count: 16)
        guard cbLen == 28, version == 1, fieldCursor.remaining == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        return RDPServerAutoReconnectPacket(
            version: version,
            logonID: logonID,
            arcRandomBits: arcRandomBits
        )
    }

    private static func parseLogonErrorField(_ cursor: inout ByteCursor) throws -> RDPLogonErrorInfo {
        let fieldData = try readLogonFieldData(&cursor)
        var fieldCursor = ByteCursor(fieldData)
        let errorNotificationType = try fieldCursor.readLittleEndianUInt32()
        let errorNotificationData = try fieldCursor.readLittleEndianUInt32()
        guard fieldCursor.remaining == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        return RDPLogonErrorInfo(
            errorNotificationType: errorNotificationType,
            errorNotificationData: errorNotificationData
        )
    }

    private static func readLogonFieldData(_ cursor: inout ByteCursor) throws -> Data {
        let fieldDataByteCount = try cursor.readLittleEndianUInt32()
        guard fieldDataByteCount <= UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        return try cursor.readData(count: Int(fieldDataByteCount))
    }
}

struct RDPShareControlPDU: Equatable, Sendable {
    var channelID: UInt16
    var totalLength: UInt16
    var pduType: UInt16
    var pduSource: UInt16

    var type: UInt16 {
        pduType & 0x000F
    }

    var protocolVersion: UInt16 {
        pduType >> 4
    }

    var typeName: String {
        switch type {
        case 0x1:
            "server-demand-active"
        case 0x3:
            "client-confirm-active"
        case 0x6:
            "server-deactivate-all"
        case 0x7:
            "data-pdu"
        case 0xA:
            "server-redirection"
        default:
            "share-control-0x\(String(format: "%x", type))"
        }
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPShareControlPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 6 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let totalLength = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let pduSource = try cursor.readLittleEndianUInt16()
        let type = pduType & 0x000F
        let protocolVersion = pduType >> 4

        guard [0x1, 0x3, 0x6, 0x7, 0xA].contains(type) else {
            return nil
        }
        guard type == 0xA || protocolVersion == 0x0001 else {
            return nil
        }
        guard totalLength != 0x8000 else {
            return nil
        }
        guard Int(totalLength) == indication.userData.count else {
            throw RDPDecodeError.invalidShareControlHeader
        }
        guard Int(totalLength) >= RDPShareHeaderLength.control else {
            throw RDPDecodeError.invalidShareControlHeader
        }

        return RDPShareControlPDU(
            channelID: indication.channelID,
            totalLength: totalLength,
            pduType: pduType,
            pduSource: pduSource
        )
    }
}

struct RDPShareDataPDU: Equatable, Sendable {
    var channelID: UInt16
    var shareID: UInt32
    var pduSource: UInt16
    var streamID: UInt8
    var uncompressedLength: UInt16
    var pduType2: UInt8
    var compressedType: UInt8
    var compressedLength: UInt16
    var payload: Data

    var typeName: String {
        switch pduType2 {
        case 0x02:
            "update"
        case 0x14:
            controlActionName.map { "control-\($0)" } ?? "control"
        case 0x1B:
            "pointer"
        case 0x1C:
            "input"
        case 0x1F:
            "server-synchronize"
        case 0x22:
            "play-sound"
        case 0x23:
            "suppress-output"
        case 0x26:
            "save-session-info"
        case 0x28:
            "font-map"
        case 0x29:
            "set-keyboard-indicators"
        case 0x2D:
            "set-keyboard-ime-status"
        case 0x2F:
            "set-error-info"
        case 0x32:
            "auto-reconnect-status"
        case 0x36:
            "status-info"
        case 0x37:
            "monitor-layout"
        default:
            "share-data-0x\(String(format: "%02x", pduType2))"
        }
    }

    var errorInfo: UInt32? {
        guard pduType2 == 0x2F, payload.count == 4 else {
            return nil
        }
        return payload.littleEndianUInt32(at: 0)
    }

    var graphicsUpdate: RDPSlowPathGraphicsUpdate? {
        guard pduType2 == 0x02 else {
            return nil
        }
        return try? RDPSlowPathGraphicsUpdate.parsePayload(payload)
    }

    var autoReconnectStatus: UInt32? {
        guard pduType2 == 0x32, payload.count == 4 else {
            return nil
        }
        return payload.littleEndianUInt32(at: 0)
    }

    var statusInfo: UInt32? {
        guard pduType2 == 0x36, payload.count == 4 else {
            return nil
        }
        return payload.littleEndianUInt32(at: 0)
    }

    var playSound: RDPPlaySoundPDU? {
        guard pduType2 == 0x22, payload.count == 8 else {
            return nil
        }
        return RDPPlaySoundPDU(
            duration: payload.littleEndianUInt32(at: 0),
            frequency: payload.littleEndianUInt32(at: 4)
        )
    }

    var saveSessionInfo: RDPSaveSessionInfoPDU? {
        guard pduType2 == 0x26 else {
            return nil
        }
        return try? RDPSaveSessionInfoPDU.parsePayload(payload)
    }

    var pointerUpdate: RDPServerPointerUpdate? {
        guard pduType2 == 0x1B else {
            return nil
        }
        return try? RDPServerPointerUpdate.parsePayload(payload)
    }

    var keyboardIndicatorUnitID: UInt16? {
        guard pduType2 == 0x29, payload.count == 4 else {
            return nil
        }
        return payload.littleEndianUInt16(at: 0)
    }

    var keyboardIndicatorFlags: RDPToggleKeyFlags? {
        guard pduType2 == 0x29, payload.count == 4 else {
            return nil
        }
        return RDPToggleKeyFlags(rawValue: UInt32(payload.littleEndianUInt16(at: 2)))
    }

    var keyboardIMEStatus: RDPKeyboardIMEStatus? {
        guard pduType2 == 0x2D, payload.count == 10 else {
            return nil
        }
        return RDPKeyboardIMEStatus(
            unitID: payload.littleEndianUInt16(at: 0),
            imeState: payload.littleEndianUInt32(at: 2),
            imeConversionMode: payload.littleEndianUInt32(at: 6)
        )
    }

    var monitorLayoutMonitorCount: UInt32? {
        guard pduType2 == 0x37, payload.count >= 4 else {
            return nil
        }
        return payload.littleEndianUInt32(at: 0)
    }

    var controlAction: UInt16? {
        guard pduType2 == 0x14, payload.count >= 2 else {
            return nil
        }
        return UInt16(payload[0]) | UInt16(payload[1]) << 8
    }

    var controlActionName: String? {
        guard let controlAction else {
            return nil
        }
        switch controlAction {
        case 0x0001:
            return "request-control"
        case 0x0002:
            return "granted-control"
        case 0x0003:
            return "detach"
        case 0x0004:
            return "cooperate"
        default:
            return "0x\(String(format: "%04x", controlAction))"
        }
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPShareDataPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        return try parseIfPresent(from: indication)
    }

    static func parseIfPresent(fromTPKT packet: Data, channelID: UInt16) throws -> RDPShareDataPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet),
              indication.channelID == channelID
        else {
            return nil
        }
        return try parseIfPresent(from: indication)
    }

    private static func parseIfPresent(from indication: MCSSendDataIndicationPDU) throws -> RDPShareDataPDU? {
        guard indication.userData.count >= 18 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let totalLength = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let pduSource = try cursor.readLittleEndianUInt16()
        let type = pduType & 0x000F
        let protocolVersion = pduType >> 4

        guard type == 0x0007 else {
            return nil
        }
        guard protocolVersion == 0x0001 else {
            return nil
        }
        guard totalLength != 0x8000 else {
            return nil
        }
        guard Int(totalLength) == indication.userData.count else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        guard Int(totalLength) >= RDPShareHeaderLength.data else {
            throw RDPDecodeError.invalidShareDataHeader
        }

        let shareID = try cursor.readLittleEndianUInt32()
        _ = try cursor.readUInt8()
        let streamID = try cursor.readUInt8()
        let uncompressedLength = try cursor.readLittleEndianUInt16()
        let pduType2 = try cursor.readUInt8()
        let compressedType = try cursor.readUInt8()
        let compressedLength = try cursor.readLittleEndianUInt16()
        try validateCompressionFields(compressedType: compressedType, compressedLength: compressedLength)
        try validateStreamID(streamID, pduType2: pduType2)
        let payloadLength = Int(totalLength) - RDPShareHeaderLength.data
        guard payloadLength >= 0, payloadLength <= cursor.remaining else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let payload = try cursor.readData(count: payloadLength)
        try validateShareDataPayloadLength(pduType2: pduType2, payloadLength: payload.count)
        try validateShareDataPayloadFields(pduType2: pduType2, payload: payload)
        try validateGraphicsUpdatePayloadIfPresent(pduType2: pduType2, payload: payload)
        try validateSaveSessionInfoPayloadIfPresent(pduType2: pduType2, payload: payload)
        try validatePointerPayloadIfPresent(pduType2: pduType2, payload: payload)
        try validateAutoReconnectStatusPayloadIfPresent(pduType2: pduType2, payload: payload)
        try validateMonitorLayoutPayloadIfPresent(pduType2: pduType2, payload: payload)
        if requiresZeroPDUSource(pduType2), pduSource != 0 {
            throw RDPDecodeError.invalidShareDataHeader
        }

        return RDPShareDataPDU(
            channelID: indication.channelID,
            shareID: shareID,
            pduSource: pduSource,
            streamID: streamID,
            uncompressedLength: uncompressedLength,
            pduType2: pduType2,
            compressedType: compressedType,
            compressedLength: compressedLength,
            payload: payload
        )
    }

    private static func validateShareDataPayloadLength(pduType2: UInt8, payloadLength: Int) throws {
        switch pduType2 {
        case 0x14, 0x28:
            guard payloadLength == 8 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x29:
            guard payloadLength == 4 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x22:
            guard payloadLength == 8 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x2D:
            guard payloadLength == 10 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x1F, 0x2F, 0x32, 0x36:
            guard payloadLength == 4 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        default:
            return
        }
    }

    private static func validateCompressionFields(compressedType: UInt8, compressedLength: UInt16) throws {
        let compressionPackage = compressedType & 0x0F
        let reservedFlags = compressedType & 0x10

        guard compressionPackage <= 0x03, reservedFlags == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        guard compressedType & 0x20 == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        guard compressedLength == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateStreamID(_ streamID: UInt8, pduType2: UInt8) throws {
        switch streamID {
        case 0x00:
            guard pduType2 == 0x1F else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x01, 0x02, 0x04:
            return
        default:
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateShareDataPayloadFields(pduType2: UInt8, payload: Data) throws {
        switch pduType2 {
        case 0x1F:
            guard payload.littleEndianUInt16(at: 0) == 0x0001 else {
                throw RDPDecodeError.invalidShareDataHeader
            }
        case 0x14:
            try validateControlPayloadFields(payload)
        default:
            return
        }
    }

    private static func validateControlPayloadFields(_ payload: Data) throws {
        let action = payload.littleEndianUInt16(at: 0)

        switch action {
        case 0x0001, 0x0002, 0x0003, 0x0004:
            return
        default:
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateGraphicsUpdatePayloadIfPresent(pduType2: UInt8, payload: Data) throws {
        guard pduType2 == 0x02 else {
            return
        }
        do {
            _ = try RDPSlowPathGraphicsUpdate.parsePayload(payload)
        } catch {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateSaveSessionInfoPayloadIfPresent(pduType2: UInt8, payload: Data) throws {
        guard pduType2 == 0x26 else {
            return
        }
        do {
            _ = try RDPSaveSessionInfoPDU.parsePayload(payload)
        } catch {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validatePointerPayloadIfPresent(pduType2: UInt8, payload: Data) throws {
        guard pduType2 == 0x1B else {
            return
        }
        _ = try RDPServerPointerUpdate.parsePayload(payload)
    }

    private static func validateAutoReconnectStatusPayloadIfPresent(pduType2: UInt8, payload: Data) throws {
        guard pduType2 == 0x32 else {
            return
        }
        guard payload.littleEndianUInt32(at: 0) == 0 else {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func validateMonitorLayoutPayloadIfPresent(pduType2: UInt8, payload: Data) throws {
        guard pduType2 == 0x37 else {
            return
        }
        guard payload.count >= 4,
              (payload.count - 4).isMultiple(of: 20)
        else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let monitorCount = payload.littleEndianUInt32(at: 0)
        guard monitorCount == UInt32((payload.count - 4) / 20) else {
            throw RDPDecodeError.invalidShareDataHeader
        }
    }

    private static func requiresZeroPDUSource(_ pduType2: UInt8) -> Bool {
        switch pduType2 {
        case 0x2F, 0x32, 0x36, 0x37:
            return true
        default:
            return false
        }
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
