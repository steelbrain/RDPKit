import Foundation
@preconcurrency import NIOCore

enum RDPDeviceRedirectionComponent {
    static let core: UInt16 = 0x4472
}

enum RDPDeviceRedirectionPacketID {
    static let serverAnnounce: UInt16 = 0x496E
    static let clientIDConfirm: UInt16 = 0x4343
    static let clientName: UInt16 = 0x434E
    static let deviceListAnnounce: UInt16 = 0x4441
    static let serverCapability: UInt16 = 0x5350
    static let clientCapability: UInt16 = 0x4350
    static let userLoggedOn: UInt16 = 0x554C
}

enum RDPDeviceRedirectionVersion {
    static let major: UInt16 = 0x0001
    static let minorRDP51: UInt16 = 0x0005
    static let minorRDP6: UInt16 = 0x000C
}

private enum RDPDeviceRedirectionCapability {
    static let generalType: UInt16 = 0x0001
    static let generalVersion2: UInt32 = 0x0000_0002
    static let generalLength: UInt16 = 44
}

private enum RDPDeviceRedirectionIOCode1 {
    static let required: UInt32 = 0x0000_3FFF
}

private enum RDPDeviceRedirectionExtendedPDU {
    static let deviceRemove: UInt32 = 0x0000_0001
    static let clientDisplayName: UInt32 = 0x0000_0002
    static let userLoggedOn: UInt32 = 0x0000_0004
}

struct RDPDeviceRedirectionHeader: Equatable, Sendable {
    var component: UInt16
    var packetID: UInt16

    init(
        component: UInt16 = RDPDeviceRedirectionComponent.core,
        packetID: UInt16
    ) {
        self.component = component
        self.packetID = packetID
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPDeviceRedirectionHeader {
        try RDPDeviceRedirectionHeader(
            component: cursor.readLittleEndianUInt16(),
            packetID: cursor.readLittleEndianUInt16()
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(component)
        data.appendLittleEndianUInt16(packetID)
        return data
    }
}

struct RDPDeviceRedirectionPDU: Equatable, Sendable {
    var header: RDPDeviceRedirectionHeader
    var payload: Data

    var typeName: String {
        switch header.packetID {
        case RDPDeviceRedirectionPacketID.serverAnnounce:
            "rdpdr-server-announce"
        case RDPDeviceRedirectionPacketID.clientIDConfirm:
            "rdpdr-client-id-confirm"
        case RDPDeviceRedirectionPacketID.clientName:
            "rdpdr-client-name"
        case RDPDeviceRedirectionPacketID.deviceListAnnounce:
            "rdpdr-device-list-announce"
        case RDPDeviceRedirectionPacketID.serverCapability:
            "rdpdr-server-capability"
        case RDPDeviceRedirectionPacketID.clientCapability:
            "rdpdr-client-capability"
        case RDPDeviceRedirectionPacketID.userLoggedOn:
            "rdpdr-user-logged-on"
        default:
            "rdpdr-0x\(String(format: "%04x", header.packetID))"
        }
    }

    static func parse(from data: Data) throws -> RDPDeviceRedirectionPDU {
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(data)
        let header = try RDPDeviceRedirectionHeader.parse(from: &cursor)
        return RDPDeviceRedirectionPDU(header: header, payload: cursor.readRemainingData())
    }

    func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }
}

struct RDPDeviceRedirectionVersionAndID: Equatable, Sendable {
    var major: UInt16
    var minor: UInt16
    var clientID: UInt32

    static func parse(from pdu: RDPDeviceRedirectionPDU) throws -> RDPDeviceRedirectionVersionAndID? {
        guard pdu.header.component == RDPDeviceRedirectionComponent.core,
              pdu.header.packetID == RDPDeviceRedirectionPacketID.serverAnnounce
                || pdu.header.packetID == RDPDeviceRedirectionPacketID.clientIDConfirm
        else {
            return nil
        }
        guard pdu.payload.count >= 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPDeviceRedirectionVersionAndID(
            major: cursor.readLittleEndianUInt16(),
            minor: cursor.readLittleEndianUInt16(),
            clientID: cursor.readLittleEndianUInt32()
        )
    }

    func clientAnnounceReplyEncoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.minorRDP6)
        payload.appendLittleEndianUInt32(clientID)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientIDConfirm),
            payload: payload
        ).encoded()
    }
}

struct RDPDeviceRedirectionClientNameRequest: Equatable, Sendable {
    var computerName: String

    func encoded() -> Data {
        let computerName = utf16LENullTerminated(self.computerName)
        var payload = Data()
        payload.appendLittleEndianUInt32(1)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(UInt32(computerName.count))
        payload.append(computerName)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientName),
            payload: payload
        ).encoded()
    }
}

struct RDPDeviceRedirectionClientCapabilities: Equatable, Sendable {
    var minorVersion: UInt16

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(0)
        payload.append(generalCapabilityEncoded())
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientCapability),
            payload: payload
        ).encoded()
    }

    private func generalCapabilityEncoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPDeviceRedirectionCapability.generalType)
        data.appendLittleEndianUInt16(RDPDeviceRedirectionCapability.generalLength)
        data.appendLittleEndianUInt32(RDPDeviceRedirectionCapability.generalVersion2)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
        data.appendLittleEndianUInt16(minorVersion)
        data.appendLittleEndianUInt32(RDPDeviceRedirectionIOCode1.required)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(
            RDPDeviceRedirectionExtendedPDU.deviceRemove
                | RDPDeviceRedirectionExtendedPDU.clientDisplayName
                | RDPDeviceRedirectionExtendedPDU.userLoggedOn
        )
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        return data
    }
}

struct RDPDeviceRedirectionDeviceListAnnounce: Equatable, Sendable {
    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(0)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.deviceListAnnounce),
            payload: payload
        ).encoded()
    }
}

final class RDPDeviceRedirectionSession: @unchecked Sendable {
    let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let computerName: String
    private let lock = NSLock()
    private var minorVersion = RDPDeviceRedirectionVersion.minorRDP6

    init(
        userChannelID: UInt16,
        staticChannelID: UInt16,
        channel: Channel,
        computerName: String
    ) {
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
        self.computerName = computerName
    }

    func receive(_ pdu: RDPDeviceRedirectionPDU) throws {
        guard pdu.header.component == RDPDeviceRedirectionComponent.core else {
            return
        }

        switch pdu.header.packetID {
        case RDPDeviceRedirectionPacketID.serverAnnounce:
            guard let announce = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) else {
                return
            }
            lock.lock()
            minorVersion = min(RDPDeviceRedirectionVersion.minorRDP6, announce.minor)
            lock.unlock()
            send(announce.clientAnnounceReplyEncoded())
            send(RDPDeviceRedirectionClientNameRequest(computerName: computerName).encoded())

        case RDPDeviceRedirectionPacketID.serverCapability:
            send(RDPDeviceRedirectionClientCapabilities(minorVersion: currentMinorVersion()).encoded())

        case RDPDeviceRedirectionPacketID.clientIDConfirm:
            if let confirm = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) {
                lock.lock()
                minorVersion = confirm.minor
                lock.unlock()
                if confirm.minor == RDPDeviceRedirectionVersion.minorRDP51 {
                    send(RDPDeviceRedirectionDeviceListAnnounce().encoded())
                }
            }

        case RDPDeviceRedirectionPacketID.userLoggedOn:
            send(RDPDeviceRedirectionDeviceListAnnounce().encoded())

        default:
            return
        }
    }

    private func currentMinorVersion() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return minorVersion
    }

    private func send(_ payload: Data) {
        let packet = RDPStaticVirtualChannelPDU(payload: payload)
            .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            var buffer = self.channel.allocator.buffer(capacity: packet.count)
            buffer.writeBytes(packet)
            self.channel.writeAndFlush(buffer, promise: nil)
        }
    }
}

private func utf16LENullTerminated(_ value: String) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.appendLittleEndianUInt16(0)
    return data
}
