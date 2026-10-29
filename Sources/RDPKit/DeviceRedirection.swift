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
    static let minorRDP6: UInt16 = 0x000C
}

/// GENERAL_CAPS_SET values the client sends ([MS-RDPEFS] 2.2.2.7.1).
private enum RDPDeviceRedirectionGeneralCapability {
    static let type: UInt16 = 0x0001
    static let length: UInt16 = 44
    static let version2: UInt32 = 0x0000_0002
    static let allIOCode1: UInt32 = 0x0000_FFFF
    /// RDPDR_DEVICE_REMOVE_PDUS | RDPDR_CLIENT_DISPLAY_NAME_PDU | RDPDR_USER_LOGGEDON_PDU.
    static let extendedPDU: UInt32 = 0x0000_0007
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
        return try RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(
                component: cursor.readLittleEndianUInt16(),
                packetID: cursor.readLittleEndianUInt16()
            ),
            payload: cursor.readRemainingData()
        )
    }

    func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }
}

/// Body shared by the Server Announce Request and the Client Announce Reply /
/// Server Client ID Confirm ([MS-RDPEFS] 2.2.2.2, 2.2.2.3, 2.2.2.6).
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
        guard pdu.payload.count == 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let versionAndID = try RDPDeviceRedirectionVersionAndID(
            major: cursor.readLittleEndianUInt16(),
            minor: cursor.readLittleEndianUInt16(),
            clientID: cursor.readLittleEndianUInt32()
        )
        // Any server minor version is accepted: the client replies with its own version
        // (MS-RDPEFS 3.2.5.1.3), and Appendix A lists values beyond those in 2.2.2.2.
        guard versionAndID.major == RDPDeviceRedirectionVersion.major else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        return versionAndID
    }

    func clientAnnounceReplyEncoded(clientID: UInt32) -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.minorRDP6)
        payload.appendLittleEndianUInt32(clientID)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientIDConfirm),
            payload: payload
        ).encoded()
    }

    /// Echoes the server's ClientId from minor version 12 on and generates a
    /// random one for older servers ([MS-RDPEFS] 3.2.5.1.3).
    func clientIDForReply(clientIDGenerator: () -> UInt32) -> UInt32 {
        guard minor >= RDPDeviceRedirectionVersion.minorRDP6 else {
            return clientIDGenerator()
        }
        return clientID
    }
}

struct RDPDeviceRedirectionClientNameRequest: Equatable, Sendable {
    var computerName: String

    func encoded() -> Data {
        var computerName = Data(utf16LittleEndian: self.computerName)
        computerName.appendLittleEndianUInt16(0)
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

/// Client Core Capability Response carrying only the general capability set,
/// since the client redirects no devices ([MS-RDPEFS] 2.2.2.8).
struct RDPDeviceRedirectionClientCapabilities: Equatable, Sendable {
    var minorVersion: UInt16

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(0)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionGeneralCapability.type)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionGeneralCapability.length)
        payload.appendLittleEndianUInt32(RDPDeviceRedirectionGeneralCapability.version2)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt16(RDPDeviceRedirectionVersion.major)
        payload.appendLittleEndianUInt16(minorVersion)
        payload.appendLittleEndianUInt32(RDPDeviceRedirectionGeneralCapability.allIOCode1)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(RDPDeviceRedirectionGeneralCapability.extendedPDU)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(0)
        payload.appendLittleEndianUInt32(0)
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientCapability),
            payload: payload
        ).encoded()
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

/// Runs the rdpdr initialization with an empty device list ([MS-RDPEFS] 3.1.3).
/// The channel exists for audio: Windows sends nothing on RDPSND unless the
/// client advertises rdpdr ([MS-RDPEA] Appendix A, note on section 2.1).
final class RDPDeviceRedirectionSession: @unchecked Sendable {
    let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let computerName: String
    private let lock = NSLock()
    private var minorVersion = RDPDeviceRedirectionVersion.minorRDP6
    private var announcedClientID: UInt32?

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
            let clientID = announce.clientIDForReply {
                UInt32.random(in: UInt32.min ... UInt32.max)
            }
            lock.withLock {
                minorVersion = min(RDPDeviceRedirectionVersion.minorRDP6, announce.minor)
                announcedClientID = clientID
            }
            send(announce.clientAnnounceReplyEncoded(clientID: clientID))
            send(RDPDeviceRedirectionClientNameRequest(computerName: computerName).encoded())

        case RDPDeviceRedirectionPacketID.serverCapability:
            let minorVersion = lock.withLock { self.minorVersion }
            send(RDPDeviceRedirectionClientCapabilities(minorVersion: minorVersion).encoded())

        case RDPDeviceRedirectionPacketID.clientIDConfirm:
            guard let confirm = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) else {
                return
            }
            // The confirmed ClientId MUST match the Client Announce Reply ([MS-RDPEFS] 3.2.5.1.6).
            guard confirm.clientID == lock.withLock({ announcedClientID }) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            send(RDPDeviceRedirectionDeviceListAnnounce().encoded())

        case RDPDeviceRedirectionPacketID.userLoggedOn:
            guard pdu.payload.isEmpty else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            send(RDPDeviceRedirectionDeviceListAnnounce().encoded())

        default:
            return
        }
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
