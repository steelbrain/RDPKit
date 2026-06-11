import Foundation

struct RDPStaticVirtualChannel: Equatable, Sendable {
    var name: String
    var options: UInt32

    init(name: String, options: UInt32) {
        precondition(!name.isEmpty)
        precondition(name.utf8.count <= 7)
        precondition(name.utf8.allSatisfy { $0 < 0x80 })

        self.name = name
        self.options = options
    }

    static let drdynvc = RDPStaticVirtualChannel(
        name: "drdynvc",
        options: ChannelOptions.initialized
            | ChannelOptions.encryptRDP
            | ChannelOptions.compressRDP
    )

    static let cliprdr = RDPStaticVirtualChannel(
        name: "cliprdr",
        options: ChannelOptions.initialized
            | ChannelOptions.encryptRDP
            | ChannelOptions.compressRDP
    )

    static let rdpsnd = RDPStaticVirtualChannel(
        name: "rdpsnd",
        options: ChannelOptions.initialized
            | ChannelOptions.encryptRDP
            | ChannelOptions.compressRDP
    )
}

enum ChannelOptions {
    static let initialized: UInt32 = 0x8000_0000
    static let encryptRDP: UInt32 = 0x4000_0000
    static let encryptServerToClient: UInt32 = 0x2000_0000
    static let encryptClientToServer: UInt32 = 0x1000_0000
    static let highPriority: UInt32 = 0x0800_0000
    static let mediumPriority: UInt32 = 0x0400_0000
    static let lowPriority: UInt32 = 0x0200_0000
    static let compressRDP: UInt32 = 0x0080_0000
    static let compress: UInt32 = 0x0040_0000
    static let showProtocol: UInt32 = 0x0020_0000
    static let remoteControlPersistent: UInt32 = 0x0010_0000
}

struct MCSConnectInitialConfiguration: Equatable, Sendable {
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var clientName: String
    var selectedProtocol: RDPSecurityProtocols
    var channels: [RDPStaticVirtualChannel]
    var advertiseMessageChannel: Bool

    init(
        desktopWidth: UInt16 = 1280,
        desktopHeight: UInt16 = 720,
        clientName: String = "KRDPSWIFT",
        selectedProtocol: RDPSecurityProtocols = .tls,
        channels: [RDPStaticVirtualChannel] = [.drdynvc],
        advertiseMessageChannel: Bool = false
    ) {
        precondition(!channels.isEmpty)
        precondition(channels.count <= 31)

        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.clientName = clientName
        self.selectedProtocol = selectedProtocol
        self.channels = channels
        self.advertiseMessageChannel = advertiseMessageChannel
    }
}

struct MCSConnectInitialPDU: Equatable, Sendable {
    var configuration: MCSConnectInitialConfiguration

    init(configuration: MCSConnectInitialConfiguration = MCSConnectInitialConfiguration()) {
        self.configuration = configuration
    }

    func encodedTPKT() -> Data {
        X224DataTPDU.wrap(encodedMCSConnectInitial())
    }

    func encodedMCSConnectInitial() -> Data {
        var fields = Data()
        fields.append(berOctetString(Data([0x01])))
        fields.append(berOctetString(Data([0x01])))
        fields.append(berBoolean(true))
        fields.append(berDomainParameters(.target))
        fields.append(berDomainParameters(.minimum))
        fields.append(berDomainParameters(.maximum))
        fields.append(berOctetString(encodedGCCConnectData()))

        var data = Data()
        data.appendUInt8(0x7F)
        data.appendUInt8(0x65)
        data.appendBERLength(fields.count)
        data.append(fields)
        return data
    }

    func encodedGCCConnectData() -> Data {
        let request = encodedGCCConferenceCreateRequest()

        var data = Data()
        data.append(contentsOf: [
            0x00, 0x05,
            0x00, 0x14, 0x7C, 0x00, 0x01,
        ])
        data.appendPERLength(request.count)
        data.append(request)
        return data
    }

    func encodedGCCConferenceCreateRequest() -> Data {
        let userData = encodedClientDataBlocks()

        var data = Data()
        data.append(contentsOf: [
            0x00, 0x08, 0x00, 0x10,
            0x00, 0x01, 0xC0, 0x00,
        ])
        data.append(contentsOf: [0x44, 0x75, 0x63, 0x61])
        data.appendPERLength(userData.count)
        data.append(userData)
        return data
    }

    func encodedClientDataBlocks() -> Data {
        var data = Data()
        data.append(encodedClientCoreData())
        data.append(encodedClientClusterData())
        data.append(encodedClientSecurityData())
        data.append(encodedClientNetworkData())
        if configuration.advertiseMessageChannel {
            data.append(encodedClientMessageChannelData())
        }
        return data
    }

    func encodedClientCoreData() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0x0008_0005)
        body.appendLittleEndianUInt16(configuration.desktopWidth)
        body.appendLittleEndianUInt16(configuration.desktopHeight)
        body.appendLittleEndianUInt16(0xCA01)
        body.appendLittleEndianUInt16(0xAA03)
        body.appendLittleEndianUInt32(0x0000_0409)
        body.appendLittleEndianUInt32(3790)
        body.append(fixedUTF16LE(configuration.clientName, codeUnitCount: 16))
        body.appendLittleEndianUInt32(4)
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt32(12)
        body.append(Data(repeating: 0, count: 64))
        body.appendLittleEndianUInt16(0xCA04)
        body.appendLittleEndianUInt16(1)
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt16(24)
        body.appendLittleEndianUInt16(0x000F)
        body.appendLittleEndianUInt16(0x01AF)
        body.append(fixedUTF16LE("00000-000-0000000-00000", codeUnitCount: 32))
        body.appendUInt8(0x06)
        body.appendUInt8(0x00)
        body.appendLittleEndianUInt32(configuration.selectedProtocol.rawValue)

        precondition(body.count == 212)
        return userDataBlock(type: 0xC001, body: body)
    }

    func encodedClientClusterData() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0x0000_000D)
        body.appendLittleEndianUInt32(0)
        return userDataBlock(type: 0xC004, body: body)
    }

    func encodedClientSecurityData() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0x0000_001B)
        body.appendLittleEndianUInt32(0)
        return userDataBlock(type: 0xC002, body: body)
    }

    func encodedClientNetworkData() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(UInt32(configuration.channels.count))
        for channel in configuration.channels {
            body.append(fixedASCII(channel.name, byteCount: 8))
            body.appendLittleEndianUInt32(channel.options)
        }
        return userDataBlock(type: 0xC003, body: body)
    }

    func encodedClientMessageChannelData() -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0)
        return userDataBlock(type: 0xC006, body: body)
    }

    private func userDataBlock(type: UInt16, body: Data) -> Data {
        precondition(body.count + 4 <= Int(UInt16.max))

        var data = Data()
        data.appendLittleEndianUInt16(type)
        data.appendLittleEndianUInt16(UInt16(body.count + 4))
        data.append(body)
        return data
    }
}

private struct MCSDomainParameters {
    var maxChannelIds: UInt16
    var maxUserIds: UInt16
    var maxTokenIds: UInt16
    var numPriorities: UInt16
    var minThroughput: UInt16
    var maxHeight: UInt16
    var maxMCSPDUSize: UInt16
    var protocolVersion: UInt16

    static let target = MCSDomainParameters(
        maxChannelIds: 34,
        maxUserIds: 2,
        maxTokenIds: 0,
        numPriorities: 1,
        minThroughput: 0,
        maxHeight: 1,
        maxMCSPDUSize: UInt16.max,
        protocolVersion: 2
    )

    static let minimum = MCSDomainParameters(
        maxChannelIds: 1,
        maxUserIds: 1,
        maxTokenIds: 1,
        numPriorities: 1,
        minThroughput: 0,
        maxHeight: 1,
        maxMCSPDUSize: 1056,
        protocolVersion: 2
    )

    static let maximum = MCSDomainParameters(
        maxChannelIds: UInt16.max,
        maxUserIds: UInt16.max,
        maxTokenIds: UInt16.max,
        numPriorities: 1,
        minThroughput: 0,
        maxHeight: 1,
        maxMCSPDUSize: UInt16.max,
        protocolVersion: 2
    )
}

private func berDomainParameters(_ parameters: MCSDomainParameters) -> Data {
    var body = Data()
    body.appendBERInteger(parameters.maxChannelIds)
    body.appendBERInteger(parameters.maxUserIds)
    body.appendBERInteger(parameters.maxTokenIds)
    body.appendBERInteger(parameters.numPriorities)
    body.appendBERInteger(parameters.minThroughput)
    body.appendBERInteger(parameters.maxHeight)
    body.appendBERInteger(parameters.maxMCSPDUSize)
    body.appendBERInteger(parameters.protocolVersion)

    var data = Data()
    data.appendUInt8(0x30)
    data.appendBERLength(body.count)
    data.append(body)
    return data
}

private func berOctetString(_ value: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x04)
    data.appendBERLength(value.count)
    data.append(value)
    return data
}

private func berBoolean(_ value: Bool) -> Data {
    Data([0x01, 0x01, value ? 0xFF : 0x00])
}

private func fixedASCII(_ string: String, byteCount: Int) -> Data {
    let bytes = Array(string.utf8)
    precondition(bytes.count <= byteCount)
    precondition(bytes.allSatisfy { $0 < 0x80 })

    var data = Data(bytes)
    while data.count < byteCount {
        data.appendUInt8(0)
    }
    return data
}

private func fixedUTF16LE(_ string: String, codeUnitCount: Int) -> Data {
    precondition(codeUnitCount > 0)

    var data = Data()
    for codeUnit in string.utf16.prefix(codeUnitCount - 1) {
        data.appendLittleEndianUInt16(codeUnit)
    }
    while data.count < codeUnitCount * 2 {
        data.appendUInt8(0)
    }
    return data
}

private extension Data {
    mutating func appendBERLength(_ length: Int) {
        precondition(length >= 0)

        if length < 0x80 {
            appendUInt8(UInt8(length))
            return
        }

        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }

        appendUInt8(0x80 | UInt8(bytes.count))
        append(contentsOf: bytes)
    }

    mutating func appendBERInteger(_ value: UInt16) {
        var bytes: [UInt8]
        if value <= 0xFF {
            bytes = [UInt8(value & 0xFF)]
        } else {
            bytes = [
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ]
        }

        appendUInt8(0x02)
        appendUInt8(UInt8(bytes.count))
        append(contentsOf: bytes)
    }
}
