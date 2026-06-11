import Foundation

enum RDPGFXChannel {
    static let name = "Microsoft::Windows::RDS::Graphics"
}

enum RDPGFXCommandID {
    static let wireToSurface1: UInt16 = 0x0001
    static let wireToSurface2: UInt16 = 0x0002
    static let createSurface: UInt16 = 0x0009
    static let startFrame: UInt16 = 0x000B
    static let endFrame: UInt16 = 0x000C
    static let frameAcknowledge: UInt16 = 0x000D
    static let resetGraphics: UInt16 = 0x000E
    static let mapSurfaceToOutput: UInt16 = 0x000F
    static let capsAdvertise: UInt16 = 0x0012
    static let capsConfirm: UInt16 = 0x0013
}

enum RDPGFXCodecID {
    static let uncompressed: UInt16 = 0x0000
    static let cavideo: UInt16 = 0x0003
    static let clearCodec: UInt16 = 0x0008
    static let caProgressive: UInt16 = 0x0009
    static let planar: UInt16 = 0x000A
    static let avc420: UInt16 = 0x000B
    static let alpha: UInt16 = 0x000C
    static let avc444: UInt16 = 0x000E
    static let avc444v2: UInt16 = 0x000F

    static func name(for codecID: UInt16) -> String {
        switch codecID {
        case uncompressed:
            "uncompressed"
        case cavideo:
            "cavideo"
        case clearCodec:
            "clearcodec"
        case caProgressive:
            "caprogressive"
        case planar:
            "planar"
        case avc420:
            "avc420"
        case alpha:
            "alpha"
        case avc444:
            "avc444"
        case avc444v2:
            "avc444v2"
        default:
            "codec-0x\(String(format: "%04x", codecID))"
        }
    }
}

enum RDPGFXCapabilityVersion {
    static let version8: UInt32 = 0x0008_0004
    static let version81: UInt32 = 0x0008_0105
}

enum RDPGFXCapabilityFlags {
    static let thinClient: UInt32 = 0x0000_0001
    static let smallCache: UInt32 = 0x0000_0002
    static let avc420Enabled: UInt32 = 0x0000_0010
}

struct RDPGFXHeader: Equatable, Sendable {
    var commandID: UInt16
    var flags: UInt16
    var pduLength: UInt32
    var payload: Data

    var typeName: String {
        switch commandID {
        case RDPGFXCommandID.wireToSurface1:
            "rdpgfx-wire-to-surface-1"
        case RDPGFXCommandID.wireToSurface2:
            "rdpgfx-wire-to-surface-2"
        case RDPGFXCommandID.createSurface:
            "rdpgfx-create-surface"
        case RDPGFXCommandID.startFrame:
            "rdpgfx-start-frame"
        case RDPGFXCommandID.endFrame:
            "rdpgfx-end-frame"
        case RDPGFXCommandID.frameAcknowledge:
            "rdpgfx-frame-acknowledge"
        case RDPGFXCommandID.resetGraphics:
            "rdpgfx-reset-graphics"
        case RDPGFXCommandID.mapSurfaceToOutput:
            "rdpgfx-map-surface-to-output"
        case RDPGFXCommandID.capsAdvertise:
            "rdpgfx-caps-advertise"
        case RDPGFXCommandID.capsConfirm:
            "rdpgfx-caps-confirm"
        default:
            "rdpgfx-0x\(String(format: "%04x", commandID))"
        }
    }

    static func parse(from data: Data) throws -> RDPGFXHeader {
        guard data.count >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        return try parse(from: &cursor)
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPGFXHeader {
        guard cursor.remaining >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let commandID = try cursor.readLittleEndianUInt16()
        let flags = try cursor.readLittleEndianUInt16()
        let pduLength = try cursor.readLittleEndianUInt32()
        guard pduLength >= 8,
              Int(pduLength) - 8 <= cursor.remaining
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let payload = try cursor.readData(count: Int(pduLength) - 8)
        return RDPGFXHeader(
            commandID: commandID,
            flags: flags,
            pduLength: pduLength,
            payload: payload
        )
    }
}

struct RDPGFXCapabilitySet: Equatable, Sendable {
    var version: UInt32
    var data: Data

    init(version: UInt32, data: Data) {
        precondition(data.count <= Int(UInt32.max))

        self.version = version
        self.data = data
    }

    static func version81(flags: UInt32) -> RDPGFXCapabilitySet {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        return RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version81, data: data)
    }

    var encoded: Data {
        var bytes = Data()
        bytes.appendLittleEndianUInt32(version)
        bytes.appendLittleEndianUInt32(UInt32(data.count))
        bytes.append(data)
        return bytes
    }

    var flags: UInt32? {
        guard data.count >= 4 else {
            return nil
        }
        var cursor = ByteCursor(data)
        return try? cursor.readLittleEndianUInt32()
    }

    static func parse(from data: Data) throws -> RDPGFXCapabilitySet {
        guard data.count >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        let version = try cursor.readLittleEndianUInt32()
        let dataLength = try cursor.readLittleEndianUInt32()
        guard dataLength <= UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return try RDPGFXCapabilitySet(
            version: version,
            data: cursor.readData(count: Int(dataLength))
        )
    }
}

struct RDPGFXCapsAdvertisePDU: Equatable, Sendable {
    var capabilitySets: [RDPGFXCapabilitySet]

    init(capabilitySets: [RDPGFXCapabilitySet] = [.version81(flags: RDPGFXCapabilityFlags.smallCache | RDPGFXCapabilityFlags.avc420Enabled)]) {
        precondition(!capabilitySets.isEmpty)
        precondition(capabilitySets.count <= Int(UInt16.max))

        self.capabilitySets = capabilitySets
    }

    func encoded() -> Data {
        let encodedSets = capabilitySets.reduce(into: Data()) { data, capabilitySet in
            data.append(capabilitySet.encoded)
        }

        let pduLength = 8 + 2 + encodedSets.count
        precondition(pduLength <= Int(UInt32.max))

        var data = Data()
        data.appendLittleEndianUInt16(RDPGFXCommandID.capsAdvertise)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(UInt32(pduLength))
        data.appendLittleEndianUInt16(UInt16(capabilitySets.count))
        data.append(encodedSets)
        return data
    }
}

struct RDPGFXCapsConfirmPDU: Equatable, Sendable {
    var capabilitySet: RDPGFXCapabilitySet

    static func parseIfPresent(from data: Data) throws -> RDPGFXCapsConfirmPDU? {
        let header = try RDPGFXHeader.parse(from: data)
        guard header.commandID == RDPGFXCommandID.capsConfirm else {
            return nil
        }

        return try RDPGFXCapsConfirmPDU(
            capabilitySet: RDPGFXCapabilitySet.parse(from: header.payload)
        )
    }
}

struct RDPGFXRect16: Encodable, Equatable, Sendable {
    var left: UInt16
    var top: UInt16
    var right: UInt16
    var bottom: UInt16

    init(left: UInt16, top: UInt16, right: UInt16, bottom: UInt16) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    var width: UInt16 {
        right >= left ? right - left : 0
    }

    var height: UInt16 {
        bottom >= top ? bottom - top : 0
    }

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXRect16 {
        try RDPGFXRect16(
            left: cursor.readLittleEndianUInt16(),
            top: cursor.readLittleEndianUInt16(),
            right: cursor.readLittleEndianUInt16(),
            bottom: cursor.readLittleEndianUInt16()
        )
    }
}

public struct RDPH264NALUnit: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data
}

public struct RDPHEVCNALUnit: Equatable, Sendable {
    public var type: UInt8
    public var payload: Data
}

enum RDPAnnexB {
    static func nalUnitPayloads(from data: Data) -> [Data] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return nalUnitPayloadRanges(in: bytes).map { range in
                payload(in: bytes, range: range)
            }
        }
    }

    static func nalUnitPayloadRanges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        guard bytes.count >= 3 else {
            return []
        }

        var ranges: [Range<Int>] = []
        var searchOffset = 0
        var payloadStart: Int?

        while let startCode = nextStartCode(in: bytes, from: searchOffset) {
            if let previousPayloadStart = payloadStart,
               previousPayloadStart < startCode.index
            {
                ranges.append(previousPayloadStart ..< startCode.index)
            }
            payloadStart = startCode.index + startCode.length
            searchOffset = startCode.index + startCode.length
        }

        if let payloadStart,
           payloadStart < bytes.count
        {
            ranges.append(payloadStart ..< bytes.count)
        }

        return ranges
    }

    static func nextStartCode(
        in bytes: UnsafeBufferPointer<UInt8>,
        from offset: Int
    ) -> (index: Int, length: Int)? {
        guard bytes.count >= 3, offset < bytes.count - 2 else {
            return nil
        }

        var index = offset
        while index < bytes.count - 2 {
            if bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 1
            {
                return (index, 3)
            }
            if index < bytes.count - 3,
               bytes[index] == 0,
               bytes[index + 1] == 0,
               bytes[index + 2] == 0,
               bytes[index + 3] == 1
            {
                return (index, 4)
            }
            index += 1
        }

        return nil
    }

    static func payload(
        in bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> Data {
        guard let baseAddress = bytes.baseAddress else {
            return Data()
        }
        return Data(bytes: baseAddress.advanced(by: range.lowerBound), count: range.count)
    }

    static func appendPayload(
        in bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        to data: inout Data
    ) {
        guard let baseAddress = bytes.baseAddress else {
            return
        }
        data.append(baseAddress.advanced(by: range.lowerBound), count: range.count)
    }
}

public struct RDPH264AnnexBSample: Equatable, Sendable {
    public var lengthPrefixedData: Data
    public var sequenceParameterSet: Data?
    public var pictureParameterSet: Data?

    public var isEmpty: Bool {
        lengthPrefixedData.isEmpty
    }
}

public struct RDPHEVCAnnexBSample: Equatable, Sendable {
    public var lengthPrefixedData: Data
    public var videoParameterSet: Data?
    public var sequenceParameterSet: Data?
    public var pictureParameterSet: Data?

    public var isEmpty: Bool {
        lengthPrefixedData.isEmpty
    }
}

public enum RDPH264AnnexB {
    public static func nalUnits(from data: Data) -> [RDPH264NALUnit] {
        RDPAnnexB.nalUnitPayloads(from: data).map { payload in
            RDPH264NALUnit(type: payload[0] & 0x1F, payload: payload)
        }
    }

    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return RDPAnnexB.nalUnitPayloadRanges(in: bytes).map { range in
                bytes[range.lowerBound] & 0x1F
            }
        }
    }

    public static func sample(from data: Data) -> RDPH264AnnexBSample {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let ranges = RDPAnnexB.nalUnitPayloadRanges(in: bytes)
            guard ranges.isEmpty == false else {
                return RDPH264AnnexBSample(
                    lengthPrefixedData: Data(),
                    sequenceParameterSet: nil,
                    pictureParameterSet: nil
                )
            }

            let payloadByteCount = ranges.reduce(0) { $0 + $1.count }
            var lengthPrefixedData = Data()
            lengthPrefixedData.reserveCapacity(payloadByteCount + ranges.count * 4)
            var sequenceParameterSet: Data?
            var pictureParameterSet: Data?

            for range in ranges {
                let type = bytes[range.lowerBound] & 0x1F
                if type == 7, sequenceParameterSet == nil {
                    sequenceParameterSet = RDPAnnexB.payload(in: bytes, range: range)
                }
                if type == 8, pictureParameterSet == nil {
                    pictureParameterSet = RDPAnnexB.payload(in: bytes, range: range)
                }

                var length = UInt32(range.count).bigEndian
                withUnsafeBytes(of: &length) { lengthBytes in
                    lengthPrefixedData.append(contentsOf: lengthBytes)
                }
                RDPAnnexB.appendPayload(in: bytes, range: range, to: &lengthPrefixedData)
            }

            return RDPH264AnnexBSample(
                lengthPrefixedData: lengthPrefixedData,
                sequenceParameterSet: sequenceParameterSet,
                pictureParameterSet: pictureParameterSet
            )
        }
    }
}

public enum RDPHEVCAnnexB {
    public static func nalUnits(from data: Data) -> [RDPHEVCNALUnit] {
        RDPAnnexB.nalUnitPayloads(from: data).compactMap { payload in
            guard payload.count >= 2,
                  let header = payload.first
            else {
                return nil
            }
            return RDPHEVCNALUnit(type: (header >> 1) & 0x3F, payload: payload)
        }
    }

    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return RDPAnnexB.nalUnitPayloadRanges(in: bytes).compactMap { range in
                guard range.count >= 2 else {
                    return nil
                }
                return (bytes[range.lowerBound] >> 1) & 0x3F
            }
        }
    }

    public static func sample(from data: Data) -> RDPHEVCAnnexBSample {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let ranges = RDPAnnexB.nalUnitPayloadRanges(in: bytes)
            guard ranges.isEmpty == false else {
                return RDPHEVCAnnexBSample(
                    lengthPrefixedData: Data(),
                    videoParameterSet: nil,
                    sequenceParameterSet: nil,
                    pictureParameterSet: nil
                )
            }

            var validRangeCount = 0
            let payloadByteCount = ranges.reduce(0) { byteCount, range in
                guard range.count >= 2 else {
                    return byteCount
                }
                validRangeCount += 1
                return byteCount + range.count
            }
            var lengthPrefixedData = Data()
            lengthPrefixedData.reserveCapacity(payloadByteCount + validRangeCount * 4)
            var videoParameterSet: Data?
            var sequenceParameterSet: Data?
            var pictureParameterSet: Data?

            for range in ranges where range.count >= 2 {
                let type = (bytes[range.lowerBound] >> 1) & 0x3F
                if type == 32, videoParameterSet == nil {
                    videoParameterSet = RDPAnnexB.payload(in: bytes, range: range)
                }
                if type == 33, sequenceParameterSet == nil {
                    sequenceParameterSet = RDPAnnexB.payload(in: bytes, range: range)
                }
                if type == 34, pictureParameterSet == nil {
                    pictureParameterSet = RDPAnnexB.payload(in: bytes, range: range)
                }

                var length = UInt32(range.count).bigEndian
                withUnsafeBytes(of: &length) { lengthBytes in
                    lengthPrefixedData.append(contentsOf: lengthBytes)
                }
                RDPAnnexB.appendPayload(in: bytes, range: range, to: &lengthPrefixedData)
            }

            return RDPHEVCAnnexBSample(
                lengthPrefixedData: lengthPrefixedData,
                videoParameterSet: videoParameterSet,
                sequenceParameterSet: sequenceParameterSet,
                pictureParameterSet: pictureParameterSet
            )
        }
    }
}

struct RDPGFXAVC420QuantQuality: Encodable, Equatable, Sendable {
    var qpVal: UInt8
    var qualityVal: UInt8

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXAVC420QuantQuality {
        try RDPGFXAVC420QuantQuality(
            qpVal: cursor.readUInt8(),
            qualityVal: cursor.readUInt8()
        )
    }
}

struct RDPGFXAVC420BitmapStream: Equatable, Sendable {
    var regionRects: [RDPGFXRect16]
    var quantQualityVals: [RDPGFXAVC420QuantQuality]
    var encodedBitstream: Data

    var nalUnitTypes: [UInt8] {
        RDPH264AnnexB.nalUnitTypes(from: encodedBitstream)
    }

    static func parse(from data: Data) throws -> RDPGFXAVC420BitmapStream {
        var cursor = ByteCursor(data)
        let regionCount = try cursor.readLittleEndianUInt32()
        guard regionCount <= UInt32(cursor.remaining / 10) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let count = Int(regionCount)
        var regionRects: [RDPGFXRect16] = []
        regionRects.reserveCapacity(count)
        for _ in 0 ..< count {
            try regionRects.append(RDPGFXRect16.parse(&cursor))
        }

        var quantQualityVals: [RDPGFXAVC420QuantQuality] = []
        quantQualityVals.reserveCapacity(count)
        for _ in 0 ..< count {
            try quantQualityVals.append(RDPGFXAVC420QuantQuality.parse(&cursor))
        }

        let encodedBitstream = cursor.readRemainingData()
        guard encodedBitstream.isEmpty == false else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXAVC420BitmapStream(
            regionRects: regionRects,
            quantQualityVals: quantQualityVals,
            encodedBitstream: encodedBitstream
        )
    }
}

enum RDPGFXAVC444LayoutCode: UInt8, Encodable, Equatable, Sendable {
    case yuv420AndChroma420 = 0
    case yuv420Only = 1
    case chroma420Only = 2

    var description: String {
        switch self {
        case .yuv420AndChroma420:
            "yuv420+chroma420"
        case .yuv420Only:
            "yuv420"
        case .chroma420Only:
            "chroma420"
        }
    }
}

struct RDPGFXAVC444BitmapStream: Equatable, Sendable {
    var layoutCode: RDPGFXAVC444LayoutCode
    var firstStreamByteCount: UInt32
    var firstStream: RDPGFXAVC420BitmapStream
    var secondStream: RDPGFXAVC420BitmapStream?

    var yuv420Stream: RDPGFXAVC420BitmapStream? {
        switch layoutCode {
        case .yuv420AndChroma420, .yuv420Only:
            firstStream
        case .chroma420Only:
            nil
        }
    }

    var chroma420Stream: RDPGFXAVC420BitmapStream? {
        switch layoutCode {
        case .yuv420AndChroma420:
            secondStream
        case .chroma420Only:
            firstStream
        case .yuv420Only:
            nil
        }
    }

    var nalUnitTypes: [UInt8] {
        var types = firstStream.nalUnitTypes
        if let secondStream {
            types.append(contentsOf: secondStream.nalUnitTypes)
        }
        return types
    }

    static func parse(from data: Data) throws -> RDPGFXAVC444BitmapStream {
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        let bitstreamInfo = try cursor.readLittleEndianUInt32()
        let firstStreamByteCount = bitstreamInfo & 0x3FFF_FFFF
        guard let layoutCode = RDPGFXAVC444LayoutCode(rawValue: UInt8(bitstreamInfo >> 30)) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let streamData = cursor.readRemainingData()
        switch layoutCode {
        case .yuv420AndChroma420:
            guard firstStreamByteCount > 0,
                  firstStreamByteCount <= UInt32(streamData.count)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let firstStreamEnd = Int(firstStreamByteCount)
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStreamByteCount: firstStreamByteCount,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: Data(streamData.prefix(firstStreamEnd))),
                secondStream: RDPGFXAVC420BitmapStream.parse(from: Data(streamData.dropFirst(firstStreamEnd)))
            )
        case .yuv420Only, .chroma420Only:
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStreamByteCount: firstStreamByteCount,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData),
                secondStream: nil
            )
        }
    }
}

struct RDPGFXResetGraphicsPDU: Equatable, Sendable {
    var width: UInt32
    var height: UInt32
    var monitorCount: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXResetGraphicsPDU {
        guard message.commandID == RDPGFXCommandID.resetGraphics,
              message.pduLength == 340
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXResetGraphicsPDU(
            width: cursor.readLittleEndianUInt32(),
            height: cursor.readLittleEndianUInt32(),
            monitorCount: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXCreateSurfacePDU: Equatable, Sendable {
    var surfaceID: UInt16
    var width: UInt16
    var height: UInt16
    var pixelFormat: UInt8

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXCreateSurfacePDU {
        guard message.commandID == RDPGFXCommandID.createSurface,
              message.payload.count == 7
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXCreateSurfacePDU(
            surfaceID: cursor.readLittleEndianUInt16(),
            width: cursor.readLittleEndianUInt16(),
            height: cursor.readLittleEndianUInt16(),
            pixelFormat: cursor.readUInt8()
        )
    }
}

struct RDPGFXMapSurfaceToOutputPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var outputOriginX: UInt32
    var outputOriginY: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXMapSurfaceToOutputPDU {
        guard message.commandID == RDPGFXCommandID.mapSurfaceToOutput,
              message.payload.count == 12
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        return try RDPGFXMapSurfaceToOutputPDU(
            surfaceID: surfaceID,
            outputOriginX: cursor.readLittleEndianUInt32(),
            outputOriginY: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXStartFramePDU: Equatable, Sendable {
    var timestamp: UInt32
    var frameID: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXStartFramePDU {
        guard message.commandID == RDPGFXCommandID.startFrame,
              message.payload.count == 8
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXStartFramePDU(
            timestamp: cursor.readLittleEndianUInt32(),
            frameID: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXEndFramePDU: Equatable, Sendable {
    var frameID: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXEndFramePDU {
        guard message.commandID == RDPGFXCommandID.endFrame,
              message.payload.count == 4
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXEndFramePDU(frameID: cursor.readLittleEndianUInt32())
    }
}

struct RDPGFXWireToSurface1PDU: Equatable, Sendable {
    var surfaceID: UInt16
    var codecID: UInt16
    var pixelFormat: UInt8
    var destinationRect: RDPGFXRect16
    var bitmapDataLength: UInt32
    var bitmapData: Data

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXWireToSurface1PDU {
        guard message.commandID == RDPGFXCommandID.wireToSurface1,
              message.payload.count >= 17
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let codecID = try cursor.readLittleEndianUInt16()
        let pixelFormat = try cursor.readUInt8()
        let destinationRect = try RDPGFXRect16.parse(&cursor)
        let bitmapDataLength = try cursor.readLittleEndianUInt32()
        guard bitmapDataLength == UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bitmapData = cursor.readRemainingData()

        return RDPGFXWireToSurface1PDU(
            surfaceID: surfaceID,
            codecID: codecID,
            pixelFormat: pixelFormat,
            destinationRect: destinationRect,
            bitmapDataLength: bitmapDataLength,
            bitmapData: bitmapData
        )
    }
}

struct RDPGFXWireToSurface2PDU: Equatable, Sendable {
    var surfaceID: UInt16
    var codecID: UInt16
    var codecContextID: UInt32
    var pixelFormat: UInt8
    var bitmapDataLength: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXWireToSurface2PDU {
        guard message.commandID == RDPGFXCommandID.wireToSurface2,
              message.payload.count >= 13
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let codecID = try cursor.readLittleEndianUInt16()
        let codecContextID = try cursor.readLittleEndianUInt32()
        let pixelFormat = try cursor.readUInt8()
        let bitmapDataLength = try cursor.readLittleEndianUInt32()
        guard bitmapDataLength == UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXWireToSurface2PDU(
            surfaceID: surfaceID,
            codecID: codecID,
            codecContextID: codecContextID,
            pixelFormat: pixelFormat,
            bitmapDataLength: bitmapDataLength
        )
    }
}

struct RDPGFXFrameAcknowledgePDU: Equatable, Sendable {
    var queueDepth: UInt32
    var frameID: UInt32
    var totalFramesDecoded: UInt32

    init(
        queueDepth: UInt32 = 0,
        frameID: UInt32,
        totalFramesDecoded: UInt32
    ) {
        self.queueDepth = queueDepth
        self.frameID = frameID
        self.totalFramesDecoded = totalFramesDecoded
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPGFXCommandID.frameAcknowledge)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(20)
        data.appendLittleEndianUInt32(queueDepth)
        data.appendLittleEndianUInt32(frameID)
        data.appendLittleEndianUInt32(totalFramesDecoded)
        return data
    }
}

public struct RDPGFXMessageSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var surfaceID: UInt16?
    public var width: UInt32?
    public var height: UInt32?
    public var pixelFormat: UInt8?
    public var codecID: UInt16?
    public var codecName: String?
    public var bitmapDataLength: UInt32?
    public var avc420RegionCount: Int?
    public var avc420EncodedBitstreamLength: Int?
    public var avc444Layout: String?
    public var avc444FirstStreamByteCount: UInt32?
    public var avc444YUV420RegionCount: Int?
    public var avc444YUV420EncodedBitstreamLength: Int?
    public var avc444Chroma420RegionCount: Int?
    public var avc444Chroma420EncodedBitstreamLength: Int?
    public var h264NalUnitTypes: [UInt8]?
    public var frameID: UInt32?
    public var outputOriginX: UInt32?
    public var outputOriginY: UInt32?

    static func summarize(
        _ message: RDPGFXHeader,
        includeVideoDetails: Bool = true
    ) throws -> RDPGFXMessageSummary {
        switch message.commandID {
        case RDPGFXCommandID.resetGraphics:
            let reset = try RDPGFXResetGraphicsPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                width: reset.width,
                height: reset.height
            )
        case RDPGFXCommandID.createSurface:
            let create = try RDPGFXCreateSurfacePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: create.surfaceID,
                width: UInt32(create.width),
                height: UInt32(create.height),
                pixelFormat: create.pixelFormat
            )
        case RDPGFXCommandID.mapSurfaceToOutput:
            let map = try RDPGFXMapSurfaceToOutputPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: map.surfaceID,
                outputOriginX: map.outputOriginX,
                outputOriginY: map.outputOriginY
            )
        case RDPGFXCommandID.startFrame:
            let startFrame = try RDPGFXStartFramePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                frameID: startFrame.frameID
            )
        case RDPGFXCommandID.endFrame:
            let endFrame = try RDPGFXEndFramePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                frameID: endFrame.frameID
            )
        case RDPGFXCommandID.wireToSurface1:
            let wire = try RDPGFXWireToSurface1PDU.parse(from: message)
            let avc420 = includeVideoDetails && wire.codecID == RDPGFXCodecID.avc420
                ? try? RDPGFXAVC420BitmapStream.parse(from: wire.bitmapData)
                : nil
            let avc444 = includeVideoDetails
                && (wire.codecID == RDPGFXCodecID.avc444 || wire.codecID == RDPGFXCodecID.avc444v2)
                ? try? RDPGFXAVC444BitmapStream.parse(from: wire.bitmapData)
                : nil
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: wire.surfaceID,
                pixelFormat: wire.pixelFormat,
                codecID: wire.codecID,
                codecName: RDPGFXCodecID.name(for: wire.codecID),
                bitmapDataLength: wire.bitmapDataLength,
                avc420RegionCount: avc420?.regionRects.count,
                avc420EncodedBitstreamLength: avc420?.encodedBitstream.count,
                avc444Layout: avc444?.layoutCode.description,
                avc444FirstStreamByteCount: avc444?.firstStreamByteCount,
                avc444YUV420RegionCount: avc444?.yuv420Stream?.regionRects.count,
                avc444YUV420EncodedBitstreamLength: avc444?.yuv420Stream?.encodedBitstream.count,
                avc444Chroma420RegionCount: avc444?.chroma420Stream?.regionRects.count,
                avc444Chroma420EncodedBitstreamLength: avc444?.chroma420Stream?.encodedBitstream.count,
                h264NalUnitTypes: includeVideoDetails ? avc420?.nalUnitTypes ?? avc444?.nalUnitTypes : nil
            )
        case RDPGFXCommandID.wireToSurface2:
            let wire = try RDPGFXWireToSurface2PDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: wire.surfaceID,
                pixelFormat: wire.pixelFormat,
                codecID: wire.codecID,
                codecName: RDPGFXCodecID.name(for: wire.codecID),
                bitmapDataLength: wire.bitmapDataLength
            )
        default:
            return RDPGFXMessageSummary(typeName: message.typeName)
        }
    }
}

enum RDPGFXServerTransport {
    static func decodeGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        guard let descriptor = data.first else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        switch descriptor {
        case 0xE0:
            var cursor = ByteCursor(data.dropFirst())
            return try splitGraphicsMessages(from: decodeRDP8BulkData(&cursor))
        case 0xE1:
            var cursor = ByteCursor(data.dropFirst())
            return try splitGraphicsMessages(from: decodeMultipartSegmentedData(&cursor))
        default:
            return try splitGraphicsMessages(from: data)
        }
    }

    private static func decodeMultipartSegmentedData(_ cursor: inout ByteCursor) throws -> Data {
        let segmentCount = try cursor.readLittleEndianUInt16()
        let uncompressedSize = try cursor.readLittleEndianUInt32()
        var data = Data()

        for _ in 0 ..< segmentCount {
            let segmentSize = try cursor.readLittleEndianUInt32()
            guard segmentSize > 0,
                  segmentSize <= UInt32(cursor.remaining)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            var segmentCursor = try ByteCursor(cursor.readData(count: Int(segmentSize)))
            try data.append(decodeRDP8BulkData(&segmentCursor))
        }

        guard data.count == Int(uncompressedSize) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return data
    }

    private static func decodeRDP8BulkData(_ cursor: inout ByteCursor) throws -> Data {
        let header = try cursor.readUInt8()
        let compressionType = header & 0x0F
        let isCompressed = header & 0x20 != 0
        guard compressionType == 0x04, !isCompressed else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return cursor.readRemainingData()
    }

    private static func splitGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        var messages: [RDPGFXHeader] = []
        var cursor = ByteCursor(data)

        while cursor.remaining > 0 {
            let message = try RDPGFXHeader.parse(from: &cursor)
            messages.append(message)
        }

        return messages
    }
}
