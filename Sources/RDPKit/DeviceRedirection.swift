import Foundation
@preconcurrency import NIOCore

enum RDPDeviceRedirectionComponent {
    static let core: UInt16 = 0x4472
    static let printer: UInt16 = 0x5052
}

enum RDPDeviceRedirectionPacketID {
    static let serverAnnounce: UInt16 = 0x496E
    static let clientIDConfirm: UInt16 = 0x4343
    static let clientName: UInt16 = 0x434E
    static let deviceListAnnounce: UInt16 = 0x4441
    static let deviceReply: UInt16 = 0x6472
    static let deviceIORequest: UInt16 = 0x4952
    static let deviceIOCompletion: UInt16 = 0x4943
    static let serverCapability: UInt16 = 0x5350
    static let clientCapability: UInt16 = 0x4350
    static let deviceListRemove: UInt16 = 0x444D
    static let printerCacheData: UInt16 = 0x5043
    static let userLoggedOn: UInt16 = 0x554C
    static let printerUsingXPS: UInt16 = 0x5543

    static func isValid(_ packetID: UInt16, for component: UInt16) -> Bool {
        switch (component, packetID) {
        case (RDPDeviceRedirectionComponent.core, serverAnnounce),
             (RDPDeviceRedirectionComponent.core, clientIDConfirm),
             (RDPDeviceRedirectionComponent.core, clientName),
             (RDPDeviceRedirectionComponent.core, deviceListAnnounce),
             (RDPDeviceRedirectionComponent.core, deviceReply),
             (RDPDeviceRedirectionComponent.core, deviceIORequest),
             (RDPDeviceRedirectionComponent.core, deviceIOCompletion),
             (RDPDeviceRedirectionComponent.core, serverCapability),
             (RDPDeviceRedirectionComponent.core, clientCapability),
             (RDPDeviceRedirectionComponent.core, deviceListRemove),
             (RDPDeviceRedirectionComponent.core, userLoggedOn),
             (RDPDeviceRedirectionComponent.printer, printerCacheData),
             (RDPDeviceRedirectionComponent.printer, printerUsingXPS):
            true
        default:
            false
        }
    }
}

enum RDPDeviceRedirectionVersion {
    static let major: UInt16 = 0x0001
    static let minorRDP5: UInt16 = 0x0002
    static let minorRDP51: UInt16 = 0x0005
    static let minorRDP52: UInt16 = 0x000A
    static let minorRDP6: UInt16 = 0x000C
    static let minorRDP61: UInt16 = 0x000D

    static func isValidMinor(_ minor: UInt16) -> Bool {
        switch minor {
        case minorRDP5, minorRDP51, minorRDP52, minorRDP6, minorRDP61:
            true
        default:
            false
        }
    }
}

private enum RDPDeviceRedirectionCapability {
    static let generalType: UInt16 = 0x0001
    static let printerType: UInt16 = 0x0002
    static let portType: UInt16 = 0x0003
    static let driveType: UInt16 = 0x0004
    static let smartCardType: UInt16 = 0x0005
    static let headerLength: UInt16 = 8
    static let generalVersion1: UInt32 = 0x0000_0001
    static let generalVersion2: UInt32 = 0x0000_0002
    static let generalVersion1Length: UInt16 = 40
    static let generalLength: UInt16 = 44
    static let deviceVersion1: UInt32 = 0x0000_0001
    static let driveVersion2: UInt32 = 0x0000_0002
}

private enum RDPDeviceRedirectionIOCode1 {
    static let supported: UInt32 = 0x0000_FFFF
    static let validMask: UInt32 = 0x0000_FFFF
}

private enum RDPDeviceRedirectionExtendedPDU {
    static let deviceRemove: UInt32 = 0x0000_0001
    static let clientDisplayName: UInt32 = 0x0000_0002
    static let userLoggedOn: UInt32 = 0x0000_0004
    static let validMask: UInt32 = deviceRemove | clientDisplayName | userLoggedOn
}

private enum RDPDeviceRedirectionExtraFlags1 {
    static let enableAsyncIO: UInt32 = 0x0000_0001
    static let validMask: UInt32 = enableAsyncIO
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
        guard RDPDeviceRedirectionPacketID.isValid(header.packetID, for: header.component)
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
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
        guard pdu.payload.count == 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let versionAndID = try RDPDeviceRedirectionVersionAndID(
            major: cursor.readLittleEndianUInt16(),
            minor: cursor.readLittleEndianUInt16(),
            clientID: cursor.readLittleEndianUInt32()
        )
        guard versionAndID.major == RDPDeviceRedirectionVersion.major,
              RDPDeviceRedirectionVersion.isValidMinor(versionAndID.minor)
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        return versionAndID
    }

    func clientAnnounceReplyEncoded(
        clientIDGenerator: () -> UInt32 = { UInt32.random(in: UInt32.min ... UInt32.max) }
    ) -> Data {
        clientAnnounceReplyEncoded(clientID: clientIDForReply(clientIDGenerator: clientIDGenerator))
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
        data.appendLittleEndianUInt32(RDPDeviceRedirectionIOCode1.supported)
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

struct RDPDeviceRedirectionServerCapabilities: Equatable, Sendable {
    struct Capability: Equatable, Sendable {
        var type: UInt16
        var version: UInt32
    }

    var capabilities: [Capability]

    static func parse(from pdu: RDPDeviceRedirectionPDU) throws -> RDPDeviceRedirectionServerCapabilities? {
        guard pdu.header.component == RDPDeviceRedirectionComponent.core,
              pdu.header.packetID == RDPDeviceRedirectionPacketID.serverCapability
        else {
            return nil
        }
        guard !pdu.payload.isEmpty else {
            return RDPDeviceRedirectionServerCapabilities(capabilities: [])
        }
        guard pdu.payload.count >= 4 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let count = try Int(cursor.readLittleEndianUInt16())
        _ = try cursor.readLittleEndianUInt16()

        var capabilities: [Capability] = []
        capabilities.reserveCapacity(count)
        for _ in 0 ..< count {
            guard cursor.remaining >= Int(RDPDeviceRedirectionCapability.headerLength) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            let type = try cursor.readLittleEndianUInt16()
            let length = try cursor.readLittleEndianUInt16()
            let version = try cursor.readLittleEndianUInt32()
            guard length >= RDPDeviceRedirectionCapability.headerLength,
                  Int(length) - Int(RDPDeviceRedirectionCapability.headerLength) <= cursor.remaining
            else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            let body = try cursor.readData(count: Int(length) - Int(RDPDeviceRedirectionCapability.headerLength))
            try validateCapability(type: type, length: length, version: version, body: body)
            capabilities.append(Capability(type: type, version: version))
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        return RDPDeviceRedirectionServerCapabilities(capabilities: capabilities)
    }

    private static func validateCapability(
        type: UInt16,
        length: UInt16,
        version: UInt32,
        body: Data
    ) throws {
        switch type {
        case RDPDeviceRedirectionCapability.generalType:
            try validateGeneralCapability(length: length, version: version, body: body)
        case RDPDeviceRedirectionCapability.printerType,
             RDPDeviceRedirectionCapability.portType,
             RDPDeviceRedirectionCapability.smartCardType:
            guard length == RDPDeviceRedirectionCapability.headerLength,
                  version == RDPDeviceRedirectionCapability.deviceVersion1
            else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        case RDPDeviceRedirectionCapability.driveType:
            guard length == RDPDeviceRedirectionCapability.headerLength,
                  version == RDPDeviceRedirectionCapability.deviceVersion1
                    || version == RDPDeviceRedirectionCapability.driveVersion2
            else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        default:
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
    }

    private static func validateGeneralCapability(
        length: UInt16,
        version: UInt32,
        body: Data
    ) throws {
        let expectedLength: UInt16
        switch version {
        case RDPDeviceRedirectionCapability.generalVersion1:
            expectedLength = RDPDeviceRedirectionCapability.generalVersion1Length
        case RDPDeviceRedirectionCapability.generalVersion2:
            expectedLength = RDPDeviceRedirectionCapability.generalLength
        default:
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard length == expectedLength,
              body.count == Int(expectedLength) - Int(RDPDeviceRedirectionCapability.headerLength)
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(body)
        _ = try cursor.readLittleEndianUInt32()
        _ = try cursor.readLittleEndianUInt32()
        let protocolMajorVersion = try cursor.readLittleEndianUInt16()
        let protocolMinorVersion = try cursor.readLittleEndianUInt16()
        let ioCode1 = try cursor.readLittleEndianUInt32()
        let ioCode2 = try cursor.readLittleEndianUInt32()
        let extendedPDU = try cursor.readLittleEndianUInt32()
        let extraFlags1 = try cursor.readLittleEndianUInt32()
        let extraFlags2 = try cursor.readLittleEndianUInt32()
        if version == RDPDeviceRedirectionCapability.generalVersion2 {
            _ = try cursor.readLittleEndianUInt32()
        }

        guard protocolMajorVersion == RDPDeviceRedirectionVersion.major,
              RDPDeviceRedirectionVersion.isValidMinor(protocolMinorVersion),
              ioCode1 & ~RDPDeviceRedirectionIOCode1.validMask == 0,
              ioCode2 == 0,
              extendedPDU & ~RDPDeviceRedirectionExtendedPDU.validMask == 0,
              extraFlags1 & ~RDPDeviceRedirectionExtraFlags1.validMask == 0,
              extraFlags2 == 0,
              cursor.remaining == 0
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
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
            lock.lock()
            minorVersion = min(RDPDeviceRedirectionVersion.minorRDP6, announce.minor)
            announcedClientID = clientID
            lock.unlock()
            send(announce.clientAnnounceReplyEncoded(clientID: clientID))
            send(RDPDeviceRedirectionClientNameRequest(computerName: computerName).encoded())

        case RDPDeviceRedirectionPacketID.serverCapability:
            _ = try RDPDeviceRedirectionServerCapabilities.parse(from: pdu)
            send(RDPDeviceRedirectionClientCapabilities(minorVersion: currentMinorVersion()).encoded())

        case RDPDeviceRedirectionPacketID.clientIDConfirm:
            if let confirm = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) {
                lock.lock()
                let clientIDMatches = confirm.clientID == announcedClientID
                if clientIDMatches {
                    minorVersion = confirm.minor
                }
                lock.unlock()
                guard clientIDMatches else {
                    throw RDPDecodeError.invalidStaticVirtualChannelPDU
                }
                if confirm.minor == RDPDeviceRedirectionVersion.minorRDP51 {
                    send(RDPDeviceRedirectionDeviceListAnnounce().encoded())
                }
            }

        case RDPDeviceRedirectionPacketID.userLoggedOn:
            guard pdu.payload.isEmpty else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
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
