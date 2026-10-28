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

    /// The Cmd field of a DVC PDU, or nil when the PDU is empty or the command
    /// is unknown, so callers can skip PDUs they do not understand.
    static func command(of pdu: Data) -> RDPDynamicVirtualChannelCommand? {
        pdu.first.flatMap { RDPDynamicVirtualChannelCommand(rawValue: $0 >> 4) }
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

struct RDPDynamicVirtualChannelDataPDU: Equatable, Sendable {
    /// Largest DVC PDU on the wire ([MS-RDPEDYC] 2.2.3). Decompressed payloads
    /// can be larger ([MS-RDPEDYC] 2.2.3.4), so the initializer does not cap them.
    static let maximumPacketByteCount = 1_600

    var channelID: UInt32
    var payload: Data

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
        guard data.count <= maximumPacketByteCount else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
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

        var pdus = [encodedDataFirstPDU(
            totalLength: UInt32(payload.count),
            lengthCode: lengthCode,
            payload: payload.prefix(firstPayloadLength)
        )]
        var start = payload.index(payload.startIndex, offsetBy: firstPayloadLength)
        while start < payload.endIndex {
            let end = payload.index(start, offsetBy: singlePayloadLimit, limitedBy: payload.endIndex)
                ?? payload.endIndex
            pdus.append(RDPDynamicVirtualChannelDataPDU(
                channelID: channelID,
                payload: payload.subdata(in: start ..< end)
            ).encoded())
            start = end
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

/// DYNVC_SOFT_SYNC_REQUEST ([MS-RDPEDYC] 2.2.5.1). Soft-Sync only switches
/// channels onto multitransport tunnels, which this client never creates, so
/// the request is recognized and otherwise ignored.
struct RDPDynamicVirtualChannelSoftSyncPDU: Equatable, Sendable {
    var typeName: String {
        RDPDynamicVirtualChannelCommand.softSyncRequest.typeName
    }

    static func parseIfPresent(from data: Data) throws -> RDPDynamicVirtualChannelSoftSyncPDU? {
        guard data.count >= 2 else {
            return nil
        }

        var cursor = ByteCursor(data)
        let header = try RDPDynamicVirtualChannelHeader(byte: cursor.readUInt8())
        guard header.command == .softSyncRequest else {
            return nil
        }
        _ = try cursor.readUInt8()
        guard try cursor.readLittleEndianUInt32() == UInt32(data.count - 2) else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        return RDPDynamicVirtualChannelSoftSyncPDU()
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
    return min(totalLength, UInt32(RDPDynamicVirtualChannelDataPDU.maximumPacketByteCount) - headerLength)
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
