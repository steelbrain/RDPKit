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

        return try RDPDynamicVirtualChannelCapabilitiesRequest(
            version: cursor.readLittleEndianUInt16(),
            priorityChargeData: cursor.readRemainingData()
        )
    }
}

struct RDPDynamicVirtualChannelCapabilitiesResponse: Equatable, Sendable {
    var version: UInt16

    init(version: UInt16) {
        precondition((1 ... 3).contains(version))
        self.version = version
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
        guard rawName[rawName.index(after: terminatorIndex)...].allSatisfy({ $0 == 0 }) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        let nameData = rawName[..<terminatorIndex]
        guard let channelName = String(data: Data(nameData), encoding: .ascii),
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

struct RDPDynamicVirtualChannelDataPDU: Equatable, Sendable {
    var channelID: UInt32
    var payload: Data

    init(channelID: UInt32, payload: Data) {
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
        return try RDPDynamicVirtualChannelDataFirstPDU(
            channelID: channelID,
            totalLength: cursor.readDynamicVirtualChannelLength(lengthCode: header.sp),
            payload: cursor.readRemainingData()
        )
    }
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
}
