import Foundation

struct RDPServerLicensePDU: Equatable, Sendable {
    var channelID: UInt16
    var securityFlags: UInt16
    var messageType: UInt8
    var flags: UInt8
    var messageSize: UInt16
    var errorCode: UInt32?
    var stateTransition: UInt32?

    var typeName: String {
        guard messageType == 0xFF else {
            return "license-message-0x\(String(format: "%02x", messageType))"
        }
        guard errorCode == 0x0000_0007 else {
            return "license-error-0x\(String(format: "%08x", errorCode ?? 0))"
        }
        return "license-error-valid-client"
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPServerLicensePDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 8 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let securityFlags = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        guard securityFlags & 0x0080 != 0 else {
            return nil
        }
        guard securityFlags & 0x0008 == 0 else {
            throw RDPDecodeError.invalidLicensePDU
        }

        let messageType = try cursor.readUInt8()
        let flags = try cursor.readUInt8()
        let messageSize = try cursor.readLittleEndianUInt16()
        guard messageSize >= 4, Int(messageSize) <= cursor.remaining + 4 else {
            throw RDPDecodeError.invalidLicensePDU
        }
        let messageBody = try cursor.readData(count: Int(messageSize) - 4)

        var errorCode: UInt32?
        var stateTransition: UInt32?
        if messageType == 0xFF {
            var messageCursor = ByteCursor(messageBody)
            guard messageCursor.remaining >= 12 else {
                throw RDPDecodeError.invalidLicensePDU
            }
            errorCode = try messageCursor.readLittleEndianUInt32()
            stateTransition = try messageCursor.readLittleEndianUInt32()
            _ = try messageCursor.readLittleEndianUInt16()
            let blobLength = try messageCursor.readLittleEndianUInt16()
            guard Int(blobLength) <= messageCursor.remaining else {
                throw RDPDecodeError.invalidLicensePDU
            }
            _ = try messageCursor.readData(count: Int(blobLength))
        }

        return RDPServerLicensePDU(
            channelID: indication.channelID,
            securityFlags: securityFlags,
            messageType: messageType,
            flags: flags,
            messageSize: messageSize,
            errorCode: errorCode,
            stateTransition: stateTransition
        )
    }
}
