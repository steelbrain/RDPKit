import Foundation

enum RDPDynamicVirtualChannelCommand: UInt8, Sendable {
    case create = 0x01
    case dataFirst = 0x02
    case data = 0x03
    case close = 0x04
    case capabilities = 0x05
    case dataFirstCompressed = 0x06
    case dataCompressed = 0x07
    case softSyncRequest = 0x08
    case softSyncResponse = 0x09

    var typeName: String {
        switch self {
        case .create:
            "dynvc-create"
        case .dataFirst:
            "dynvc-data-first"
        case .data:
            "dynvc-data"
        case .close:
            "dynvc-close"
        case .capabilities:
            "dynvc-capabilities"
        case .dataFirstCompressed:
            "dynvc-data-first-compressed"
        case .dataCompressed:
            "dynvc-data-compressed"
        case .softSyncRequest:
            "dynvc-soft-sync-request"
        case .softSyncResponse:
            "dynvc-soft-sync-response"
        }
    }
}

struct RDPDynamicVirtualChannelHeader: Equatable, Sendable {
    var channelIDLength: UInt8
    var sp: UInt8
    var command: RDPDynamicVirtualChannelCommand

    init(channelIDLength: UInt8 = 0, sp: UInt8 = 0, command: RDPDynamicVirtualChannelCommand) {
        precondition(channelIDLength < 3)
        precondition(sp < 4)

        self.channelIDLength = channelIDLength
        self.sp = sp
        self.command = command
    }

    init(byte: UInt8) throws {
        let commandValue = byte >> 4
        guard let command = RDPDynamicVirtualChannelCommand(rawValue: commandValue) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let channelIDLength = byte & 0x03
        guard channelIDLength < 3 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        self.channelIDLength = channelIDLength
        sp = (byte >> 2) & 0x03
        self.command = command
    }

    var encodedByte: UInt8 {
        (command.rawValue << 4) | (sp << 2) | channelIDLength
    }
}

struct RDPDynamicVirtualChannelCapabilitiesRequest: Equatable, Sendable {
    var version: UInt16
    var priorityChargeData: Data

    var typeName: String {
        "dynvc-capabilities-request"
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelCapabilitiesRequest? {
        guard data.count >= 4 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .capabilities else {
            return nil
        }
        guard header.channelIDLength == 0 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let pad = try cursor.readUInt8()
        guard pad == 0 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let version = try cursor.readLittleEndianUInt16()
        let priorityChargeData = cursor.readRemainingData()
        switch version {
        case 1:
            guard priorityChargeData.isEmpty else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
        case 2, 3:
            guard priorityChargeData.count == 8 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
        default:
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return RDPDynamicVirtualChannelCapabilitiesRequest(
            version: version,
            priorityChargeData: priorityChargeData
        )
    }
}

struct RDPDynamicVirtualChannelCapabilitiesResponse: Equatable, Sendable {
    static let maximumSupportedVersion: UInt16 = 3

    var version: UInt16

    init(version: UInt16) {
        precondition((1 ... 3).contains(version))
        self.version = version
    }

    init(requestedVersion: UInt16) {
        self.init(version: max(1, min(requestedVersion, Self.maximumSupportedVersion)))
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(command: .capabilities).encodedByte)
        data.appendUInt8(0)
        data.appendLittleEndianUInt16(version)
        return data
    }
}

struct RDPDynamicVirtualChannelCreateRequest: Equatable, Sendable {
    var channelID: UInt32
    var priority: UInt8
    var channelName: String

    var typeName: String {
        "dynvc-create-request"
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelCreateRequest? {
        guard data.count >= 3 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .create else {
            return nil
        }

        let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
        let rawName = cursor.readRemainingData()
        guard let terminatorIndex = rawName.firstIndex(of: 0) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        guard rawName.index(after: terminatorIndex) == rawName.endIndex else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        let nameData = rawName[..<terminatorIndex]
        guard let channelName = String(data: Data(nameData), encoding: .windowsCP1252),
              !channelName.isEmpty
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return RDPDynamicVirtualChannelCreateRequest(
            channelID: channelID,
            priority: header.sp,
            channelName: channelName
        )
    }
}

struct RDPDynamicVirtualChannelCreateResponse: Equatable, Sendable {
    var channelID: UInt32
    var creationStatus: Int32

    init(channelID: UInt32, creationStatus: Int32 = 0) {
        self.channelID = channelID
        self.creationStatus = creationStatus
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            command: .create
        ).encodedByte)
        data.appendDynamicVirtualChannelID(channelID)
        data.appendLittleEndianUInt32(UInt32(bitPattern: creationStatus))
        return data
    }
}

struct RDPDynamicVirtualChannelClosePDU: Equatable, Sendable {
    var channelID: UInt32

    var typeName: String {
        "dynvc-close"
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            command: .close
        ).encodedByte)
        data.appendDynamicVirtualChannelID(channelID)
        return data
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelClosePDU? {
        guard data.count >= 2 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .close else {
            return nil
        }

        let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return RDPDynamicVirtualChannelClosePDU(channelID: channelID)
    }
}

enum RDPWindowsAuxiliaryDynamicChannel {
    static let inputName = RDPInputDynamicChannel.name
    static let coreInputName = RDPCoreInputChannel.name
    static let mouseCursorName = RDPMouseCursorChannel.name
    static let audioInputName = RDPAudioInputDynamicChannel.name

    static let acceptedNames: Set<String> = [
        inputName,
        coreInputName,
        mouseCursorName,
        audioInputName,
    ]

    static func isAcceptedNoOp(_ channelName: String) -> Bool {
        acceptedNames.contains(channelName)
    }
}

enum RDPInputDynamicChannel {
    static let name = "Microsoft::Windows::RDS::Input"
}

enum RDPInputProtocolVersion: UInt32, Sendable {
    case version100 = 0x0001_0000
    case version101 = 0x0001_0001
    case version200 = 0x0002_0000
    case version300 = 0x0003_0000
}

enum RDPInputEventID {
    static let serverReady: UInt16 = 0x0001
    static let clientReady: UInt16 = 0x0002
    static let suspendInput: UInt16 = 0x0004
    static let resumeInput: UInt16 = 0x0005
}

enum RDPInputClientReadyFlags {
    static let showTouchVisuals: UInt32 = 0x0000_0001
    static let disableTimestampInjection: UInt32 = 0x0000_0002
    static let enableMultipenInjection: UInt32 = 0x0000_0004
}

enum RDPInputServerReadyFeatures {
    static let multipenInjectionSupported: UInt32 = 0x0000_0001
    static let supportedMask: UInt32 = multipenInjectionSupported
}

struct RDPInputServerReadyPDU: Equatable, Sendable {
    var protocolVersion: RDPInputProtocolVersion
    var supportedFeatures: UInt32?

    static func parseIfPresent(from data: Data) throws -> RDPInputServerReadyPDU? {
        guard data.count >= 6 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let eventID = try cursor.readLittleEndianUInt16()
        guard eventID == RDPInputEventID.serverReady else {
            return nil
        }

        let pduLength = try cursor.readLittleEndianUInt32()
        guard pduLength == UInt32(data.count) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        guard data.count == 10 || data.count == 14 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let protocolVersionValue = try cursor.readLittleEndianUInt32()
        guard let protocolVersion = RDPInputProtocolVersion(rawValue: protocolVersionValue) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        let supportedFeatures: UInt32?
        if data.count == 14 {
            guard protocolVersion == .version300 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            let featureFlags = try cursor.readLittleEndianUInt32()
            guard featureFlags & ~RDPInputServerReadyFeatures.supportedMask == 0 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            supportedFeatures = featureFlags
        } else {
            supportedFeatures = nil
        }

        return RDPInputServerReadyPDU(
            protocolVersion: protocolVersion,
            supportedFeatures: supportedFeatures
        )
    }
}

struct RDPInputSuspendPDU: Equatable, Sendable {
    static func parseIfPresent(from data: Data) throws -> RDPInputSuspendPDU? {
        guard try parseHeaderOnlyInputPDU(data, eventID: RDPInputEventID.suspendInput) != nil else {
            return nil
        }
        return RDPInputSuspendPDU()
    }
}

struct RDPInputResumePDU: Equatable, Sendable {
    static func parseIfPresent(from data: Data) throws -> RDPInputResumePDU? {
        guard try parseHeaderOnlyInputPDU(data, eventID: RDPInputEventID.resumeInput) != nil else {
            return nil
        }
        return RDPInputResumePDU()
    }
}

struct RDPInputClientReadyPDU: Equatable, Sendable {
    var flags: UInt32
    var protocolVersion: RDPInputProtocolVersion
    var maxTouchContacts: UInt16

    init(
        flags: UInt32 = 0,
        protocolVersion: RDPInputProtocolVersion = .version100,
        maxTouchContacts: UInt16 = 0
    ) {
        self.flags = flags
        self.protocolVersion = protocolVersion
        self.maxTouchContacts = maxTouchContacts
    }

    init(serverReady: RDPInputServerReadyPDU, maxTouchContacts: UInt16 = 0) {
        self.init(
            protocolVersion: RDPInputClientReadyPDU.clientProtocolVersion(for: serverReady.protocolVersion),
            maxTouchContacts: maxTouchContacts
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPInputEventID.clientReady)
        data.appendLittleEndianUInt32(16)
        data.appendLittleEndianUInt32(flags)
        data.appendLittleEndianUInt32(protocolVersion.rawValue)
        data.appendLittleEndianUInt16(maxTouchContacts)
        return data
    }

    private static func clientProtocolVersion(for serverVersion: RDPInputProtocolVersion) -> RDPInputProtocolVersion {
        switch serverVersion {
        case .version100:
            .version100
        case .version101:
            .version101
        case .version200:
            .version200
        case .version300:
            .version300
        }
    }
}

private func parseHeaderOnlyInputPDU(_ data: Data, eventID expectedEventID: UInt16) throws -> Void? {
    guard data.count >= 6 else {
        return nil
    }

    var cursor = ByteCursor(data)
    let eventID = try cursor.readLittleEndianUInt16()
    guard eventID == expectedEventID else {
        return nil
    }
    let pduLength = try cursor.readLittleEndianUInt32()
    guard pduLength == UInt32(data.count),
          data.count == 6
    else {
        throw RDPDecodeError.invalidDynamicVirtualChannelPDU
    }
    return ()
}

enum RDPCoreInputChannel {
    static let name = "Microsoft::Windows::RDS::CoreInput"
}

struct RDPCoreInputInitRequestPDU: Equatable, Sendable {
    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(0x03)
        data.appendUInt8(0x01)
        data.appendUInt8(0)
        data.appendUInt8(0)
        data.appendLittleEndianUInt16(0x0100)
        data.appendLittleEndianUInt16(0x0100)
        data.appendLittleEndianUInt64(0)
        return data
    }
}

enum RDPMouseCursorChannel {
    static let name = "Microsoft::Windows::RDS::MouseCursor"
}

struct RDPMouseCursorCapsAdvertisePDU: Equatable, Sendable {
    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(0x01)
        data.appendUInt8(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(0x5350_4143)
        data.appendLittleEndianUInt32(1)
        data.appendLittleEndianUInt32(12)
        return data
    }
}

struct RDPDynamicVirtualChannelDataPDU: Equatable, Sendable {
    static let maximumPacketByteCount = 1_600

    var channelID: UInt32
    var payload: Data

    init(channelID: UInt32, payload: Data) {
        precondition(payload.count <= Self.maximumPayloadByteCount(channelID: channelID))
        self.channelID = channelID
        self.payload = payload
    }

    var typeName: String {
        "dynvc-data"
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            command: .data
        ).encodedByte)
        data.appendDynamicVirtualChannelID(channelID)
        data.append(payload)
        return data
    }

    static func maximumPayloadByteCount(channelID: UInt32) -> Int {
        maximumPacketByteCount
            - 1
            - Int(dynamicVirtualChannelFieldByteCount(lengthCode: dynamicVirtualChannelIDLengthCode(channelID)))
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelDataPDU? {
        guard data.count >= 2 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .data else {
            return nil
        }

        return try RDPDynamicVirtualChannelDataPDU(
            channelID: cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength),
            payload: cursor.readRemainingData()
        )
    }
}

struct RDPDynamicVirtualChannelDataPacketizer: Equatable, Sendable {
    var channelID: UInt32
    var payload: Data

    func encodedPDUs() -> [Data] {
        precondition(payload.count <= Int(UInt32.max))

        let singlePayloadLimit = RDPDynamicVirtualChannelDataPDU.maximumPayloadByteCount(channelID: channelID)
        guard payload.count > singlePayloadLimit else {
            return [RDPDynamicVirtualChannelDataPDU(channelID: channelID, payload: payload).encoded()]
        }

        let channelIDLengthCode = dynamicVirtualChannelIDLengthCode(channelID)
        let lengthCode = dynamicVirtualChannelLengthCode(UInt32(payload.count))
        let firstPayloadLength = Int(dynamicVirtualChannelDataFirstPayloadLength(
            channelIDLengthCode: channelIDLengthCode,
            lengthCode: lengthCode,
            totalLength: UInt32(payload.count)
        ))
        precondition(firstPayloadLength > 0)

        var pdus: [Data] = []
        pdus.append(encodedDataFirstPDU(
            totalLength: UInt32(payload.count),
            lengthCode: lengthCode,
            payload: payload.prefix(firstPayloadLength)
        ))

        var offset = firstPayloadLength
        while offset < payload.count {
            let endIndex = min(offset + singlePayloadLimit, payload.count)
            pdus.append(RDPDynamicVirtualChannelDataPDU(
                channelID: channelID,
                payload: payload.subdata(in: offset ..< endIndex)
            ).encoded())
            offset = endIndex
        }
        return pdus
    }

    private func encodedDataFirstPDU(totalLength: UInt32, lengthCode: UInt8, payload: Data) -> Data {
        var data = Data()
        data.appendUInt8(RDPDynamicVirtualChannelHeader(
            channelIDLength: dynamicVirtualChannelIDLengthCode(channelID),
            sp: lengthCode,
            command: .dataFirst
        ).encodedByte)
        data.appendDynamicVirtualChannelID(channelID)
        data.appendDynamicVirtualChannelLength(totalLength, lengthCode: lengthCode)
        data.append(payload)
        return data
    }
}

struct RDPDynamicVirtualChannelDataFirstPDU: Equatable, Sendable {
    var channelID: UInt32
    var totalLength: UInt32
    var payload: Data

    init(channelID: UInt32, totalLength: UInt32, payload: Data) {
        self.channelID = channelID
        self.totalLength = totalLength
        self.payload = payload
    }

    var typeName: String {
        "dynvc-data-first"
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelDataFirstPDU? {
        guard data.count >= 3 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .dataFirst else {
            return nil
        }

        let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
        let totalLength = try cursor.readDynamicVirtualChannelLength(lengthCode: header.sp)
        let payload = cursor.readRemainingData()
        guard UInt32(payload.count) == dynamicVirtualChannelDataFirstPayloadLength(
            channelIDLengthCode: header.channelIDLength,
            lengthCode: header.sp,
            totalLength: totalLength
        ) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        return RDPDynamicVirtualChannelDataFirstPDU(
            channelID: channelID,
            totalLength: totalLength,
            payload: payload
        )
    }
}

struct RDPDynamicVirtualChannelCompressedDataPDU: Equatable, Sendable {
    private static let minimumSegmentedDataByteCount = 2

    var command: RDPDynamicVirtualChannelCommand
    var channelID: UInt32
    var totalLength: UInt32?
    var compressedPayload: Data

    var typeName: String {
        command.typeName
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelCompressedDataPDU? {
        guard data.count >= 2 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        switch header.command {
        case .dataFirstCompressed:
            let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
            let totalLength = try cursor.readDynamicVirtualChannelLength(lengthCode: header.sp)
            let compressedPayload = cursor.readRemainingData()
            try validateCompressedPayload(
                compressedPayload,
                headerByteCount: 1
                    + Int(dynamicVirtualChannelFieldByteCount(lengthCode: header.channelIDLength))
                    + Int(dynamicVirtualChannelFieldByteCount(lengthCode: header.sp))
            )
            return RDPDynamicVirtualChannelCompressedDataPDU(
                command: header.command,
                channelID: channelID,
                totalLength: totalLength,
                compressedPayload: compressedPayload
            )
        case .dataCompressed:
            let channelID = try cursor.readDynamicVirtualChannelID(lengthCode: header.channelIDLength)
            let compressedPayload = cursor.readRemainingData()
            try validateCompressedPayload(
                compressedPayload,
                headerByteCount: 1
                    + Int(dynamicVirtualChannelFieldByteCount(lengthCode: header.channelIDLength))
            )
            return RDPDynamicVirtualChannelCompressedDataPDU(
                command: header.command,
                channelID: channelID,
                totalLength: nil,
                compressedPayload: compressedPayload
            )
        default:
            return nil
        }
    }

    private static func validateCompressedPayload(_ payload: Data, headerByteCount: Int) throws {
        guard payload.count >= minimumSegmentedDataByteCount,
              headerByteCount + payload.count <= RDPDynamicVirtualChannelDataPDU.maximumPacketByteCount
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
    }
}

struct RDPDynamicVirtualChannelSoftSyncChannelList: Equatable, Sendable {
    var tunnelType: UInt32
    var channelIDs: [UInt32]
}

private enum RDPDynamicVirtualChannelSoftSync {
    static let tcpFlushedFlag: UInt16 = 0x0001
    static let channelListPresentFlag: UInt16 = 0x0002
    static let supportedFlags: UInt16 = tcpFlushedFlag | channelListPresentFlag
    static let udpReliableTunnel: UInt32 = 0x0000_0001
    static let udpLossyTunnel: UInt32 = 0x0000_0003

    static func isSupportedTunnelType(_ tunnelType: UInt32) -> Bool {
        tunnelType == udpReliableTunnel || tunnelType == udpLossyTunnel
    }
}

struct RDPDynamicVirtualChannelSoftSyncPDU: Equatable, Sendable {
    var command: RDPDynamicVirtualChannelCommand
    var flags: UInt16?
    var channelLists: [RDPDynamicVirtualChannelSoftSyncChannelList]
    var tunnelsToSwitch: [UInt32]

    var typeName: String {
        command.typeName
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelSoftSyncPDU? {
        guard data.count >= 2 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .softSyncRequest || header.command == .softSyncResponse else {
            return nil
        }
        guard header.channelIDLength == 0, header.sp == 0 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        guard try cursor.readUInt8() == 0 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }

        switch header.command {
        case .softSyncRequest:
            let length = try cursor.readLittleEndianUInt32()
            guard length >= 8,
                  Int(length) == data.count - 2
            else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            let flags = try cursor.readLittleEndianUInt16()
            guard flags & RDPDynamicVirtualChannelSoftSync.tcpFlushedFlag != 0,
                  flags & ~RDPDynamicVirtualChannelSoftSync.supportedFlags == 0
            else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            let tunnelCount = try Int(cursor.readLittleEndianUInt16())
            let channelLists: [RDPDynamicVirtualChannelSoftSyncChannelList]
            if flags & RDPDynamicVirtualChannelSoftSync.channelListPresentFlag != 0 {
                guard tunnelCount > 0 else {
                    throw RDPDecodeError.invalidDynamicVirtualChannelPDU
                }
                channelLists = try parseSoftSyncChannelLists(from: &cursor, count: tunnelCount)
            } else {
                guard tunnelCount == 0 else {
                    throw RDPDecodeError.invalidDynamicVirtualChannelPDU
                }
                channelLists = []
            }
            guard cursor.remaining == 0 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            return RDPDynamicVirtualChannelSoftSyncPDU(
                command: header.command,
                flags: flags,
                channelLists: channelLists,
                tunnelsToSwitch: []
            )
        case .softSyncResponse:
            let tunnelCount = try Int(cursor.readLittleEndianUInt32())
            guard cursor.remaining == tunnelCount * 4 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            var tunnelsToSwitch: [UInt32] = []
            tunnelsToSwitch.reserveCapacity(tunnelCount)
            for _ in 0 ..< tunnelCount {
                let tunnelType = try cursor.readLittleEndianUInt32()
                guard RDPDynamicVirtualChannelSoftSync.isSupportedTunnelType(tunnelType) else {
                    throw RDPDecodeError.invalidDynamicVirtualChannelPDU
                }
                tunnelsToSwitch.append(tunnelType)
            }
            return RDPDynamicVirtualChannelSoftSyncPDU(
                command: header.command,
                flags: nil,
                channelLists: [],
                tunnelsToSwitch: tunnelsToSwitch
            )
        default:
            break
        }

        throw RDPDecodeError.invalidDynamicVirtualChannelPDU
    }
}

private func parseSoftSyncChannelLists(
    from cursor: inout ByteCursor,
    count: Int
) throws -> [RDPDynamicVirtualChannelSoftSyncChannelList] {
    var channelLists: [RDPDynamicVirtualChannelSoftSyncChannelList] = []
    channelLists.reserveCapacity(count)
    var seenTunnelTypes = Set<UInt32>()
    var seenChannelIDs = Set<UInt32>()
    for _ in 0 ..< count {
        guard cursor.remaining >= 6 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        let tunnelType = try cursor.readLittleEndianUInt32()
        guard RDPDynamicVirtualChannelSoftSync.isSupportedTunnelType(tunnelType),
              seenTunnelTypes.insert(tunnelType).inserted
        else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        let channelCount = try Int(cursor.readLittleEndianUInt16())
        guard cursor.remaining >= channelCount * 4 else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        var channelIDs: [UInt32] = []
        channelIDs.reserveCapacity(channelCount)
        for _ in 0 ..< channelCount {
            let channelID = try cursor.readLittleEndianUInt32()
            guard seenChannelIDs.insert(channelID).inserted else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            channelIDs.append(channelID)
        }
        channelLists.append(RDPDynamicVirtualChannelSoftSyncChannelList(
            tunnelType: tunnelType,
            channelIDs: channelIDs
        ))
    }
    return channelLists
}

func dynamicVirtualChannelIDLengthCode(_ channelID: UInt32) -> UInt8 {
    if channelID <= UInt8.max {
        return 0
    }
    if channelID <= UInt16.max {
        return 1
    }
    return 2
}

func dynamicVirtualChannelLengthCode(_ length: UInt32) -> UInt8 {
    if length <= UInt8.max {
        return 0
    }
    if length <= UInt16.max {
        return 1
    }
    return 2
}

func dynamicVirtualChannelFieldByteCount(lengthCode: UInt8) -> UInt32 {
    switch lengthCode {
    case 0:
        return 1
    case 1:
        return 2
    case 2:
        return 4
    default:
        preconditionFailure("invalid dynamic virtual channel length code")
    }
}

func dynamicVirtualChannelDataFirstPayloadLength(
    channelIDLengthCode: UInt8,
    lengthCode: UInt8,
    totalLength: UInt32
) -> UInt32 {
    let headerLength = 1
        + dynamicVirtualChannelFieldByteCount(lengthCode: channelIDLengthCode)
        + dynamicVirtualChannelFieldByteCount(lengthCode: lengthCode)
    return min(totalLength, 1_600 - headerLength)
}

extension ByteCursor {
    mutating func readDynamicVirtualChannelID(lengthCode: UInt8) throws -> UInt32 {
        switch lengthCode {
        case 0:
            return try UInt32(readUInt8())
        case 1:
            return try UInt32(readLittleEndianUInt16())
        case 2:
            return try readLittleEndianUInt32()
        default:
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
    }

    mutating func readDynamicVirtualChannelLength(lengthCode: UInt8) throws -> UInt32 {
        switch lengthCode {
        case 0:
            return try UInt32(readUInt8())
        case 1:
            return try UInt32(readLittleEndianUInt16())
        case 2:
            return try readLittleEndianUInt32()
        default:
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
    }
}

extension Data {
    mutating func appendDynamicVirtualChannelID(_ channelID: UInt32) {
        switch dynamicVirtualChannelIDLengthCode(channelID) {
        case 0:
            appendUInt8(UInt8(channelID))
        case 1:
            appendLittleEndianUInt16(UInt16(channelID))
        default:
            appendLittleEndianUInt32(channelID)
        }
    }

    mutating func appendDynamicVirtualChannelLength(_ length: UInt32, lengthCode: UInt8) {
        switch lengthCode {
        case 0:
            appendUInt8(UInt8(length))
        case 1:
            appendLittleEndianUInt16(UInt16(length))
        case 2:
            appendLittleEndianUInt32(length)
        default:
            preconditionFailure("invalid dynamic virtual channel length code")
        }
    }
}
