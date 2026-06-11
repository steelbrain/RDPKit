import Foundation

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
        guard totalLength == 0x8000 || Int(totalLength) <= indication.userData.count else {
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
        case 0x23:
            "suppress-output"
        case 0x26:
            "save-session-info"
        case 0x28:
            "font-map"
        default:
            "share-data-0x\(String(format: "%02x", pduType2))"
        }
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
        guard totalLength == 0x8000 || Int(totalLength) <= indication.userData.count else {
            throw RDPDecodeError.invalidShareDataHeader
        }

        let shareID = try cursor.readLittleEndianUInt32()
        _ = try cursor.readUInt8()
        let streamID = try cursor.readUInt8()
        let uncompressedLength = try cursor.readLittleEndianUInt16()
        let pduType2 = try cursor.readUInt8()
        let compressedType = try cursor.readUInt8()
        let compressedLength = try cursor.readLittleEndianUInt16()
        let payloadLength = totalLength == 0x8000
            ? cursor.remaining
            : Int(totalLength) - 18
        guard payloadLength >= 0, payloadLength <= cursor.remaining else {
            throw RDPDecodeError.invalidShareDataHeader
        }
        let payload = try cursor.readData(count: payloadLength)

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
}
