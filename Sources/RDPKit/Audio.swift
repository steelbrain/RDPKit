import Foundation
@preconcurrency import NIOCore

enum RDPAudioChannel {
    static let name = "rdpsnd"
}

enum RDPAudioDynamicChannel {
    static let name = "AUDIO_PLAYBACK_DVC"
}

enum RDPAudioInputDynamicChannel {
    static let name = "AUDIO_INPUT"
}

enum RDPAudioInputMessageType {
    static let version: UInt8 = 0x01
    static let formats: UInt8 = 0x02
    static let open: UInt8 = 0x03
    static let openReply: UInt8 = 0x04
    static let dataIncoming: UInt8 = 0x05
    static let data: UInt8 = 0x06
    static let formatChange: UInt8 = 0x07
}

enum RDPAudioMessageType {
    static let close: UInt8 = 0x01
    static let waveInfo: UInt8 = 0x02
    static let volume: UInt8 = 0x03
    static let pitch: UInt8 = 0x04
    static let waveConfirm: UInt8 = 0x05
    static let training: UInt8 = 0x06
    static let formats: UInt8 = 0x07
    static let cryptKey: UInt8 = 0x08
    static let waveEncrypt: UInt8 = 0x09
    static let udpWave: UInt8 = 0x0A
    static let udpWaveLast: UInt8 = 0x0B
    static let qualityMode: UInt8 = 0x0C
    static let wave2: UInt8 = 0x0D
}

enum RDPAudioCapabilityFlags {
    static let alive: UInt32 = 0x0000_0001
    static let volume: UInt32 = 0x0000_0002
    static let pitch: UInt32 = 0x0000_0004
}

public enum RDPAudioFormatTag {
    public static let pcm: UInt16 = 0x0001
    public static let extensible: UInt16 = 0xFFFE
}

public enum RDPAudioFormatValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case extraDataTooLarge(maximumByteCount: Int, actualByteCount: Int)

    public var description: String {
        switch self {
        case let .extraDataTooLarge(maximumByteCount, actualByteCount):
            "Audio format extra data is \(actualByteCount) bytes; maximum is \(maximumByteCount) bytes."
        }
    }
}

enum RDPAudioQualityMode {
    static let dynamic: UInt16 = 0x0000
    static let medium: UInt16 = 0x0001
    static let high: UInt16 = 0x0002
}

struct RDPAudioHeader: Equatable, Sendable {
    var messageType: UInt8
    var pad: UInt8
    var bodySize: UInt16

    init(messageType: UInt8, pad: UInt8 = 0, bodySize: UInt16) {
        self.messageType = messageType
        self.pad = pad
        self.bodySize = bodySize
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPAudioHeader {
        try RDPAudioHeader(
            messageType: cursor.readUInt8(),
            pad: cursor.readUInt8(),
            bodySize: cursor.readLittleEndianUInt16()
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(messageType)
        data.appendUInt8(pad)
        data.appendLittleEndianUInt16(bodySize)
        return data
    }
}

struct RDPAudioPDU: Equatable, Sendable {
    var header: RDPAudioHeader
    var payload: Data

    init(messageType: UInt8, pad: UInt8 = 0, payload: Data = Data()) {
        precondition(payload.count <= Int(UInt16.max))
        header = RDPAudioHeader(
            messageType: messageType,
            pad: pad,
            bodySize: UInt16(payload.count)
        )
        self.payload = payload
    }

    var typeName: String {
        switch header.messageType {
        case RDPAudioMessageType.close:
            "audio-close"
        case RDPAudioMessageType.waveInfo:
            "audio-wave-info"
        case RDPAudioMessageType.volume:
            "audio-volume"
        case RDPAudioMessageType.pitch:
            "audio-pitch"
        case RDPAudioMessageType.waveConfirm:
            "audio-wave-confirm"
        case RDPAudioMessageType.training:
            "audio-training"
        case RDPAudioMessageType.formats:
            "audio-formats"
        case RDPAudioMessageType.cryptKey:
            "audio-crypt-key"
        case RDPAudioMessageType.waveEncrypt:
            "audio-wave-encrypt"
        case RDPAudioMessageType.udpWave:
            "audio-udp-wave"
        case RDPAudioMessageType.udpWaveLast:
            "audio-udp-wave-last"
        case RDPAudioMessageType.qualityMode:
            "audio-quality-mode"
        case RDPAudioMessageType.wave2:
            "audio-wave2"
        default:
            "audio-0x\(String(format: "%02x", header.messageType))"
        }
    }

    static func parse(from data: Data) throws -> RDPAudioPDU {
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(data)
        let header = try RDPAudioHeader.parse(from: &cursor)
        if header.messageType == RDPAudioMessageType.waveInfo {
            guard cursor.remaining >= RDPAudioWaveInfoPDU.byteCountWithoutHeader,
                  Int(header.bodySize) >= RDPAudioWaveInfoPDU.byteCountWithoutHeader
            else {
                throw RDPDecodeError.invalidAudioPDU
            }
        } else if Int(header.bodySize) != cursor.remaining {
            throw RDPDecodeError.invalidAudioPDU
        }
        return RDPAudioPDU(header: header, payload: cursor.readRemainingData())
    }

    func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }

    private init(header: RDPAudioHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public struct RDPAudioMessageSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var bodySize: UInt16

    public init(typeName: String, bodySize: UInt16) {
        self.typeName = typeName
        self.bodySize = bodySize
    }

    static func summarize(_ pdu: RDPAudioPDU) -> RDPAudioMessageSummary {
        RDPAudioMessageSummary(
            typeName: pdu.typeName,
            bodySize: pdu.header.bodySize
        )
    }
}

public struct RDPAudioSample: Equatable, Sendable {
    public var format: RDPAudioFormat
    public var timestamp: UInt16
    public var blockNo: UInt8
    public var audioTimestamp: UInt32?
    public var data: Data
    public var receivedAt: Date

    public init(
        format: RDPAudioFormat,
        timestamp: UInt16,
        blockNo: UInt8,
        audioTimestamp: UInt32? = nil,
        data: Data,
        receivedAt: Date
    ) {
        self.format = format
        self.timestamp = timestamp
        self.blockNo = blockNo
        self.audioTimestamp = audioTimestamp
        self.data = data
        self.receivedAt = receivedAt
    }
}

public struct RDPAudioFormat: Encodable, Equatable, Sendable {
    public var formatTag: UInt16
    public var channelCount: UInt16
    public var samplesPerSecond: UInt32
    public var averageBytesPerSecond: UInt32
    public var blockAlign: UInt16
    public var bitsPerSample: UInt16
    public private(set) var extraData: Data

    public static let maximumExtraDataByteCount = Int(UInt16.max)

    public init(
        formatTag: UInt16,
        channelCount: UInt16,
        samplesPerSecond: UInt32,
        averageBytesPerSecond: UInt32,
        blockAlign: UInt16,
        bitsPerSample: UInt16,
        extraData: Data = Data()
    ) throws {
        guard extraData.count <= Self.maximumExtraDataByteCount else {
            throw RDPAudioFormatValidationError.extraDataTooLarge(
                maximumByteCount: Self.maximumExtraDataByteCount,
                actualByteCount: extraData.count
            )
        }

        self.init(
            uncheckedFormatTag: formatTag,
            channelCount: channelCount,
            samplesPerSecond: samplesPerSecond,
            averageBytesPerSecond: averageBytesPerSecond,
            blockAlign: blockAlign,
            bitsPerSample: bitsPerSample,
            extraData: extraData
        )
    }

    private init(
        uncheckedFormatTag formatTag: UInt16,
        channelCount: UInt16,
        samplesPerSecond: UInt32,
        averageBytesPerSecond: UInt32,
        blockAlign: UInt16,
        bitsPerSample: UInt16,
        extraData: Data = Data()
    ) {
        self.formatTag = formatTag
        self.channelCount = channelCount
        self.samplesPerSecond = samplesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.blockAlign = blockAlign
        self.bitsPerSample = bitsPerSample
        self.extraData = extraData
    }

    public static let pcmStereo48k16Bit = RDPAudioFormat(
        uncheckedFormatTag: RDPAudioFormatTag.pcm,
        channelCount: 2,
        samplesPerSecond: 48000,
        averageBytesPerSecond: 192_000,
        blockAlign: 4,
        bitsPerSample: 16
    )

    public var isPCM16Bit: Bool {
        formatTag == RDPAudioFormatTag.pcm
            && bitsPerSample == 16
            && channelCount > 0
            && samplesPerSecond > 0
            && blockAlign == channelCount * 2
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPAudioFormat {
        guard cursor.remaining >= 18 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        let formatTag = try cursor.readLittleEndianUInt16()
        let channelCount = try cursor.readLittleEndianUInt16()
        let samplesPerSecond = try cursor.readLittleEndianUInt32()
        let averageBytesPerSecond = try cursor.readLittleEndianUInt32()
        let blockAlign = try cursor.readLittleEndianUInt16()
        let bitsPerSample = try cursor.readLittleEndianUInt16()
        let extraDataByteCount = try Int(cursor.readLittleEndianUInt16())
        guard extraDataByteCount <= cursor.remaining else {
            throw RDPDecodeError.invalidAudioPDU
        }
        let extraData = try cursor.readData(count: extraDataByteCount)
        return try RDPAudioFormat(
            formatTag: formatTag,
            channelCount: channelCount,
            samplesPerSecond: samplesPerSecond,
            averageBytesPerSecond: averageBytesPerSecond,
            blockAlign: blockAlign,
            bitsPerSample: bitsPerSample,
            extraData: extraData
        )
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(formatTag)
        data.appendLittleEndianUInt16(channelCount)
        data.appendLittleEndianUInt32(samplesPerSecond)
        data.appendLittleEndianUInt32(averageBytesPerSecond)
        data.appendLittleEndianUInt16(blockAlign)
        data.appendLittleEndianUInt16(bitsPerSample)
        data.appendLittleEndianUInt16(UInt16(extraData.count))
        data.append(extraData)
        return data
    }
}

struct RDPAudioInputPDU: Equatable, Sendable {
    var messageType: UInt8
    var payload: Data

    var typeName: String {
        switch messageType {
        case RDPAudioInputMessageType.version:
            "audio-input-version"
        case RDPAudioInputMessageType.formats:
            "audio-input-formats"
        case RDPAudioInputMessageType.open:
            "audio-input-open"
        case RDPAudioInputMessageType.openReply:
            "audio-input-open-reply"
        case RDPAudioInputMessageType.dataIncoming:
            "audio-input-data-incoming"
        case RDPAudioInputMessageType.data:
            "audio-input-data"
        case RDPAudioInputMessageType.formatChange:
            "audio-input-format-change"
        default:
            "audio-input-0x\(String(format: "%02x", messageType))"
        }
    }

    init(messageType: UInt8, payload: Data = Data()) {
        self.messageType = messageType
        self.payload = payload
    }

    static func parse(from data: Data) throws -> RDPAudioInputPDU {
        guard data.isEmpty == false else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(data)
        return try RDPAudioInputPDU(
            messageType: cursor.readUInt8(),
            payload: cursor.readRemainingData()
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendUInt8(messageType)
        data.append(payload)
        return data
    }
}

struct RDPAudioInputVersionPDU: Equatable, Sendable {
    static let maximumSupportedVersion: UInt32 = 2

    var version: UInt32

    init(version: UInt32 = maximumSupportedVersion) {
        self.version = version
    }

    init(serverVersion: UInt32) {
        version = min(max(serverVersion, 1), Self.maximumSupportedVersion)
    }

    static func parseIfPresent(from pdu: RDPAudioInputPDU) throws -> RDPAudioInputVersionPDU? {
        guard pdu.messageType == RDPAudioInputMessageType.version else {
            return nil
        }
        guard pdu.payload.count == 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let version = try cursor.readLittleEndianUInt32()
        guard version >= 1 else {
            throw RDPDecodeError.invalidAudioPDU
        }
        return RDPAudioInputVersionPDU(version: version)
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(version)
        return RDPAudioInputPDU(
            messageType: RDPAudioInputMessageType.version,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioInputFormatsPDU: Equatable, Sendable {
    var cbSizeFormatsPacket: UInt32
    var formats: [RDPAudioFormat]
    var extraData: Data

    init(
        cbSizeFormatsPacket: UInt32 = 0,
        formats: [RDPAudioFormat],
        extraData: Data = Data()
    ) {
        precondition(formats.count <= Int(UInt32.max))

        self.cbSizeFormatsPacket = cbSizeFormatsPacket
        self.formats = formats
        self.extraData = extraData
    }

    static func parseIfPresent(from pdu: RDPAudioInputPDU) throws -> RDPAudioInputFormatsPDU? {
        guard pdu.messageType == RDPAudioInputMessageType.formats else {
            return nil
        }
        guard pdu.payload.count >= 8 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let formatCount = try Int(cursor.readLittleEndianUInt32())
        let cbSizeFormatsPacket = try cursor.readLittleEndianUInt32()
        guard formatCount <= cursor.remaining / 18 else {
            throw RDPDecodeError.invalidAudioPDU
        }
        var formats: [RDPAudioFormat] = []
        formats.reserveCapacity(formatCount)
        for _ in 0 ..< formatCount {
            try formats.append(RDPAudioFormat.parse(from: &cursor))
        }

        return RDPAudioInputFormatsPDU(
            cbSizeFormatsPacket: cbSizeFormatsPacket,
            formats: formats,
            extraData: cursor.readRemainingData()
        )
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(UInt32(formats.count))
        payload.appendLittleEndianUInt32(encodedSizeWithoutExtraData)
        for format in formats {
            payload.append(format.encoded())
        }
        payload.append(extraData)
        return RDPAudioInputPDU(
            messageType: RDPAudioInputMessageType.formats,
            payload: payload
        ).encoded()
    }

    private var encodedSizeWithoutExtraData: UInt32 {
        UInt32(1 + 4 + 4 + formats.reduce(0) { $0 + $1.encoded().count })
    }
}

struct RDPAudioInputOpenPDU: Equatable, Sendable {
    private static let maximumChannelMask: UInt32 = 0x0003_FFFF
    private static let pcmSubformat = Data([
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00,
        0x10, 0x00,
        0x80, 0x00,
        0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ])

    var framesPerPacket: UInt32
    var initialFormat: UInt32
    var format: RDPAudioFormat

    static func parseIfPresent(from pdu: RDPAudioInputPDU) throws -> RDPAudioInputOpenPDU? {
        guard pdu.messageType == RDPAudioInputMessageType.open else {
            return nil
        }
        guard pdu.payload.count >= 26 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let framesPerPacket = try cursor.readLittleEndianUInt32()
        let initialFormat = try cursor.readLittleEndianUInt32()
        let format = try RDPAudioFormat.parse(from: &cursor)
        guard cursor.remaining == 0,
              try isValidExtensibleFormat(format)
        else {
            throw RDPDecodeError.invalidAudioPDU
        }

        return RDPAudioInputOpenPDU(
            framesPerPacket: framesPerPacket,
            initialFormat: initialFormat,
            format: format
        )
    }

    private static func isValidExtensibleFormat(_ format: RDPAudioFormat) throws -> Bool {
        guard format.formatTag == RDPAudioFormatTag.extensible else {
            return true
        }
        guard format.extraData.count == 22 else {
            return false
        }

        var cursor = ByteCursor(format.extraData)
        let validBitsPerSample = try cursor.readLittleEndianUInt16()
        let channelMask = try cursor.readLittleEndianUInt32()
        let subformat = try cursor.readData(count: 16)
        return validBitsPerSample <= format.bitsPerSample
            && channelMask & ~maximumChannelMask == 0
            && subformat == pcmSubformat
    }
}

struct RDPAudioInputOpenReplyPDU: Equatable, Sendable {
    static let genericFailure: UInt32 = 0x8000_4005

    var result: UInt32

    init(result: UInt32 = genericFailure) {
        self.result = result
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(result)
        return RDPAudioInputPDU(
            messageType: RDPAudioInputMessageType.openReply,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioInputIncomingDataPDU: Equatable, Sendable {
    func encoded() -> Data {
        RDPAudioInputPDU(messageType: RDPAudioInputMessageType.dataIncoming).encoded()
    }
}

struct RDPAudioInputFormatChangePDU: Equatable, Sendable {
    var newFormat: UInt32

    static func parseIfPresent(from pdu: RDPAudioInputPDU) throws -> RDPAudioInputFormatChangePDU? {
        guard pdu.messageType == RDPAudioInputMessageType.formatChange else {
            return nil
        }
        guard pdu.payload.count == 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPAudioInputFormatChangePDU(newFormat: cursor.readLittleEndianUInt32())
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(newFormat)
        return RDPAudioInputPDU(
            messageType: RDPAudioInputMessageType.formatChange,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioWaveInfoPDU: Equatable, Sendable {
    static let byteCountWithoutHeader = 12

    var timestamp: UInt16
    var formatNo: UInt16
    var blockNo: UInt8
    var initialAudioData: Data
    var expectedWaveDataByteCount: Int

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioWaveInfoPDU? {
        guard pdu.header.messageType == RDPAudioMessageType.waveInfo else {
            return nil
        }
        guard pdu.payload.count == byteCountWithoutHeader,
              Int(pdu.header.bodySize) >= byteCountWithoutHeader
        else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let timestamp = try cursor.readLittleEndianUInt16()
        let formatNo = try cursor.readLittleEndianUInt16()
        let blockNo = try cursor.readUInt8()
        _ = try cursor.readData(count: 3)
        let initialAudioData = try cursor.readData(count: 4)
        return RDPAudioWaveInfoPDU(
            timestamp: timestamp,
            formatNo: formatNo,
            blockNo: blockNo,
            initialAudioData: initialAudioData,
            expectedWaveDataByteCount: Int(pdu.header.bodySize) - byteCountWithoutHeader
        )
    }
}

struct RDPAudioWaveDataPDU: Equatable, Sendable {
    var data: Data

    static func parse(from payload: Data) throws -> RDPAudioWaveDataPDU {
        guard payload.count >= 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(payload)
        let pad = try cursor.readLittleEndianUInt32()
        guard pad == 0 else {
            throw RDPDecodeError.invalidAudioPDU
        }
        return RDPAudioWaveDataPDU(data: cursor.readRemainingData())
    }
}

struct RDPAudioWave2PDU: Equatable, Sendable {
    var timestamp: UInt16
    var formatNo: UInt16
    var blockNo: UInt8
    var audioTimestamp: UInt32
    var data: Data

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioWave2PDU? {
        guard pdu.header.messageType == RDPAudioMessageType.wave2 else {
            return nil
        }
        guard pdu.payload.count >= 12 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let timestamp = try cursor.readLittleEndianUInt16()
        let formatNo = try cursor.readLittleEndianUInt16()
        let blockNo = try cursor.readUInt8()
        _ = try cursor.readData(count: 3)
        let audioTimestamp = try cursor.readLittleEndianUInt32()
        return RDPAudioWave2PDU(
            timestamp: timestamp,
            formatNo: formatNo,
            blockNo: blockNo,
            audioTimestamp: audioTimestamp,
            data: cursor.readRemainingData()
        )
    }
}

struct RDPAudioWaveConfirmPDU: Equatable, Sendable {
    var timestamp: UInt16
    var blockNo: UInt8

    init(timestamp: UInt16, blockNo: UInt8) {
        self.timestamp = timestamp
        self.blockNo = blockNo
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(timestamp)
        payload.appendUInt8(blockNo)
        payload.appendUInt8(0)
        return RDPAudioPDU(
            messageType: RDPAudioMessageType.waveConfirm,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioVolumePDU: Equatable, Sendable {
    var volume: UInt32

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioVolumePDU? {
        guard pdu.header.messageType == RDPAudioMessageType.volume else {
            return nil
        }
        guard pdu.payload.count == 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPAudioVolumePDU(volume: cursor.readLittleEndianUInt32())
    }
}

struct RDPAudioPitchPDU: Equatable, Sendable {
    var pitch: UInt32

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioPitchPDU? {
        guard pdu.header.messageType == RDPAudioMessageType.pitch else {
            return nil
        }
        guard pdu.payload.count == 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPAudioPitchPDU(pitch: cursor.readLittleEndianUInt32())
    }
}

struct RDPAudioFormatsPDU: Equatable, Sendable {
    var flags: UInt32
    var volume: UInt32
    var pitch: UInt32
    var datagramPort: UInt16
    var lastBlockConfirmed: UInt8
    var version: UInt16
    var formats: [RDPAudioFormat]

    init(
        flags: UInt32,
        volume: UInt32 = 0,
        pitch: UInt32 = 0,
        datagramPort: UInt16 = 0,
        lastBlockConfirmed: UInt8 = 0,
        version: UInt16 = 6,
        formats: [RDPAudioFormat]
    ) {
        precondition(formats.count <= Int(UInt16.max))

        self.flags = flags
        self.volume = volume
        self.pitch = pitch
        self.datagramPort = datagramPort
        self.lastBlockConfirmed = lastBlockConfirmed
        self.version = version
        self.formats = formats
    }

    static func clientPCM(version: UInt16) -> RDPAudioFormatsPDU {
        RDPAudioFormatsPDU(
            flags: RDPAudioCapabilityFlags.alive | RDPAudioCapabilityFlags.volume,
            volume: 0xFFFF_FFFF,
            datagramPort: 0,
            version: version,
            formats: [.pcmStereo48k16Bit]
        )
    }

    static func compatibleClientFormats(from serverFormats: [RDPAudioFormat]) -> [RDPAudioFormat] {
        let exactPCM = serverFormats.first { format in
            format.formatTag == RDPAudioFormatTag.pcm
                && format.channelCount == RDPAudioFormat.pcmStereo48k16Bit.channelCount
                && format.samplesPerSecond == RDPAudioFormat.pcmStereo48k16Bit.samplesPerSecond
                && format.bitsPerSample == RDPAudioFormat.pcmStereo48k16Bit.bitsPerSample
                && format.blockAlign == RDPAudioFormat.pcmStereo48k16Bit.blockAlign
        }
        if let exactPCM {
            return [exactPCM]
        }

        return serverFormats.first(where: \.isPCM16Bit).map { [$0] } ?? []
    }

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioFormatsPDU? {
        guard pdu.header.messageType == RDPAudioMessageType.formats else {
            return nil
        }
        guard pdu.payload.count >= 20 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let flags = try cursor.readLittleEndianUInt32()
        let volume = try cursor.readLittleEndianUInt32()
        let pitch = try cursor.readLittleEndianUInt32()
        let datagramPort = try cursor.readBigEndianUInt16()
        let formatCount = try Int(cursor.readLittleEndianUInt16())
        let lastBlockConfirmed = try cursor.readUInt8()
        let version = try cursor.readLittleEndianUInt16()
        _ = try cursor.readUInt8()
        guard formatCount <= cursor.remaining / 18 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var formats: [RDPAudioFormat] = []
        formats.reserveCapacity(formatCount)
        for _ in 0 ..< formatCount {
            try formats.append(RDPAudioFormat.parse(from: &cursor))
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        return RDPAudioFormatsPDU(
            flags: flags,
            volume: volume,
            pitch: pitch,
            datagramPort: datagramPort,
            lastBlockConfirmed: lastBlockConfirmed,
            version: version,
            formats: formats
        )
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(flags)
        payload.appendLittleEndianUInt32(volume)
        payload.appendLittleEndianUInt32(pitch)
        payload.appendBigEndianUInt16(datagramPort)
        payload.appendLittleEndianUInt16(UInt16(formats.count))
        payload.appendUInt8(lastBlockConfirmed)
        payload.appendLittleEndianUInt16(version)
        payload.appendUInt8(0)
        for format in formats {
            payload.append(format.encoded())
        }
        return RDPAudioPDU(
            messageType: RDPAudioMessageType.formats,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioQualityModePDU: Equatable, Sendable {
    var qualityMode: UInt16

    init(qualityMode: UInt16 = RDPAudioQualityMode.dynamic) {
        self.qualityMode = qualityMode
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(qualityMode)
        payload.appendLittleEndianUInt16(0)
        return RDPAudioPDU(
            messageType: RDPAudioMessageType.qualityMode,
            payload: payload
        ).encoded()
    }
}

struct RDPAudioTrainingPDU: Equatable, Sendable {
    var timestamp: UInt16
    var packetSize: UInt16

    static func parseIfPresent(from pdu: RDPAudioPDU) throws -> RDPAudioTrainingPDU? {
        guard pdu.header.messageType == RDPAudioMessageType.training else {
            return nil
        }
        guard pdu.payload.count >= 4 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let timestamp = try cursor.readLittleEndianUInt16()
        let packetSize = try cursor.readLittleEndianUInt16()
        let dataByteCount = cursor.remaining
        let fullPDUByteCount = pdu.payload.count + 4
        if dataByteCount > 0 {
            guard fullPDUByteCount <= Int(UInt16.max),
                  packetSize == UInt16(fullPDUByteCount) || packetSize == UInt16(dataByteCount)
            else {
                throw RDPDecodeError.invalidAudioPDU
            }
        }

        return RDPAudioTrainingPDU(timestamp: timestamp, packetSize: packetSize)
    }

    func confirmEncoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt16(timestamp)
        payload.appendLittleEndianUInt16(packetSize)
        return RDPAudioPDU(
            messageType: RDPAudioMessageType.training,
            payload: payload
        ).encoded()
    }
}

public final class RDPAudioSession: @unchecked Sendable {
    public let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let dynamicChannelID: UInt32?
    private let lock = NSLock()
    private var serverFormats: [RDPAudioFormat] = []
    private var negotiatedFormats: [RDPAudioFormat] = []
    private var serverVersion: UInt16 = 0
    private var pendingWaveInfo: RDPAudioWaveInfoPDU?

    init(userChannelID: UInt16, staticChannelID: UInt16, channel: Channel) {
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
        dynamicChannelID = nil
    }

    init(
        userChannelID: UInt16,
        dynamicStaticChannelID: UInt16,
        dynamicChannelID: UInt32,
        channel: Channel
    ) {
        self.userChannelID = userChannelID
        staticChannelID = dynamicStaticChannelID
        self.channel = channel
        self.dynamicChannelID = dynamicChannelID
    }

    func handlesDynamicChannel(_ channelID: UInt32) -> Bool {
        dynamicChannelID == channelID
    }

    func respondToServerFormats(_ serverFormatsPDU: RDPAudioFormatsPDU) {
        let clientVersion = min(UInt16(8), max(UInt16(2), serverFormatsPDU.version))
        let formats = negotiatedFormats(from: serverFormatsPDU.formats)
        let clientFormats = RDPAudioFormatsPDU(
            flags: RDPAudioCapabilityFlags.alive | RDPAudioCapabilityFlags.volume,
            volume: 0xFFFF_FFFF,
            datagramPort: 0,
            version: clientVersion,
            formats: formats
        )

        lock.lock()
        serverFormats = serverFormatsPDU.formats
        negotiatedFormats = formats
        serverVersion = serverFormatsPDU.version
        lock.unlock()

        send(clientFormats.encoded())
        if serverFormatsPDU.version >= 6 {
            send(RDPAudioQualityModePDU(qualityMode: RDPAudioQualityMode.high).encoded())
        }
    }

    func respondToTraining(_ training: RDPAudioTrainingPDU) {
        send(training.confirmEncoded())
    }

    func receive(_ pdu: RDPAudioPDU, receivedAt: Date) throws -> RDPAudioSample? {
        if let waveInfo = try RDPAudioWaveInfoPDU.parseIfPresent(from: pdu) {
            lock.lock()
            let canReceiveWaveInfo = serverVersion < 8
            if canReceiveWaveInfo {
                pendingWaveInfo = waveInfo
            }
            lock.unlock()
            guard canReceiveWaveInfo else {
                throw RDPDecodeError.invalidAudioPDU
            }
            return nil
        }

        if let wave2 = try RDPAudioWave2PDU.parseIfPresent(from: pdu) {
            lock.lock()
            let canReceiveWave2 = serverVersion >= 8
            lock.unlock()
            guard canReceiveWave2 else {
                throw RDPDecodeError.invalidAudioPDU
            }
            return try sample(
                formatNo: wave2.formatNo,
                timestamp: wave2.timestamp,
                blockNo: wave2.blockNo,
                audioTimestamp: wave2.audioTimestamp,
                data: wave2.data,
                receivedAt: receivedAt
            )
        }

        return nil
    }

    func receiveWaveData(_ payload: Data, receivedAt: Date) throws -> RDPAudioSample? {
        let waveInfo: RDPAudioWaveInfoPDU?
        lock.lock()
        waveInfo = pendingWaveInfo
        pendingWaveInfo = nil
        lock.unlock()

        guard let waveInfo else {
            return nil
        }

        let waveData = try RDPAudioWaveDataPDU.parse(from: payload)
        guard waveData.data.count == waveInfo.expectedWaveDataByteCount else {
            throw RDPDecodeError.invalidAudioPDU
        }

        var sampleData = Data()
        sampleData.reserveCapacity(waveInfo.initialAudioData.count + waveData.data.count)
        sampleData.append(waveInfo.initialAudioData)
        sampleData.append(waveData.data)
        return try sample(
            formatNo: waveInfo.formatNo,
            timestamp: waveInfo.timestamp,
            blockNo: waveInfo.blockNo,
            audioTimestamp: nil,
            data: sampleData,
            receivedAt: receivedAt
        )
    }

    func confirmConsumed(_ sample: RDPAudioSample) {
        let elapsedMilliseconds = max(0, Int(Date().timeIntervalSince(sample.receivedAt) * 1000))
        let timestamp = sample.timestamp &+ UInt16(truncatingIfNeeded: elapsedMilliseconds)
        send(RDPAudioWaveConfirmPDU(timestamp: timestamp, blockNo: sample.blockNo).encoded())
    }

    private func negotiatedFormats(from serverFormats: [RDPAudioFormat]) -> [RDPAudioFormat] {
        RDPAudioFormatsPDU.compatibleClientFormats(from: serverFormats)
    }

    private func sample(
        formatNo: UInt16,
        timestamp: UInt16,
        blockNo: UInt8,
        audioTimestamp: UInt32?,
        data: Data,
        receivedAt: Date
    ) throws -> RDPAudioSample {
        let format: RDPAudioFormat?
        lock.lock()
        if Int(formatNo) < negotiatedFormats.count {
            format = negotiatedFormats[Int(formatNo)]
        } else {
            format = nil
        }
        lock.unlock()

        guard let format, format.isPCM16Bit else {
            throw RDPDecodeError.invalidAudioPDU
        }
        guard data.count % Int(format.blockAlign) == 0 else {
            throw RDPDecodeError.invalidAudioPDU
        }

        return RDPAudioSample(
            format: format,
            timestamp: timestamp,
            blockNo: blockNo,
            audioTimestamp: audioTimestamp,
            data: data,
            receivedAt: receivedAt
        )
    }

    private func send(_ payload: Data) {
        let packets = Self.encodedPackets(
            payload,
            userChannelID: userChannelID,
            staticChannelID: staticChannelID,
            dynamicChannelID: dynamicChannelID
        )
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            for packet in packets {
                var buffer = self.channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                self.channel.writeAndFlush(buffer, promise: nil)
            }
        }
    }

    static func encodedPacket(
        _ payload: Data,
        userChannelID: UInt16,
        staticChannelID: UInt16,
        dynamicChannelID: UInt32?
    ) -> Data {
        if let dynamicChannelID {
            precondition(payload.count <= RDPDynamicVirtualChannelDataPDU.maximumPayloadByteCount(
                channelID: dynamicChannelID
            ))
        }
        return encodedPackets(
            payload,
            userChannelID: userChannelID,
            staticChannelID: staticChannelID,
            dynamicChannelID: dynamicChannelID
        )[0]
    }

    static func encodedPackets(
        _ payload: Data,
        userChannelID: UInt16,
        staticChannelID: UInt16,
        dynamicChannelID: UInt32?
    ) -> [Data] {
        let channelPayload: Data
        let staticChannelFlags: UInt32
        if let dynamicChannelID {
            return RDPDynamicVirtualChannelDataPacketizer(
                channelID: dynamicChannelID,
                payload: payload
            ).encodedPDUs().map { dynamicPayload in
                RDPStaticVirtualChannelPDU(
                    payload: dynamicPayload,
                    flags: RDPStaticVirtualChannelFlags.complete
                ).encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
            }
        } else {
            channelPayload = payload
            staticChannelFlags = RDPStaticVirtualChannelFlags.complete
        }

        return [RDPStaticVirtualChannelPDU(
            payload: channelPayload,
            flags: staticChannelFlags
        ).encodedTPKT(initiator: userChannelID, channelID: staticChannelID)]
    }
}
