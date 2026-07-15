import Foundation

enum RDPGFXChannel {
    static let name = "Microsoft::Windows::RDS::Graphics"
}

enum RDPGFXCommandID {
    static let wireToSurface1: UInt16 = 0x0001
    static let wireToSurface2: UInt16 = 0x0002
    static let deleteEncodingContext: UInt16 = 0x0003
    static let solidFill: UInt16 = 0x0004
    static let surfaceToSurface: UInt16 = 0x0005
    static let surfaceToCache: UInt16 = 0x0006
    static let cacheToSurface: UInt16 = 0x0007
    static let evictCacheEntry: UInt16 = 0x0008
    static let createSurface: UInt16 = 0x0009
    static let deleteSurface: UInt16 = 0x000A
    static let startFrame: UInt16 = 0x000B
    static let endFrame: UInt16 = 0x000C
    static let frameAcknowledge: UInt16 = 0x000D
    static let resetGraphics: UInt16 = 0x000E
    static let mapSurfaceToOutput: UInt16 = 0x000F
    static let cacheImportOffer: UInt16 = 0x0010
    static let cacheImportReply: UInt16 = 0x0011
    static let capsAdvertise: UInt16 = 0x0012
    static let capsConfirm: UInt16 = 0x0013
    static let mapSurfaceToWindow: UInt16 = 0x0015
    static let qoeFrameAcknowledge: UInt16 = 0x0016
    static let mapSurfaceToScaledOutput: UInt16 = 0x0017
    static let mapSurfaceToScaledWindow: UInt16 = 0x0018

    static func requiresLogicalFrame(_ commandID: UInt16) -> Bool {
        switch commandID {
        case wireToSurface1,
             wireToSurface2,
             solidFill,
             surfaceToSurface,
             surfaceToCache,
             cacheToSurface:
            true
        default:
            false
        }
    }
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

    static func isValidWireToSurface1(_ codecID: UInt16) -> Bool {
        switch codecID {
        case uncompressed, cavideo, clearCodec, planar, avc420, alpha, avc444, avc444v2:
            true
        default:
            false
        }
    }

    static func isValidWireToSurface2(_ codecID: UInt16) -> Bool {
        codecID == caProgressive
    }

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
    static let version10: UInt32 = 0x000A_0002
    static let version101: UInt32 = 0x000A_0100
    static let version102: UInt32 = 0x000A_0200
    static let version103: UInt32 = 0x000A_0301
    static let version104: UInt32 = 0x000A_0400
    static let version105: UInt32 = 0x000A_0502
    static let version106: UInt32 = 0x000A_0600
    static let version107: UInt32 = 0x000A_0701
}

enum RDPGFXCapabilityFlags {
    static let thinClient: UInt32 = 0x0000_0001
    static let smallCache: UInt32 = 0x0000_0002
    static let avc420Enabled: UInt32 = 0x0000_0010
    static let avcDisabled: UInt32 = 0x0000_0020
    static let avcThinClient: UInt32 = 0x0000_0040
    static let scaledMapDisabled: UInt32 = 0x0000_0080
    static let defaultVersion8: UInt32 = smallCache
    static let defaultVersion81: UInt32 = smallCache | avc420Enabled
    static let defaultVersion10: UInt32 = smallCache
    static let defaultVersion102: UInt32 = smallCache
    static let defaultVersion103: UInt32 = avcThinClient
    static let defaultVersion104Through107: UInt32 = smallCache | avcThinClient
    static let defaultVersion107: UInt32 = smallCache | avcThinClient
}

enum RDPGFXPixelFormat {
    static let xrgb8888: UInt8 = 0x20
    static let argb8888: UInt8 = 0x21

    static func isValid(_ value: UInt8) -> Bool {
        value == xrgb8888 || value == argb8888
    }
}

enum RDPGFXCacheSlot {
    static let maximumSlot: UInt16 = 25_600
    static let smallCacheMaximumSlot: UInt16 = 4_096

    static func isValid(_ value: UInt16) -> Bool {
        value >= 1 && value <= maximumSlot
    }
}

enum RDPGFXBitmapCache {
    static let maximumByteCount = 100 * 1_024 * 1_024
    static let smallCacheMaximumByteCount = 16 * 1_024 * 1_024
}

public enum RDPGraphicsCapabilityProfile: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case automatic
    case avcThinClient
    case avc420
    case legacy

    public var displayName: String {
        switch self {
        case .automatic:
            "automatic"
        case .avcThinClient:
            "AVC thin client"
        case .avc420:
            "AVC420"
        case .legacy:
            "legacy bitmap"
        }
    }

    var capabilitySets: [RDPGFXCapabilitySet] {
        switch self {
        case .automatic:
            [
                .version107(flags: RDPGFXCapabilityFlags.defaultVersion107),
                .flagged(
                    version: RDPGFXCapabilityVersion.version106,
                    flags: RDPGFXCapabilityFlags.defaultVersion104Through107
                ),
                .flagged(
                    version: RDPGFXCapabilityVersion.version105,
                    flags: RDPGFXCapabilityFlags.defaultVersion104Through107
                ),
                .flagged(
                    version: RDPGFXCapabilityVersion.version104,
                    flags: RDPGFXCapabilityFlags.defaultVersion104Through107
                ),
                .flagged(
                    version: RDPGFXCapabilityVersion.version103,
                    flags: RDPGFXCapabilityFlags.defaultVersion103
                ),
                .flagged(
                    version: RDPGFXCapabilityVersion.version102,
                    flags: RDPGFXCapabilityFlags.defaultVersion102
                ),
                .version101(),
                .flagged(
                    version: RDPGFXCapabilityVersion.version10,
                    flags: RDPGFXCapabilityFlags.defaultVersion10
                ),
                .version81(flags: RDPGFXCapabilityFlags.defaultVersion81),
                .version8(flags: RDPGFXCapabilityFlags.defaultVersion8),
            ]
        case .avcThinClient:
            [
                .version107(flags: RDPGFXCapabilityFlags.defaultVersion107),
            ]
        case .avc420:
            [
                .version81(flags: RDPGFXCapabilityFlags.defaultVersion81),
            ]
        case .legacy:
            [
                .version8(flags: RDPGFXCapabilityFlags.defaultVersion8),
            ]
        }
    }
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
        case RDPGFXCommandID.deleteEncodingContext:
            "rdpgfx-delete-encoding-context"
        case RDPGFXCommandID.solidFill:
            "rdpgfx-solid-fill"
        case RDPGFXCommandID.surfaceToSurface:
            "rdpgfx-surface-to-surface"
        case RDPGFXCommandID.surfaceToCache:
            "rdpgfx-surface-to-cache"
        case RDPGFXCommandID.cacheToSurface:
            "rdpgfx-cache-to-surface"
        case RDPGFXCommandID.evictCacheEntry:
            "rdpgfx-evict-cache-entry"
        case RDPGFXCommandID.createSurface:
            "rdpgfx-create-surface"
        case RDPGFXCommandID.deleteSurface:
            "rdpgfx-delete-surface"
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
        case RDPGFXCommandID.cacheImportOffer:
            "rdpgfx-cache-import-offer"
        case RDPGFXCommandID.cacheImportReply:
            "rdpgfx-cache-import-reply"
        case RDPGFXCommandID.capsAdvertise:
            "rdpgfx-caps-advertise"
        case RDPGFXCommandID.capsConfirm:
            "rdpgfx-caps-confirm"
        case RDPGFXCommandID.mapSurfaceToWindow:
            "rdpgfx-map-surface-to-window"
        case RDPGFXCommandID.qoeFrameAcknowledge:
            "rdpgfx-qoe-frame-acknowledge"
        case RDPGFXCommandID.mapSurfaceToScaledOutput:
            "rdpgfx-map-surface-to-scaled-output"
        case RDPGFXCommandID.mapSurfaceToScaledWindow:
            "rdpgfx-map-surface-to-scaled-window"
        default:
            "rdpgfx-0x\(String(format: "%04x", commandID))"
        }
    }

    static func parse(from data: Data) throws -> RDPGFXHeader {
        guard data.count >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        let header = try parse(from: &cursor)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return header
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPGFXHeader {
        guard cursor.remaining >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let commandID = try cursor.readLittleEndianUInt16()
        let flags = try cursor.readLittleEndianUInt16()
        let pduLength = try cursor.readLittleEndianUInt32()
        guard flags == 0,
              pduLength >= 8,
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

struct RDPGFXLogicalFrameTracker: Equatable, Sendable {
    private(set) var activeFrameID: UInt32?

    mutating func shouldProcess(_ message: RDPGFXHeader) throws -> Bool {
        switch message.commandID {
        case RDPGFXCommandID.startFrame:
            guard activeFrameID == nil else {
                return false
            }
            activeFrameID = try RDPGFXStartFramePDU.parse(from: message).frameID
            return true

        case RDPGFXCommandID.endFrame:
            let frameID = try RDPGFXEndFramePDU.parse(from: message).frameID
            guard frameID == activeFrameID else {
                return false
            }
            activeFrameID = nil
            return true

        default:
            return !RDPGFXCommandID.requiresLogicalFrame(message.commandID)
                || activeFrameID != nil
        }
    }
}

struct RDPGFXCapabilitySet: Equatable, Sendable {
    var version: UInt32
    var data: Data

    init(version: UInt32, data: Data) {
        precondition(data.count <= Int(UInt32.max))
        if let expectedDataLength = Self.expectedDataLength(for: version) {
            precondition(data.count == expectedDataLength)
        }

        self.version = version
        self.data = data
    }

    static func version81(flags: UInt32) -> RDPGFXCapabilitySet {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        return RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version81, data: data)
    }

    static func version107(flags: UInt32) -> RDPGFXCapabilitySet {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        return RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version107, data: data)
    }

    static func version8(flags: UInt32) -> RDPGFXCapabilitySet {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        return RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version8, data: data)
    }

    static func flagged(version: UInt32, flags: UInt32) -> RDPGFXCapabilitySet {
        precondition(version != RDPGFXCapabilityVersion.version101)
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        return RDPGFXCapabilitySet(version: version, data: data)
    }

    static func version101() -> RDPGFXCapabilitySet {
        RDPGFXCapabilitySet(
            version: RDPGFXCapabilityVersion.version101,
            data: Data(repeating: 0, count: 16)
        )
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
        let remainingDataLength = cursor.remaining
        let capabilityData = try cursor.readData(count: remainingDataLength)
        guard dataLength == UInt32(remainingDataLength),
              isValidData(version: version, data: capabilityData)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXCapabilitySet(
            version: version,
            data: capabilityData
        )
    }

    static func validated(version: UInt32, data: Data) throws -> RDPGFXCapabilitySet {
        guard isValidData(version: version, data: data) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXCapabilitySet(version: version, data: data)
    }

    static func isKnownVersion(_ version: UInt32) -> Bool {
        expectedDataLength(for: version) != nil
    }

    private static func expectedDataLength(for version: UInt32) -> Int? {
        switch version {
        case RDPGFXCapabilityVersion.version8,
             RDPGFXCapabilityVersion.version81,
             RDPGFXCapabilityVersion.version10,
             RDPGFXCapabilityVersion.version102,
             RDPGFXCapabilityVersion.version103,
             RDPGFXCapabilityVersion.version104,
             RDPGFXCapabilityVersion.version105,
             RDPGFXCapabilityVersion.version106,
             RDPGFXCapabilityVersion.version107:
            4
        case RDPGFXCapabilityVersion.version101:
            16
        default:
            nil
        }
    }

    private static func isValidDataLength(_ dataLength: UInt32, for version: UInt32) -> Bool {
        guard let expectedDataLength = expectedDataLength(for: version) else {
            return true
        }
        return dataLength == UInt32(expectedDataLength)
    }

    private static func isValidData(version: UInt32, data: Data) -> Bool {
        guard isValidDataLength(UInt32(data.count), for: version) else {
            return false
        }
        switch version {
        case RDPGFXCapabilityVersion.version101:
            return data.allSatisfy { $0 == 0 }
        case RDPGFXCapabilityVersion.version8:
            guard let flags = data.littleEndianUInt32IfPresent(at: 0) else {
                return false
            }
            return flags & ~(RDPGFXCapabilityFlags.thinClient | RDPGFXCapabilityFlags.smallCache) == 0
        case RDPGFXCapabilityVersion.version81:
            guard let flags = data.littleEndianUInt32IfPresent(at: 0) else {
                return false
            }
            return flags & ~(RDPGFXCapabilityFlags.thinClient
                | RDPGFXCapabilityFlags.smallCache
                | RDPGFXCapabilityFlags.avc420Enabled) == 0
        case RDPGFXCapabilityVersion.version10,
             RDPGFXCapabilityVersion.version102:
            guard let flags = data.littleEndianUInt32IfPresent(at: 0) else {
                return false
            }
            return flags & ~(RDPGFXCapabilityFlags.smallCache | RDPGFXCapabilityFlags.avcDisabled) == 0
        case RDPGFXCapabilityVersion.version103,
             RDPGFXCapabilityVersion.version104,
             RDPGFXCapabilityVersion.version105,
             RDPGFXCapabilityVersion.version106,
             RDPGFXCapabilityVersion.version107:
            guard let flags = data.littleEndianUInt32IfPresent(at: 0) else {
                return false
            }
            guard flags & ~allowedFlags(for: version) == 0 else {
                return false
            }
            let incompatibleAVCFlags = RDPGFXCapabilityFlags.avcDisabled
                | RDPGFXCapabilityFlags.avcThinClient
            return flags & incompatibleAVCFlags != incompatibleAVCFlags
        default:
            return true
        }
    }

    private static func allowedFlags(for version: UInt32) -> UInt32 {
        switch version {
        case RDPGFXCapabilityVersion.version103:
            RDPGFXCapabilityFlags.avcDisabled | RDPGFXCapabilityFlags.avcThinClient
        case RDPGFXCapabilityVersion.version104,
             RDPGFXCapabilityVersion.version105,
             RDPGFXCapabilityVersion.version106:
            RDPGFXCapabilityFlags.smallCache
                | RDPGFXCapabilityFlags.avcDisabled
                | RDPGFXCapabilityFlags.avcThinClient
        case RDPGFXCapabilityVersion.version107:
            RDPGFXCapabilityFlags.smallCache
                | RDPGFXCapabilityFlags.avcDisabled
                | RDPGFXCapabilityFlags.avcThinClient
                | RDPGFXCapabilityFlags.scaledMapDisabled
        default:
            UInt32.max
        }
    }
}

private extension Data {
    func littleEndianUInt32IfPresent(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else {
            return nil
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

struct RDPGFXCapsAdvertisePDU: Equatable, Sendable {
    var capabilitySets: [RDPGFXCapabilitySet]

    init(capabilitySets: [RDPGFXCapabilitySet] = RDPGraphicsCapabilityProfile.automatic.capabilitySets) {
        precondition(!capabilitySets.isEmpty)
        precondition(capabilitySets.count <= Int(UInt16.max))
        precondition(Set(capabilitySets.map(\.version)).count == capabilitySets.count)

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

    static func parseIfPresent(from data: Data) throws -> RDPGFXCapsAdvertisePDU? {
        let header = try RDPGFXHeader.parse(from: data)
        guard header.commandID == RDPGFXCommandID.capsAdvertise else {
            return nil
        }

        var cursor = ByteCursor(header.payload)
        let capabilitySetCount = try Int(cursor.readLittleEndianUInt16())
        var capabilitySets: [RDPGFXCapabilitySet] = []
        capabilitySets.reserveCapacity(capabilitySetCount)
        for _ in 0 ..< capabilitySetCount {
            guard cursor.remaining >= 8 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }

            let version = try cursor.readLittleEndianUInt32()
            let dataLength = try cursor.readLittleEndianUInt32()
            guard dataLength <= UInt32(cursor.remaining) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let data = try cursor.readData(count: Int(dataLength))
            guard RDPGFXCapabilitySet.isKnownVersion(version) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            capabilitySets.append(try RDPGFXCapabilitySet.validated(version: version, data: data))
        }
        guard cursor.remaining == 0,
              !capabilitySets.isEmpty,
              Set(capabilitySets.map(\.version)).count == capabilitySets.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXCapsAdvertisePDU(capabilitySets: capabilitySets)
    }
}

struct RDPGFXCapsConfirmPDU: Equatable, Sendable {
    var capabilitySet: RDPGFXCapabilitySet

    static func parseIfPresent(from data: Data) throws -> RDPGFXCapsConfirmPDU? {
        let header = try RDPGFXHeader.parse(from: data)
        return try parse(from: header)
    }

    static func parse(from header: RDPGFXHeader) throws -> RDPGFXCapsConfirmPDU? {
        guard header.commandID == RDPGFXCommandID.capsConfirm else {
            return nil
        }

        let capabilitySet = try RDPGFXCapabilitySet.parse(from: header.payload)
        guard RDPGFXCapabilitySet.isKnownVersion(capabilitySet.version) else {
            return nil
        }
        return RDPGFXCapsConfirmPDU(capabilitySet: capabilitySet)
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

struct RDPGFXPoint16: Encodable, Equatable, Sendable {
    var x: Int16
    var y: Int16

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXPoint16 {
        try RDPGFXPoint16(
            x: Int16(bitPattern: cursor.readLittleEndianUInt16()),
            y: Int16(bitPattern: cursor.readLittleEndianUInt16())
        )
    }
}

struct RDPGFXColor32: Encodable, Equatable, Sendable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8

    var rgbHexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    var bgraData: Data {
        Data([blue, green, red, alpha])
    }

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXColor32 {
        try RDPGFXColor32(
            blue: cursor.readUInt8(),
            green: cursor.readUInt8(),
            red: cursor.readUInt8(),
            alpha: cursor.readUInt8()
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
    var isProgressive: Bool
    var qualityVal: UInt8

    init(qpVal: UInt8, isProgressive: Bool = false, qualityVal: UInt8) {
        precondition(qpVal <= 51)
        precondition(qualityVal <= 100)

        self.qpVal = qpVal
        self.isProgressive = isProgressive
        self.qualityVal = qualityVal
    }

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXAVC420QuantQuality {
        let qpAndProgressive = try cursor.readUInt8()
        let qualityVal = try cursor.readUInt8()
        guard qpAndProgressive & 0x3F <= 51, qualityVal <= 100 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXAVC420QuantQuality(
            qpVal: qpAndProgressive & 0x3F,
            isProgressive: qpAndProgressive & 0x80 != 0,
            qualityVal: qualityVal
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
        case .yuv420Only:
            guard firstStreamByteCount == UInt32(streamData.count) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStreamByteCount: firstStreamByteCount,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData),
                secondStream: nil
            )
        case .chroma420Only:
            guard firstStreamByteCount == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStreamByteCount: firstStreamByteCount,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData),
                secondStream: nil
            )
        }
    }
}

struct RDPGFXAlphaBitmapStream: Equatable, Sendable {
    private static let alphaSignature: UInt16 = 0x414C

    var compressed: Bool
    var alphaValues: Data

    static func parse(from data: Data, pixelCount: Int) throws -> RDPGFXAlphaBitmapStream {
        guard pixelCount >= 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(data)
        guard cursor.remaining >= 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let alphaSignature = try cursor.readLittleEndianUInt16()
        let compressed = try cursor.readLittleEndianUInt16()
        guard alphaSignature == Self.alphaSignature else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        if compressed == 0 {
            let alphaValues = cursor.readRemainingData()
            guard alphaValues.count == pixelCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return RDPGFXAlphaBitmapStream(compressed: false, alphaValues: alphaValues)
        }

        var alphaValues: [UInt8] = []
        alphaValues.reserveCapacity(pixelCount)
        while cursor.remaining > 0 {
            let runValue = try cursor.readUInt8()
            let runLength = try readRunLength(&cursor)
            guard UInt64(alphaValues.count) + UInt64(runLength) <= UInt64(pixelCount) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            alphaValues.append(contentsOf: repeatElement(runValue, count: runLength))
        }
        guard alphaValues.count == pixelCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXAlphaBitmapStream(compressed: true, alphaValues: Data(alphaValues))
    }

    private static func readRunLength(_ cursor: inout ByteCursor) throws -> Int {
        let firstFactor = try cursor.readUInt8()
        guard firstFactor == 0xFF else {
            return Int(firstFactor)
        }

        let secondFactor = try cursor.readLittleEndianUInt16()
        guard secondFactor == 0xFFFF else {
            return Int(secondFactor)
        }

        let thirdFactor = try cursor.readLittleEndianUInt32()
        guard UInt64(thirdFactor) <= UInt64(Int.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return Int(thirdFactor)
    }
}

struct RDPGFXMonitorDefinition: Equatable, Sendable {
    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32
    var flags: UInt32

    static func parse(from cursor: inout ByteCursor) throws -> RDPGFXMonitorDefinition {
        RDPGFXMonitorDefinition(
            left: Int32(bitPattern: try cursor.readLittleEndianUInt32()),
            top: Int32(bitPattern: try cursor.readLittleEndianUInt32()),
            right: Int32(bitPattern: try cursor.readLittleEndianUInt32()),
            bottom: Int32(bitPattern: try cursor.readLittleEndianUInt32()),
            flags: try cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXResetGraphicsPDU: Equatable, Sendable {
    static let maximumDimension: UInt32 = 32_766
    static let maximumMonitorCount: UInt32 = 16

    var width: UInt32
    var height: UInt32
    var monitorDefinitions: [RDPGFXMonitorDefinition]

    var monitorCount: UInt32 {
        UInt32(monitorDefinitions.count)
    }

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXResetGraphicsPDU {
        guard message.commandID == RDPGFXCommandID.resetGraphics,
              message.pduLength == 340
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let width = try cursor.readLittleEndianUInt32()
        let height = try cursor.readLittleEndianUInt32()
        let monitorCount = try cursor.readLittleEndianUInt32()
        guard width <= maximumDimension,
              height <= maximumDimension,
              monitorCount <= maximumMonitorCount,
              cursor.remaining >= Int(monitorCount) * 20
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var monitorDefinitions: [RDPGFXMonitorDefinition] = []
        monitorDefinitions.reserveCapacity(Int(monitorCount))
        for _ in 0 ..< Int(monitorCount) {
            monitorDefinitions.append(try RDPGFXMonitorDefinition.parse(from: &cursor))
        }

        return RDPGFXResetGraphicsPDU(
            width: width,
            height: height,
            monitorDefinitions: monitorDefinitions
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
        let surfaceID = try cursor.readLittleEndianUInt16()
        let width = try cursor.readLittleEndianUInt16()
        let height = try cursor.readLittleEndianUInt16()
        let pixelFormat = try cursor.readUInt8()
        guard RDPGFXPixelFormat.isValid(pixelFormat) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXCreateSurfacePDU(
            surfaceID: surfaceID,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }
}

struct RDPGFXDeleteSurfacePDU: Equatable, Sendable {
    var surfaceID: UInt16

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXDeleteSurfacePDU {
        guard message.commandID == RDPGFXCommandID.deleteSurface,
              message.payload.count == 2
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXDeleteSurfacePDU(surfaceID: cursor.readLittleEndianUInt16())
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
        let reserved = try cursor.readLittleEndianUInt16()
        guard reserved == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let outputOriginX = try cursor.readLittleEndianUInt32()
        let outputOriginY = try cursor.readLittleEndianUInt32()
        return RDPGFXMapSurfaceToOutputPDU(
            surfaceID: surfaceID,
            outputOriginX: outputOriginX,
            outputOriginY: outputOriginY
        )
    }
}

struct RDPGFXMapSurfaceToScaledOutputPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var outputOriginX: UInt32
    var outputOriginY: UInt32
    var targetWidth: UInt32
    var targetHeight: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXMapSurfaceToScaledOutputPDU {
        guard message.commandID == RDPGFXCommandID.mapSurfaceToScaledOutput,
              message.payload.count == 20
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let reserved = try cursor.readLittleEndianUInt16()
        guard reserved == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try RDPGFXMapSurfaceToScaledOutputPDU(
            surfaceID: surfaceID,
            outputOriginX: cursor.readLittleEndianUInt32(),
            outputOriginY: cursor.readLittleEndianUInt32(),
            targetWidth: cursor.readLittleEndianUInt32(),
            targetHeight: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXMapSurfaceToWindowPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var windowID: UInt64
    var mappedWidth: UInt32
    var mappedHeight: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXMapSurfaceToWindowPDU {
        guard message.commandID == RDPGFXCommandID.mapSurfaceToWindow,
              message.payload.count == 18
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXMapSurfaceToWindowPDU(
            surfaceID: cursor.readLittleEndianUInt16(),
            windowID: cursor.readLittleEndianUInt64(),
            mappedWidth: cursor.readLittleEndianUInt32(),
            mappedHeight: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXMapSurfaceToScaledWindowPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var windowID: UInt64
    var mappedWidth: UInt32
    var mappedHeight: UInt32
    var targetWidth: UInt32
    var targetHeight: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXMapSurfaceToScaledWindowPDU {
        guard message.commandID == RDPGFXCommandID.mapSurfaceToScaledWindow,
              message.payload.count == 26
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXMapSurfaceToScaledWindowPDU(
            surfaceID: cursor.readLittleEndianUInt16(),
            windowID: cursor.readLittleEndianUInt64(),
            mappedWidth: cursor.readLittleEndianUInt32(),
            mappedHeight: cursor.readLittleEndianUInt32(),
            targetWidth: cursor.readLittleEndianUInt32(),
            targetHeight: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXSolidFillPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var fillPixel: RDPGFXColor32
    var fillRects: [RDPGFXRect16]

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXSolidFillPDU {
        guard message.commandID == RDPGFXCommandID.solidFill,
              message.payload.count >= 8
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let fillPixel = try RDPGFXColor32.parse(&cursor)
        let rectCount = try cursor.readLittleEndianUInt16()
        guard cursor.remaining == Int(rectCount) * 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var fillRects: [RDPGFXRect16] = []
        fillRects.reserveCapacity(Int(rectCount))
        for _ in 0 ..< Int(rectCount) {
            try fillRects.append(RDPGFXRect16.parse(&cursor))
        }

        return RDPGFXSolidFillPDU(
            surfaceID: surfaceID,
            fillPixel: fillPixel,
            fillRects: fillRects
        )
    }
}

struct RDPGFXSurfaceToSurfacePDU: Equatable, Sendable {
    var sourceSurfaceID: UInt16
    var destinationSurfaceID: UInt16
    var sourceRect: RDPGFXRect16
    var destinationPoints: [RDPGFXPoint16]

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXSurfaceToSurfacePDU {
        guard message.commandID == RDPGFXCommandID.surfaceToSurface,
              message.payload.count >= 14
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let sourceSurfaceID = try cursor.readLittleEndianUInt16()
        let destinationSurfaceID = try cursor.readLittleEndianUInt16()
        let sourceRect = try RDPGFXRect16.parse(&cursor)
        let destinationPointCount = try cursor.readLittleEndianUInt16()
        guard cursor.remaining == Int(destinationPointCount) * 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var destinationPoints: [RDPGFXPoint16] = []
        destinationPoints.reserveCapacity(Int(destinationPointCount))
        for _ in 0 ..< Int(destinationPointCount) {
            try destinationPoints.append(RDPGFXPoint16.parse(&cursor))
        }

        return RDPGFXSurfaceToSurfacePDU(
            sourceSurfaceID: sourceSurfaceID,
            destinationSurfaceID: destinationSurfaceID,
            sourceRect: sourceRect,
            destinationPoints: destinationPoints
        )
    }
}

struct RDPGFXSurfaceToCachePDU: Equatable, Sendable {
    var surfaceID: UInt16
    var cacheKey: UInt64
    var cacheSlot: UInt16
    var sourceRect: RDPGFXRect16

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXSurfaceToCachePDU {
        guard message.commandID == RDPGFXCommandID.surfaceToCache,
              message.payload.count == 20
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let cacheKey = try cursor.readLittleEndianUInt64()
        let cacheSlot = try cursor.readLittleEndianUInt16()
        guard RDPGFXCacheSlot.isValid(cacheSlot) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let sourceRect = try RDPGFXRect16.parse(&cursor)

        return RDPGFXSurfaceToCachePDU(
            surfaceID: surfaceID,
            cacheKey: cacheKey,
            cacheSlot: cacheSlot,
            sourceRect: sourceRect
        )
    }
}

struct RDPGFXCacheToSurfacePDU: Equatable, Sendable {
    var cacheSlot: UInt16
    var surfaceID: UInt16
    var destinationPoints: [RDPGFXPoint16]

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXCacheToSurfacePDU {
        guard message.commandID == RDPGFXCommandID.cacheToSurface,
              message.payload.count >= 6
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let cacheSlot = try cursor.readLittleEndianUInt16()
        guard RDPGFXCacheSlot.isValid(cacheSlot) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let surfaceID = try cursor.readLittleEndianUInt16()
        let destinationPointCount = try cursor.readLittleEndianUInt16()
        guard cursor.remaining == Int(destinationPointCount) * 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var destinationPoints: [RDPGFXPoint16] = []
        destinationPoints.reserveCapacity(Int(destinationPointCount))
        for _ in 0 ..< Int(destinationPointCount) {
            try destinationPoints.append(RDPGFXPoint16.parse(&cursor))
        }

        return RDPGFXCacheToSurfacePDU(
            cacheSlot: cacheSlot,
            surfaceID: surfaceID,
            destinationPoints: destinationPoints
        )
    }
}

struct RDPGFXEvictCacheEntryPDU: Equatable, Sendable {
    var cacheSlot: UInt16

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXEvictCacheEntryPDU {
        guard message.commandID == RDPGFXCommandID.evictCacheEntry,
              message.payload.count == 2
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let cacheSlot = try cursor.readLittleEndianUInt16()
        guard RDPGFXCacheSlot.isValid(cacheSlot) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXEvictCacheEntryPDU(cacheSlot: cacheSlot)
    }
}

struct RDPGFXCacheImportReplyPDU: Equatable, Sendable {
    var cacheSlots: [UInt16]

    var importedEntriesCount: UInt16 {
        UInt16(cacheSlots.count)
    }

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXCacheImportReplyPDU {
        guard message.commandID == RDPGFXCommandID.cacheImportReply,
              message.payload.count >= 2
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let importedEntriesCount = try cursor.readLittleEndianUInt16()
        guard cursor.remaining == Int(importedEntriesCount) * 2 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cacheSlots: [UInt16] = []
        cacheSlots.reserveCapacity(Int(importedEntriesCount))
        for _ in 0 ..< Int(importedEntriesCount) {
            let cacheSlot = try cursor.readLittleEndianUInt16()
            guard RDPGFXCacheSlot.isValid(cacheSlot) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            cacheSlots.append(cacheSlot)
        }

        return RDPGFXCacheImportReplyPDU(cacheSlots: cacheSlots)
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
        let timestamp = try cursor.readLittleEndianUInt32()
        guard isValidTimestamp(timestamp) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try RDPGFXStartFramePDU(
            timestamp: timestamp,
            frameID: cursor.readLittleEndianUInt32()
        )
    }

    private static func isValidTimestamp(_ timestamp: UInt32) -> Bool {
        let milliseconds = timestamp & 0x03FF
        let seconds = (timestamp >> 10) & 0x003F
        let minutes = (timestamp >> 16) & 0x003F
        let hours = (timestamp >> 22) & 0x03FF
        return milliseconds <= 999
            && seconds <= 59
            && minutes <= 59
            && hours <= 23
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
        guard RDPGFXCodecID.isValidWireToSurface1(codecID) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let pixelFormat = try cursor.readUInt8()
        guard RDPGFXPixelFormat.isValid(pixelFormat) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
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

struct RDPGFXDeleteEncodingContextPDU: Equatable, Sendable {
    var surfaceID: UInt16
    var codecContextID: UInt32

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXDeleteEncodingContextPDU {
        guard message.commandID == RDPGFXCommandID.deleteEncodingContext,
              message.payload.count == 6
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        return try RDPGFXDeleteEncodingContextPDU(
            surfaceID: cursor.readLittleEndianUInt16(),
            codecContextID: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXWireToSurface2PDU: Equatable, Sendable {
    var surfaceID: UInt16
    var codecID: UInt16
    var codecContextID: UInt32
    var pixelFormat: UInt8
    var bitmapDataLength: UInt32
    var bitmapData: Data

    static func parse(from message: RDPGFXHeader) throws -> RDPGFXWireToSurface2PDU {
        guard message.commandID == RDPGFXCommandID.wireToSurface2,
              message.payload.count >= 13
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let surfaceID = try cursor.readLittleEndianUInt16()
        let codecID = try cursor.readLittleEndianUInt16()
        guard RDPGFXCodecID.isValidWireToSurface2(codecID) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let codecContextID = try cursor.readLittleEndianUInt32()
        let pixelFormat = try cursor.readUInt8()
        guard RDPGFXPixelFormat.isValid(pixelFormat) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bitmapDataLength = try cursor.readLittleEndianUInt32()
        guard bitmapDataLength == UInt32(cursor.remaining) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bitmapData = cursor.readRemainingData()

        return RDPGFXWireToSurface2PDU(
            surfaceID: surfaceID,
            codecID: codecID,
            codecContextID: codecContextID,
            pixelFormat: pixelFormat,
            bitmapDataLength: bitmapDataLength,
            bitmapData: bitmapData
        )
    }
}

private enum RDPGFXProgressiveBlockType {
    static let sync: UInt16 = 0xCCC0
    static let frameBegin: UInt16 = 0xCCC1
    static let frameEnd: UInt16 = 0xCCC2
    static let context: UInt16 = 0xCCC3
    static let region: UInt16 = 0xCCC4
    static let tileSimple: UInt16 = 0xCCC5
    static let tileFirst: UInt16 = 0xCCC6
    static let tileUpgrade: UInt16 = 0xCCC7

    static func name(for blockType: UInt16) -> String {
        switch blockType {
        case sync:
            "sync"
        case frameBegin:
            "frame-begin"
        case frameEnd:
            "frame-end"
        case context:
            "context"
        case region:
            "region"
        case tileSimple:
            "tile-simple"
        case tileFirst:
            "tile-first"
        case tileUpgrade:
            "tile-upgrade"
        default:
            "block-0x\(String(format: "%04x", blockType))"
        }
    }
}

private struct RDPGFXProgressiveBitmapStreamSummary: Equatable, Sendable {
    var blockTypes: [UInt16] = []
    var blockTypeNames: [String] = []
    var contextIDs: [UInt8] = []
    var contextTileSizes: [UInt16] = []
    var contextFlags: [UInt8] = []
    var frameIndexes: [UInt32] = []
    var frameRegionCounts: [UInt16] = []
    var regionCount = 0
    var regionRectCount = 0
    var regionRects: [RDPFrameRect] = []
    var regionTileCount = 0
    var tileSimpleCount = 0
    var tileFirstCount = 0
    var tileUpgradeCount = 0

    static func summarize(_ data: Data) throws -> RDPGFXProgressiveBitmapStreamSummary {
        var cursor = ByteCursor(data)
        var summary = RDPGFXProgressiveBitmapStreamSummary()
        while cursor.remaining > 0 {
            guard cursor.remaining >= 6 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let blockType = try cursor.readLittleEndianUInt16()
            let blockLength = try cursor.readLittleEndianUInt32()
            guard blockLength >= 6,
                  UInt64(blockLength - 6) <= UInt64(cursor.remaining)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let body = try cursor.readData(count: Int(blockLength - 6))
            summary.blockTypes.append(blockType)
            summary.blockTypeNames.append(RDPGFXProgressiveBlockType.name(for: blockType))

            switch blockType {
            case RDPGFXProgressiveBlockType.sync:
                try parseSync(body)
            case RDPGFXProgressiveBlockType.context:
                try summary.parseContext(body)
            case RDPGFXProgressiveBlockType.frameBegin:
                try summary.parseFrameBegin(body)
            case RDPGFXProgressiveBlockType.frameEnd:
                guard body.isEmpty else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
            case RDPGFXProgressiveBlockType.region:
                try summary.parseRegion(body)
            case RDPGFXProgressiveBlockType.tileSimple,
                 RDPGFXProgressiveBlockType.tileFirst,
                 RDPGFXProgressiveBlockType.tileUpgrade:
                throw RDPDecodeError.invalidRDPGFXPDU
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
        return summary
    }

    private static func parseSync(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 6,
              try cursor.readLittleEndianUInt32() == 0xCACC_ACCA,
              try cursor.readLittleEndianUInt16() == 0x0100
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private mutating func parseContext(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let contextID = try cursor.readUInt8()
        let tileSize = try cursor.readLittleEndianUInt16()
        let flags = try cursor.readUInt8()
        guard tileSize == 64 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        contextIDs.append(contextID)
        contextTileSizes.append(tileSize)
        contextFlags.append(flags)
    }

    private mutating func parseFrameBegin(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        frameIndexes.append(try cursor.readLittleEndianUInt32())
        frameRegionCounts.append(try cursor.readLittleEndianUInt16())
    }

    private mutating func parseRegion(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 12 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let tileSize = try cursor.readUInt8()
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        let quantCount = try Int(cursor.readUInt8())
        let progressiveQuantCount = try Int(cursor.readUInt8())
        _ = try cursor.readUInt8()
        let tileCount = try Int(cursor.readLittleEndianUInt16())
        let tileDataSize = try Int(cursor.readLittleEndianUInt32())
        guard tileSize == 64,
              rectangleCount > 0,
              quantCount <= 7
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let metadataByteCount = rectangleCount * 8 + quantCount * 5 + progressiveQuantCount * 16
        guard cursor.remaining == metadataByteCount + tileDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        regionCount += 1
        regionRectCount += rectangleCount
        for _ in 0 ..< rectangleCount {
            let x = try cursor.readLittleEndianUInt16()
            let y = try cursor.readLittleEndianUInt16()
            let width = try cursor.readLittleEndianUInt16()
            let height = try cursor.readLittleEndianUInt16()
            guard UInt32(x) + UInt32(width) <= UInt32(UInt16.max),
                  UInt32(y) + UInt32(height) <= UInt32(UInt16.max)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            regionRects.append(RDPFrameRect(
                left: x,
                top: y,
                right: x + width,
                bottom: y + height
            ))
        }
        _ = try cursor.readData(count: quantCount * 5)
        _ = try cursor.readData(count: progressiveQuantCount * 16)
        try parseRegionTiles(
            cursor.readRemainingData(),
            expectedTileCount: tileCount
        )
    }

    private mutating func parseRegionTiles(_ data: Data, expectedTileCount: Int) throws {
        var cursor = ByteCursor(data)
        var parsedTileCount = 0
        while cursor.remaining > 0 {
            guard cursor.remaining >= 6 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let blockType = try cursor.readLittleEndianUInt16()
            let blockLength = try cursor.readLittleEndianUInt32()
            guard blockLength >= 6,
                  UInt64(blockLength - 6) <= UInt64(cursor.remaining)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let tileBody = try cursor.readData(count: Int(blockLength - 6))
            switch blockType {
            case RDPGFXProgressiveBlockType.tileSimple:
                try Self.parseSimpleOrFirstTile(tileBody, hasQuality: false)
                tileSimpleCount += 1
            case RDPGFXProgressiveBlockType.tileFirst:
                try Self.parseSimpleOrFirstTile(tileBody, hasQuality: true)
                tileFirstCount += 1
            case RDPGFXProgressiveBlockType.tileUpgrade:
                try Self.parseUpgradeTile(tileBody)
                tileUpgradeCount += 1
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            parsedTileCount += 1
        }
        guard parsedTileCount == expectedTileCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        regionTileCount += parsedTileCount
    }

    private static func parseSimpleOrFirstTile(_ data: Data, hasQuality: Bool) throws {
        var cursor = ByteCursor(data)
        let headerByteCount = hasQuality ? 17 : 16
        guard cursor.remaining >= headerByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        _ = try cursor.readUInt8()
        if hasQuality {
            _ = try cursor.readUInt8()
        }
        let yByteCount = try Int(cursor.readLittleEndianUInt16())
        let cbByteCount = try Int(cursor.readLittleEndianUInt16())
        let crByteCount = try Int(cursor.readLittleEndianUInt16())
        let tailByteCount = try Int(cursor.readLittleEndianUInt16())
        guard cursor.remaining == yByteCount + cbByteCount + crByteCount + tailByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseUpgradeTile(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        _ = try cursor.readUInt8()
        let ySRLByteCount = try Int(cursor.readLittleEndianUInt16())
        let yRawByteCount = try Int(cursor.readLittleEndianUInt16())
        let cbSRLByteCount = try Int(cursor.readLittleEndianUInt16())
        let cbRawByteCount = try Int(cursor.readLittleEndianUInt16())
        let crSRLByteCount = try Int(cursor.readLittleEndianUInt16())
        let crRawByteCount = try Int(cursor.readLittleEndianUInt16())
        let componentByteCount = ySRLByteCount + yRawByteCount
            + cbSRLByteCount + cbRawByteCount
            + crSRLByteCount + crRawByteCount
        guard cursor.remaining == componentByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }
}

private enum RDPGFXCAVideoBlockType {
    static let tile: UInt16 = 0xCAC3
    static let sync: UInt16 = 0xCCC0
    static let codecVersions: UInt16 = 0xCCC1
    static let channels: UInt16 = 0xCCC2
    static let context: UInt16 = 0xCCC3
    static let frameBegin: UInt16 = 0xCCC4
    static let frameEnd: UInt16 = 0xCCC5
    static let region: UInt16 = 0xCCC6
    static let tileSet: UInt16 = 0xCCC7

    static func name(for blockType: UInt16) -> String {
        switch blockType {
        case tile:
            "tile"
        case sync:
            "sync"
        case codecVersions:
            "codec-versions"
        case channels:
            "channels"
        case context:
            "context"
        case frameBegin:
            "frame-begin"
        case frameEnd:
            "frame-end"
        case region:
            "region"
        case tileSet:
            "tile-set"
        default:
            "block-0x\(String(format: "%04x", blockType))"
        }
    }

    static func isChannelBlock(_ blockType: UInt16) -> Bool {
        switch blockType {
        case context, frameBegin, frameEnd, region, tileSet:
            true
        default:
            false
        }
    }
}

private struct RDPGFXCAVideoBitmapStreamSummary: Equatable, Sendable {
    var blockTypes: [UInt16] = []
    var blockTypeNames: [String] = []
    var channelWidths: [UInt16] = []
    var channelHeights: [UInt16] = []
    var contextEntropyAlgorithms: [String] = []
    var tileSetEntropyAlgorithms: [String] = []
    var frameIndexes: [UInt32] = []
    var frameRegionCounts: [UInt16] = []
    var regionCount = 0
    var regionRectCount = 0
    var regionRects: [RDPFrameRect] = []
    var tileCount = 0
    var tileRects: [RDPFrameRect] = []
    var tileDataByteCount = 0

    static func summarize(_ data: Data) throws -> RDPGFXCAVideoBitmapStreamSummary {
        var cursor = ByteCursor(data)
        var summary = RDPGFXCAVideoBitmapStreamSummary()
        while cursor.remaining > 0 {
            try summary.parseBlock(from: &cursor, topLevel: true)
        }
        return summary
    }

    private mutating func parseBlock(from cursor: inout ByteCursor, topLevel: Bool) throws {
        guard cursor.remaining >= 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let blockType = try cursor.readLittleEndianUInt16()
        let blockLength = try cursor.readLittleEndianUInt32()
        guard blockLength >= 6,
              UInt64(blockLength - 6) <= UInt64(cursor.remaining)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        blockTypes.append(blockType)
        blockTypeNames.append(RDPGFXCAVideoBlockType.name(for: blockType))

        var bodyCursor = ByteCursor(try cursor.readData(count: Int(blockLength - 6)))
        if RDPGFXCAVideoBlockType.isChannelBlock(blockType) {
            let channelID = try Self.parseCodecChannelHeader(&bodyCursor)
            switch blockType {
            case RDPGFXCAVideoBlockType.context:
                guard channelID == 0xFF else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
            default:
                guard channelID == 0 else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
            }
        }

        switch blockType {
        case RDPGFXCAVideoBlockType.sync:
            try Self.parseSync(&bodyCursor)
        case RDPGFXCAVideoBlockType.codecVersions:
            try Self.parseCodecVersions(&bodyCursor)
        case RDPGFXCAVideoBlockType.channels:
            try parseChannels(&bodyCursor)
        case RDPGFXCAVideoBlockType.context:
            try parseContext(&bodyCursor)
        case RDPGFXCAVideoBlockType.frameBegin:
            try parseFrameBegin(&bodyCursor)
        case RDPGFXCAVideoBlockType.frameEnd:
            guard bodyCursor.remaining == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        case RDPGFXCAVideoBlockType.region:
            try parseRegion(&bodyCursor)
        case RDPGFXCAVideoBlockType.tileSet:
            try parseTileSet(&bodyCursor)
        case RDPGFXCAVideoBlockType.tile where !topLevel:
            try parseTile(&bodyCursor)
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        guard bodyCursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func entropyAlgorithmName(_ bits: UInt16) -> String {
        switch bits {
        case 0x01:
            "rlgr1"
        case 0x04:
            "rlgr3"
        default:
            "entropy-0x\(String(format: "%x", bits))"
        }
    }

    private static func parseCodecChannelHeader(_ cursor: inout ByteCursor) throws -> UInt8 {
        guard cursor.remaining >= 2,
              try cursor.readUInt8() == 1
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try cursor.readUInt8()
    }

    private static func parseSync(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining == 6,
              try cursor.readLittleEndianUInt32() == 0xCACC_ACCA,
              try cursor.readLittleEndianUInt16() == 0x0100
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseCodecVersions(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let codecCount = try Int(cursor.readUInt8())
        guard cursor.remaining == codecCount * 3 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for _ in 0 ..< codecCount {
            guard try cursor.readUInt8() == 1,
                  try cursor.readLittleEndianUInt16() == 0x0100
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
    }

    private mutating func parseChannels(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let channelCount = try Int(cursor.readUInt8())
        guard cursor.remaining == channelCount * 5 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for _ in 0 ..< channelCount {
            guard try cursor.readUInt8() == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            channelWidths.append(try cursor.readLittleEndianUInt16())
            channelHeights.append(try cursor.readLittleEndianUInt16())
        }
    }

    private mutating func parseContext(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining == 5,
              try cursor.readUInt8() == 0,
              try cursor.readLittleEndianUInt16() == 64
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let properties = try cursor.readLittleEndianUInt16()
        let entropy = (properties >> 9) & 0x0F
        contextEntropyAlgorithms.append(Self.entropyAlgorithmName(entropy))
    }

    private mutating func parseFrameBegin(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        frameIndexes.append(try cursor.readLittleEndianUInt32())
        frameRegionCounts.append(try cursor.readLittleEndianUInt16())
    }

    private mutating func parseRegion(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining >= 7,
              try cursor.readUInt8() & 0x01 == 0x01
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        guard cursor.remaining >= rectangleCount * 8 + 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        regionCount += 1
        regionRectCount += rectangleCount
        for _ in 0 ..< rectangleCount {
            let x = try cursor.readLittleEndianUInt16()
            let y = try cursor.readLittleEndianUInt16()
            let width = try cursor.readLittleEndianUInt16()
            let height = try cursor.readLittleEndianUInt16()
            guard UInt32(x) + UInt32(width) <= UInt32(UInt16.max),
                  UInt32(y) + UInt32(height) <= UInt32(UInt16.max)
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            regionRects.append(RDPFrameRect(
                left: x,
                top: y,
                right: x + width,
                bottom: y + height
            ))
        }
        guard try cursor.readLittleEndianUInt16() == 0xCAC1,
              try cursor.readLittleEndianUInt16() == 1
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private mutating func parseTileSet(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining >= 14,
              try cursor.readLittleEndianUInt16() == 0xCAC2,
              try cursor.readLittleEndianUInt16() == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let properties = try cursor.readLittleEndianUInt16()
        let entropy = (properties >> 10) & 0x0F
        tileSetEntropyAlgorithms.append(Self.entropyAlgorithmName(entropy))
        let quantCount = try Int(cursor.readUInt8())
        guard try cursor.readUInt8() == 64 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let expectedTileCount = try Int(cursor.readLittleEndianUInt16())
        let tilesDataSize = try Int(cursor.readLittleEndianUInt32())
        guard cursor.remaining == quantCount * 5 + tilesDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readData(count: quantCount * 5)

        var tileCursor = ByteCursor(try cursor.readData(count: tilesDataSize))
        let startTileCount = tileCount
        while tileCursor.remaining > 0 {
            try parseBlock(from: &tileCursor, topLevel: false)
        }
        guard tileCount - startTileCount == expectedTileCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private mutating func parseTile(_ cursor: inout ByteCursor) throws {
        guard cursor.remaining >= 13 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        _ = try cursor.readUInt8()
        let xIndex = try cursor.readLittleEndianUInt16()
        let yIndex = try cursor.readLittleEndianUInt16()
        let yByteCount = try Int(cursor.readLittleEndianUInt16())
        let cbByteCount = try Int(cursor.readLittleEndianUInt16())
        let crByteCount = try Int(cursor.readLittleEndianUInt16())
        let componentByteCount = yByteCount + cbByteCount + crByteCount
        guard cursor.remaining == componentByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readData(count: componentByteCount)

        let left = UInt32(xIndex) * 64
        let top = UInt32(yIndex) * 64
        guard left + 64 <= UInt32(UInt16.max),
              top + 64 <= UInt32(UInt16.max)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        tileCount += 1
        tileDataByteCount += componentByteCount
        tileRects.append(RDPFrameRect(
            left: UInt16(left),
            top: UInt16(top),
            right: UInt16(left + 64),
            bottom: UInt16(top + 64)
        ))
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

struct RDPGFXQoEFrameAcknowledgePDU: Equatable, Sendable {
    var frameID: UInt32
    var timestamp: UInt32
    var timeDiffSE: UInt16
    var timeDiffEDR: UInt16

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPGFXCommandID.qoeFrameAcknowledge)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(20)
        data.appendLittleEndianUInt32(frameID)
        data.appendLittleEndianUInt32(timestamp)
        data.appendLittleEndianUInt16(timeDiffSE)
        data.appendLittleEndianUInt16(timeDiffEDR)
        return data
    }
}

public struct RDPGFXMessageSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var surfaceID: UInt16?
    public var width: UInt32?
    public var height: UInt32?
    public var monitorCount: UInt32?
    public var pixelFormat: UInt8?
    public var codecID: UInt16?
    public var codecName: String?
    public var codecContextID: UInt32?
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
    public var clearCodecFlags: UInt8?
    public var clearCodecSequenceNumber: UInt8?
    public var clearCodecGlyphIndex: UInt16?
    public var clearCodecResidualByteCount: UInt32?
    public var clearCodecBandsByteCount: UInt32?
    public var clearCodecSubcodecByteCount: UInt32?
    public var clearCodecSubcodecIDs: [UInt8]?
    public var clearCodecSubcodecRects: [RDPFrameRect]?
    public var clearCodecSubcodecByteCounts: [UInt32]?
    public var clearCodecNSCodecYByteCounts: [UInt32?]?
    public var clearCodecNSCodecCoByteCounts: [UInt32?]?
    public var clearCodecNSCodecCgByteCounts: [UInt32?]?
    public var clearCodecNSCodecAlphaByteCounts: [UInt32?]?
    public var clearCodecNSCodecColorLossLevels: [UInt8?]?
    public var clearCodecNSCodecChromaSubsamplingLevels: [UInt8?]?
    public var cavideoBlockTypes: [UInt16]?
    public var cavideoBlockTypeNames: [String]?
    public var cavideoChannelWidths: [UInt16]?
    public var cavideoChannelHeights: [UInt16]?
    public var cavideoContextEntropyAlgorithms: [String]?
    public var cavideoTileSetEntropyAlgorithms: [String]?
    public var cavideoFrameIndexes: [UInt32]?
    public var cavideoFrameRegionCounts: [UInt16]?
    public var cavideoRegionCount: Int?
    public var cavideoRegionRectCount: Int?
    public var cavideoRegionRects: [RDPFrameRect]?
    public var cavideoTileCount: Int?
    public var cavideoTileRects: [RDPFrameRect]?
    public var cavideoTileDataByteCount: Int?
    public var progressiveBlockTypes: [UInt16]?
    public var progressiveBlockTypeNames: [String]?
    public var progressiveContextIDs: [UInt8]?
    public var progressiveContextTileSizes: [UInt16]?
    public var progressiveContextFlags: [UInt8]?
    public var progressiveFrameIndexes: [UInt32]?
    public var progressiveFrameRegionCounts: [UInt16]?
    public var progressiveRegionCount: Int?
    public var progressiveRegionRectCount: Int?
    public var progressiveRegionRects: [RDPFrameRect]?
    public var progressiveRegionTileCount: Int?
    public var progressiveTileSimpleCount: Int?
    public var progressiveTileFirstCount: Int?
    public var progressiveTileUpgradeCount: Int?
    public var frameID: UInt32?
    public var outputOriginX: UInt32?
    public var outputOriginY: UInt32?
    public var targetWidth: UInt32?
    public var targetHeight: UInt32?
    public var windowID: UInt64?
    public var mappedWidth: UInt32?
    public var mappedHeight: UInt32?
    public var fillColor: String?
    public var fillRectCount: Int?
    public var sourceSurfaceID: UInt16?
    public var sourceRect: RDPFrameRect?
    public var cacheKey: UInt64?
    public var cacheSlot: UInt16?
    public var importedEntriesCount: Int?
    public var destinationPointCount: Int?

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
                height: reset.height,
                monitorCount: reset.monitorCount
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
        case RDPGFXCommandID.deleteSurface:
            let delete = try RDPGFXDeleteSurfacePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: delete.surfaceID
            )
        case RDPGFXCommandID.mapSurfaceToOutput:
            let map = try RDPGFXMapSurfaceToOutputPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: map.surfaceID,
                outputOriginX: map.outputOriginX,
                outputOriginY: map.outputOriginY
            )
        case RDPGFXCommandID.mapSurfaceToScaledOutput:
            let map = try RDPGFXMapSurfaceToScaledOutputPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: map.surfaceID,
                outputOriginX: map.outputOriginX,
                outputOriginY: map.outputOriginY,
                targetWidth: map.targetWidth,
                targetHeight: map.targetHeight
            )
        case RDPGFXCommandID.mapSurfaceToWindow:
            let map = try RDPGFXMapSurfaceToWindowPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: map.surfaceID,
                windowID: map.windowID,
                mappedWidth: map.mappedWidth,
                mappedHeight: map.mappedHeight
            )
        case RDPGFXCommandID.mapSurfaceToScaledWindow:
            let map = try RDPGFXMapSurfaceToScaledWindowPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: map.surfaceID,
                targetWidth: map.targetWidth,
                targetHeight: map.targetHeight,
                windowID: map.windowID,
                mappedWidth: map.mappedWidth,
                mappedHeight: map.mappedHeight
            )
        case RDPGFXCommandID.solidFill:
            let solidFill = try RDPGFXSolidFillPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: solidFill.surfaceID,
                fillColor: solidFill.fillPixel.rgbHexString,
                fillRectCount: solidFill.fillRects.count
            )
        case RDPGFXCommandID.surfaceToSurface:
            let surfaceToSurface = try RDPGFXSurfaceToSurfacePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: surfaceToSurface.destinationSurfaceID,
                sourceSurfaceID: surfaceToSurface.sourceSurfaceID,
                sourceRect: RDPFrameRect(surfaceToSurface.sourceRect),
                destinationPointCount: surfaceToSurface.destinationPoints.count
            )
        case RDPGFXCommandID.surfaceToCache:
            let surfaceToCache = try RDPGFXSurfaceToCachePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: surfaceToCache.surfaceID,
                sourceRect: RDPFrameRect(surfaceToCache.sourceRect),
                cacheKey: surfaceToCache.cacheKey,
                cacheSlot: surfaceToCache.cacheSlot
            )
        case RDPGFXCommandID.cacheToSurface:
            let cacheToSurface = try RDPGFXCacheToSurfacePDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: cacheToSurface.surfaceID,
                cacheSlot: cacheToSurface.cacheSlot,
                destinationPointCount: cacheToSurface.destinationPoints.count
            )
        case RDPGFXCommandID.evictCacheEntry:
            let evict = try RDPGFXEvictCacheEntryPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                cacheSlot: evict.cacheSlot
            )
        case RDPGFXCommandID.cacheImportReply:
            let reply = try RDPGFXCacheImportReplyPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                importedEntriesCount: reply.cacheSlots.count
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
        case RDPGFXCommandID.deleteEncodingContext:
            let delete = try RDPGFXDeleteEncodingContextPDU.parse(from: message)
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: delete.surfaceID,
                codecContextID: delete.codecContextID
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
            let clearCodec = wire.codecID == RDPGFXCodecID.clearCodec
                ? try? RDPClearCodecDecoder.summarize(wire.bitmapData)
                : nil
            let cavideo = includeVideoDetails && wire.codecID == RDPGFXCodecID.cavideo
                ? try? RDPGFXCAVideoBitmapStreamSummary.summarize(wire.bitmapData)
                : nil
            if wire.codecID == RDPGFXCodecID.alpha {
                _ = try RDPGFXAlphaBitmapStream.parse(
                    from: wire.bitmapData,
                    pixelCount: Int(wire.destinationRect.width) * Int(wire.destinationRect.height)
                )
            }
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
                h264NalUnitTypes: includeVideoDetails ? avc420?.nalUnitTypes ?? avc444?.nalUnitTypes : nil,
                clearCodecFlags: clearCodec?.flags,
                clearCodecSequenceNumber: clearCodec?.sequenceNumber,
                clearCodecGlyphIndex: clearCodec?.glyphIndex,
                clearCodecResidualByteCount: clearCodec?.residualByteCount,
                clearCodecBandsByteCount: clearCodec?.bandsByteCount,
                clearCodecSubcodecByteCount: clearCodec?.subcodecByteCount,
                clearCodecSubcodecIDs: clearCodec?.subcodecRegions.map(\.codecID),
                clearCodecSubcodecRects: clearCodec?.subcodecRegions.map(\.rect),
                clearCodecSubcodecByteCounts: clearCodec?.subcodecRegions.map(\.byteCount),
                clearCodecNSCodecYByteCounts: clearCodec?.subcodecRegions.map(\.nsCodecYByteCount),
                clearCodecNSCodecCoByteCounts: clearCodec?.subcodecRegions.map(\.nsCodecCoByteCount),
                clearCodecNSCodecCgByteCounts: clearCodec?.subcodecRegions.map(\.nsCodecCgByteCount),
                clearCodecNSCodecAlphaByteCounts: clearCodec?.subcodecRegions.map(\.nsCodecAlphaByteCount),
                clearCodecNSCodecColorLossLevels: clearCodec?.subcodecRegions.map(\.nsCodecColorLossLevel),
                clearCodecNSCodecChromaSubsamplingLevels: clearCodec?.subcodecRegions.map(\.nsCodecChromaSubsamplingLevel),
                cavideoBlockTypes: cavideo?.blockTypes,
                cavideoBlockTypeNames: cavideo?.blockTypeNames,
                cavideoChannelWidths: cavideo?.channelWidths,
                cavideoChannelHeights: cavideo?.channelHeights,
                cavideoContextEntropyAlgorithms: cavideo?.contextEntropyAlgorithms,
                cavideoTileSetEntropyAlgorithms: cavideo?.tileSetEntropyAlgorithms,
                cavideoFrameIndexes: cavideo?.frameIndexes,
                cavideoFrameRegionCounts: cavideo?.frameRegionCounts,
                cavideoRegionCount: cavideo?.regionCount,
                cavideoRegionRectCount: cavideo?.regionRectCount,
                cavideoRegionRects: cavideo?.regionRects,
                cavideoTileCount: cavideo?.tileCount,
                cavideoTileRects: cavideo?.tileRects,
                cavideoTileDataByteCount: cavideo?.tileDataByteCount
            )
        case RDPGFXCommandID.wireToSurface2:
            let wire = try RDPGFXWireToSurface2PDU.parse(from: message)
            let progressive = wire.codecID == RDPGFXCodecID.caProgressive
                ? try? RDPGFXProgressiveBitmapStreamSummary.summarize(wire.bitmapData)
                : nil
            return RDPGFXMessageSummary(
                typeName: message.typeName,
                surfaceID: wire.surfaceID,
                pixelFormat: wire.pixelFormat,
                codecID: wire.codecID,
                codecName: RDPGFXCodecID.name(for: wire.codecID),
                codecContextID: wire.codecContextID,
                bitmapDataLength: wire.bitmapDataLength,
                progressiveBlockTypes: progressive?.blockTypes,
                progressiveBlockTypeNames: progressive?.blockTypeNames,
                progressiveContextIDs: progressive?.contextIDs,
                progressiveContextTileSizes: progressive?.contextTileSizes,
                progressiveContextFlags: progressive?.contextFlags,
                progressiveFrameIndexes: progressive?.frameIndexes,
                progressiveFrameRegionCounts: progressive?.frameRegionCounts,
                progressiveRegionCount: progressive?.regionCount,
                progressiveRegionRectCount: progressive?.regionRectCount,
                progressiveRegionRects: progressive?.regionRects,
                progressiveRegionTileCount: progressive?.regionTileCount,
                progressiveTileSimpleCount: progressive?.tileSimpleCount,
                progressiveTileFirstCount: progressive?.tileFirstCount,
                progressiveTileUpgradeCount: progressive?.tileUpgradeCount
            )
        default:
            return RDPGFXMessageSummary(typeName: message.typeName)
        }
    }
}

final class RDPGFXServerTransportDecoder {
    private let zgfx = RDPZGFXDecompressor()

    func decodeGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        try RDPGFXServerTransport.decodeGraphicsMessages(from: data, zgfx: zgfx)
    }
}

enum RDPGFXServerTransport {
    static func decodeGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        try decodeGraphicsMessages(from: data, zgfx: RDPZGFXDecompressor())
    }

    fileprivate static func decodeGraphicsMessages(
        from data: Data,
        zgfx: RDPZGFXDecompressor
    ) throws -> [RDPGFXHeader] {
        guard let descriptor = data.first else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        switch descriptor {
        case 0xE0, 0xE1:
            return try splitGraphicsMessages(from: zgfx.decompress(data))
        default:
            return try splitGraphicsMessages(from: data)
        }
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
