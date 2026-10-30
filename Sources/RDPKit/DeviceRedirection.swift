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
    static let deviceReply: UInt16 = 0x6472
    static let deviceIORequest: UInt16 = 0x4952
    static let deviceIOCompletion: UInt16 = 0x4943
}

enum RDPDeviceRedirectionVersion {
    static let major: UInt16 = 0x0001
    /// Servers this old send no User Logged On, so drives are announced on Client ID Confirm.
    static let minorRDP51: UInt16 = 0x0005
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

/// DRIVE_CAPS_SET: a capability header alone ([MS-RDPEFS] 2.2.2.7.5).
private enum RDPDeviceRedirectionDriveCapability {
    static let type: UInt16 = 0x0004
    static let length: UInt16 = 8
    static let version2: UInt32 = 0x0000_0002
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
        case RDPDeviceRedirectionPacketID.deviceReply:
            "rdpdr-device-reply"
        case RDPDeviceRedirectionPacketID.deviceIORequest:
            "rdpdr-device-io-request"
        case RDPDeviceRedirectionPacketID.deviceIOCompletion:
            "rdpdr-device-io-completion"
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

/// Client Core Capability Response: the general capability set, and the drive
/// set when drives are shared ([MS-RDPEFS] 2.2.2.8).
struct RDPDeviceRedirectionClientCapabilities: Equatable, Sendable {
    var minorVersion: UInt16
    var sharesDrives = false

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(sharesDrives ? 2 : 1)
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
        if sharesDrives {
            // A server does not take a filesystem device from a client that did not
            // advertise drive support.
            payload.appendLittleEndianUInt16(RDPDeviceRedirectionDriveCapability.type)
            payload.appendLittleEndianUInt16(RDPDeviceRedirectionDriveCapability.length)
            payload.appendLittleEndianUInt32(RDPDeviceRedirectionDriveCapability.version2)
        }
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.clientCapability),
            payload: payload
        ).encoded()
    }
}

/// DEVICE_ANNOUNCE for one device ([MS-RDPEFS] 2.2.1.3).
struct RDPDeviceAnnounce: Equatable, Sendable {
    var deviceType: UInt32
    var deviceID: UInt32
    /// Up to eight ASCII characters, not NUL-terminated when eight long.
    var preferredDOSName: String
    var deviceData: Data

    /// A filesystem device. Its DeviceData is the drive name as NUL-terminated ASCII,
    /// which Windows shows as `\\tsclient\<name>`, as FreeRDP's drive channel sends it.
    static func drive(deviceID: UInt32, name: String) -> RDPDeviceAnnounce {
        let name = deviceName(name)
        var deviceData = Data(name.utf8)
        deviceData.appendUInt8(0)
        return RDPDeviceAnnounce(
            deviceType: RDPDeviceType.filesystem,
            deviceID: deviceID,
            preferredDOSName: String(name.prefix(8)),
            deviceData: deviceData
        )
    }

    /// A name a server accepts: ASCII without the characters DEVICE_ANNOUNCE forbids,
    /// each other character replaced by `_`, as FreeRDP does.
    static func deviceName(_ name: String) -> String {
        let characters = name.unicodeScalars.map { scalar -> Character in
            guard scalar.isASCII, scalar.value >= 0x21, !"<>\"/\\|:*?".unicodeScalars.contains(scalar) else {
                return "_"
            }
            return Character(scalar)
        }
        return characters.isEmpty ? "_" : String(characters)
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(deviceType)
        data.appendLittleEndianUInt32(deviceID)
        let dosName = Data(preferredDOSName.utf8.prefix(8))
        data.append(dosName)
        data.append(Data(count: 8 - dosName.count))
        data.appendLittleEndianUInt32(UInt32(deviceData.count))
        data.append(deviceData)
        return data
    }
}

struct RDPDeviceRedirectionDeviceListAnnounce: Equatable, Sendable {
    var devices: [RDPDeviceAnnounce] = []

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(UInt32(devices.count))
        for device in devices {
            payload.append(device.encoded())
        }
        return RDPDeviceRedirectionPDU(
            header: RDPDeviceRedirectionHeader(packetID: RDPDeviceRedirectionPacketID.deviceListAnnounce),
            payload: payload
        ).encoded()
    }
}

/// What the application is told about device redirection.
enum RDPDeviceRedirectionEvent: Equatable, Sendable {
    /// The drive's folder does not exist, so it was not announced.
    case driveUnavailable(name: String)
    /// The server refused the drive with an NTSTATUS ([MS-RDPEFS] 2.2.2.1).
    case driveRejected(name: String, status: UInt32)
}

/// Runs the rdpdr initialization ([MS-RDPEFS] 3.1.3) and serves the shared drives.
/// The channel also exists for audio: Windows sends nothing on RDPSND unless the
/// client advertises rdpdr ([MS-RDPEA] Appendix A, note on section 2.1).
///
/// Drive I/O runs on a serial queue of its own, so file access never holds up the
/// connection thread that receives graphics.
final class RDPDeviceRedirectionSession: @unchecked Sendable {
    let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let computerName: String
    private let chunkSize: RDPStaticVirtualChannelChunkSize
    private let drives: [RDPSharedDriveDevice]
    private let ioQueue = DispatchQueue(label: "RDPKit.device-redirection")
    /// Drive I/O waits on it, so a server that stops reading stops the reads it asked for.
    private let replyBudget = RDPOutboundByteBudget()
    private let lock = NSLock()
    private var minorVersion = RDPDeviceRedirectionVersion.minorRDP6
    private var announcedClientID: UInt32?
    /// Only the connection thread reads and writes these.
    private var announcedDriveIDs: Set<UInt32> = []
    private var hasAnnouncedDrives = false

    init(
        userChannelID: UInt16,
        staticChannelID: UInt16,
        channel: Channel,
        computerName: String,
        drives: [RDPSharedDrive] = [],
        chunkSize: RDPStaticVirtualChannelChunkSize = RDPStaticVirtualChannelChunkSize()
    ) {
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
        self.computerName = computerName
        self.chunkSize = chunkSize
        self.drives = drives.enumerated().map { RDPSharedDriveDevice(deviceID: UInt32($0.offset + 1), drive: $0.element) }
    }

    @discardableResult
    func receive(_ pdu: RDPDeviceRedirectionPDU) throws -> [RDPDeviceRedirectionEvent] {
        guard pdu.header.component == RDPDeviceRedirectionComponent.core else {
            return []
        }

        switch pdu.header.packetID {
        case RDPDeviceRedirectionPacketID.serverAnnounce:
            guard let announce = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) else {
                return []
            }
            let clientID = announce.clientIDForReply {
                UInt32.random(in: UInt32.min ... UInt32.max)
            }
            lock.withLock {
                minorVersion = min(RDPDeviceRedirectionVersion.minorRDP6, announce.minor)
                announcedClientID = clientID
            }
            // A server starting over has forgotten the devices and their handles. FreeRDP
            // 3.32 re-initializes its devices and announces them again on each Server
            // Announce, which Windows servers send with I/O still pending (rdpdr_main.c,
            // rdpdr_process_init).
            announcedDriveIDs = []
            hasAnnouncedDrives = false
            let drives = drives
            ioQueue.async {
                drives.forEach { $0.closeAllFiles() }
            }
            send(announce.clientAnnounceReplyEncoded(clientID: clientID))
            send(RDPDeviceRedirectionClientNameRequest(computerName: computerName).encoded())

        case RDPDeviceRedirectionPacketID.serverCapability:
            let minorVersion = lock.withLock { self.minorVersion }
            send(RDPDeviceRedirectionClientCapabilities(
                minorVersion: minorVersion,
                sharesDrives: !drives.isEmpty
            ).encoded())

        case RDPDeviceRedirectionPacketID.clientIDConfirm:
            guard let confirm = try RDPDeviceRedirectionVersionAndID.parse(from: pdu) else {
                return []
            }
            // The confirmed ClientId MUST match the Client Announce Reply ([MS-RDPEFS] 3.2.5.1.6).
            guard confirm.clientID == lock.withLock({ announcedClientID }) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            // Drives wait for User Logged On, as in FreeRDP, from servers that send it.
            let announcesDrives = lock.withLock { minorVersion } <= RDPDeviceRedirectionVersion.minorRDP51
            return announceDevices(includingDrives: announcesDrives)

        case RDPDeviceRedirectionPacketID.userLoggedOn:
            guard pdu.payload.isEmpty else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            return announceDevices(includingDrives: true)

        case RDPDeviceRedirectionPacketID.deviceReply:
            var cursor = ByteCursor(pdu.payload)
            let deviceID = try cursor.readLittleEndianUInt32()
            let status = try cursor.readLittleEndianUInt32()
            guard status != RDPNTStatus.success, let drive = drives.first(where: { $0.deviceID == deviceID }) else {
                return []
            }
            announcedDriveIDs.remove(deviceID)
            return [.driveRejected(name: drive.drive.name, status: status)]

        case RDPDeviceRedirectionPacketID.deviceIORequest:
            serve(try RDPDeviceIORequest.parse(from: pdu))

        default:
            break
        }
        return []
    }

    /// The device list: empty until drives are due, then each drive whose folder exists,
    /// once per Server Announce.
    private func announceDevices(includingDrives: Bool) -> [RDPDeviceRedirectionEvent] {
        var devices: [RDPDeviceAnnounce] = []
        var events: [RDPDeviceRedirectionEvent] = []
        if includingDrives, !hasAnnouncedDrives {
            hasAnnouncedDrives = true
            let available = ioQueue.sync { drives.filter { $0.resolveRoot() } }
            for drive in drives {
                if available.contains(where: { $0 === drive }) {
                    announcedDriveIDs.insert(drive.deviceID)
                    devices.append(.drive(deviceID: drive.deviceID, name: drive.drive.name))
                } else {
                    events.append(.driveUnavailable(name: drive.drive.name))
                }
            }
        }
        send(RDPDeviceRedirectionDeviceListAnnounce(devices: devices).encoded())
        return events
    }

    private func serve(_ request: RDPDeviceIORequest) {
        guard announcedDriveIDs.contains(request.deviceID),
              let drive = drives.first(where: { $0.deviceID == request.deviceID })
        else {
            send(RDPDeviceIOCompletion(
                deviceID: request.deviceID,
                completionID: request.completionID,
                status: RDPNTStatus.unsuccessful,
                body: request.failureReplyBody
            ).encoded())
            return
        }
        ioQueue.async {
            if let completion = drive.completion(for: request) {
                self.replyBudget.write(self.packets(completion.encoded()), to: self.channel)
            }
        }
    }

    /// Waits for the drive I/O queued so far, for tests.
    func waitForDriveIO() {
        ioQueue.sync {}
    }

    private func packets(_ payload: Data) -> [Data] {
        RDPStaticVirtualChannelPDU.encodedTPKTs(
            payload: payload,
            chunkByteCount: chunkSize.byteCount,
            initiator: userChannelID,
            channelID: staticChannelID
        )
    }

    /// Sends one message, chunked; its chunks reach the wire together, as one event
    /// loop task.
    private func send(_ payload: Data) {
        let packets = packets(payload)
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            for packet in packets {
                var buffer = self.channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                self.channel.write(buffer, promise: nil)
            }
            self.channel.flush()
        }
    }
}
