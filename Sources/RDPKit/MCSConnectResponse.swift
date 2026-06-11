import Foundation

public struct RDPStaticVirtualChannelAssignment: Encodable, Equatable, Sendable {
    public var name: String
    public var channelID: UInt16

    public init(name: String, channelID: UInt16) {
        self.name = name
        self.channelID = channelID
    }
}

struct MCSConnectResponse: Equatable, Sendable {
    var result: UInt8
    var calledConnectID: UInt16?
    var serverUserDataKey: String?
    var ioChannelID: UInt16?
    var messageChannelID: UInt16?
    var staticChannelAssignments: [RDPStaticVirtualChannelAssignment]

    var resultName: String {
        result == 0 ? "rt-successful" : "rt-\(result)"
    }

    static func parse(
        fromTPKT packet: Data,
        requestedChannels: [RDPStaticVirtualChannel] = []
    ) throws -> MCSConnectResponse {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let applicationClass = try cursor.readUInt8()
        let applicationType = try cursor.readUInt8()
        guard applicationClass == 0x7F, applicationType == 0x66 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }

        let connectResponseLength = try cursor.readBERLength()
        var mcsCursor = try ByteCursor(cursor.readData(count: connectResponseLength))
        let resultValue = try mcsCursor.readBEREnumerated()
        guard resultValue <= UInt8.max else {
            throw RDPDecodeError.invalidBERLength
        }
        let result = UInt8(resultValue)

        guard mcsCursor.remaining > 0 else {
            return MCSConnectResponse(
                result: result,
                calledConnectID: nil,
                serverUserDataKey: nil,
                ioChannelID: nil,
                messageChannelID: nil,
                staticChannelAssignments: []
            )
        }

        let calledConnectIDValue = try mcsCursor.readBERInteger()
        guard calledConnectIDValue <= UInt16.max else {
            throw RDPDecodeError.invalidBERLength
        }
        let calledConnectID = UInt16(calledConnectIDValue)
        _ = try mcsCursor.readBERSequenceData()
        let userData = try mcsCursor.readBEROctetString()
        let serverData = try parseGCCServerData(userData, requestedChannels: requestedChannels)

        return MCSConnectResponse(
            result: result,
            calledConnectID: calledConnectID,
            serverUserDataKey: serverData.key,
            ioChannelID: serverData.ioChannelID,
            messageChannelID: serverData.messageChannelID,
            staticChannelAssignments: serverData.staticChannelAssignments
        )
    }
}

private struct GCCServerData {
    var key: String?
    var ioChannelID: UInt16?
    var messageChannelID: UInt16?
    var staticChannelAssignments: [RDPStaticVirtualChannelAssignment]
}

private func parseGCCServerData(
    _ data: Data,
    requestedChannels: [RDPStaticVirtualChannel]
) throws -> GCCServerData {
    let serverKey = Data([0x4D, 0x63, 0x44, 0x6E])
    guard let keyRange = data.range(of: serverKey) else {
        return GCCServerData(key: nil, ioChannelID: nil, messageChannelID: nil, staticChannelAssignments: [])
    }

    var cursor = ByteCursor(Data(data[keyRange.upperBound...]))
    let userDataLength = try cursor.readPERLength()
    let serverBlocks = try cursor.readData(count: userDataLength)
    let serverData = try parseServerDataBlocks(from: serverBlocks)

    let assignments = serverData.channelIDs.enumerated().map { index, channelID in
        let name = requestedChannels.indices.contains(index)
            ? requestedChannels[index].name
            : "channel-\(index)"
        return RDPStaticVirtualChannelAssignment(name: name, channelID: channelID)
    }

    return GCCServerData(
        key: "McDn",
        ioChannelID: serverData.ioChannelID,
        messageChannelID: serverData.messageChannelID,
        staticChannelAssignments: assignments
    )
}

private func parseServerDataBlocks(
    from serverBlocks: Data
) throws -> (ioChannelID: UInt16?, channelIDs: [UInt16], messageChannelID: UInt16?) {
    var cursor = ByteCursor(serverBlocks)
    var ioChannelID: UInt16?
    var channelIDs: [UInt16] = []
    var messageChannelID: UInt16?

    while cursor.remaining >= 4 {
        let type = try cursor.readLittleEndianUInt16()
        let length = try cursor.readLittleEndianUInt16()
        guard length >= 4, Int(length) - 4 <= cursor.remaining else {
            throw RDPDecodeError.invalidUserDataBlockLength(length)
        }

        let body = try cursor.readData(count: Int(length) - 4)
        switch type {
        case 0x0C03:
            var bodyCursor = ByteCursor(body)
            ioChannelID = try bodyCursor.readLittleEndianUInt16()
            let channelCount = try Int(bodyCursor.readLittleEndianUInt16())
            channelIDs = []
            for _ in 0 ..< channelCount {
                try channelIDs.append(bodyCursor.readLittleEndianUInt16())
            }
        case 0x0C04:
            var bodyCursor = ByteCursor(body)
            messageChannelID = try bodyCursor.readLittleEndianUInt16()
        default:
            continue
        }
    }

    return (ioChannelID, channelIDs, messageChannelID)
}

private extension ByteCursor {
    mutating func readBERLength() throws -> Int {
        let first = try readUInt8()
        guard first & 0x80 != 0 else {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4 else {
            throw RDPDecodeError.invalidBERLength
        }

        var value = 0
        for _ in 0 ..< byteCount {
            value = try (value << 8) | Int(readUInt8())
        }
        return value
    }

    mutating func readBEREnumerated() throws -> UInt32 {
        try readBERUnsignedValue(expectedTag: 0x0A)
    }

    mutating func readBERInteger() throws -> UInt32 {
        try readBERUnsignedValue(expectedTag: 0x02)
    }

    mutating func readBEROctetString() throws -> Data {
        let tag = try readUInt8()
        guard tag == 0x04 else {
            throw RDPDecodeError.invalidBERTag(expected: 0x04, actual: tag)
        }

        return try readData(count: readBERLength())
    }

    mutating func readBERSequenceData() throws -> Data {
        let tag = try readUInt8()
        guard tag == 0x30 else {
            throw RDPDecodeError.invalidBERTag(expected: 0x30, actual: tag)
        }

        return try readData(count: readBERLength())
    }

    mutating func readBERUnsignedValue(expectedTag: UInt8) throws -> UInt32 {
        let tag = try readUInt8()
        guard tag == expectedTag else {
            throw RDPDecodeError.invalidBERTag(expected: expectedTag, actual: tag)
        }

        let length = try readBERLength()
        guard length > 0, length <= 4 else {
            throw RDPDecodeError.invalidBERLength
        }

        var value: UInt32 = 0
        for _ in 0 ..< length {
            value = try (value << 8) | UInt32(readUInt8())
        }
        return value
    }
}
