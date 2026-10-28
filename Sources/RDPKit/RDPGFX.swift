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
            Self.automaticCapabilitySets
        case .avcThinClient:
            [.version107(flags: RDPGFXCapabilityFlags.defaultVersion107)]
        case .avc420:
            [.version81(flags: RDPGFXCapabilityFlags.defaultVersion81)]
        case .legacy:
            [.version8(flags: RDPGFXCapabilityFlags.defaultVersion8)]
        }
    }

    private static let automaticCapabilitySets: [RDPGFXCapabilitySet] = {
        typealias Version = RDPGFXCapabilityVersion
        typealias Flags = RDPGFXCapabilityFlags
        return [
            RDPGFXCapabilitySet(version: Version.version107, flags: Flags.defaultVersion107),
            RDPGFXCapabilitySet(version: Version.version106, flags: Flags.defaultVersion107),
            RDPGFXCapabilitySet(version: Version.version105, flags: Flags.defaultVersion107),
            RDPGFXCapabilitySet(version: Version.version104, flags: Flags.defaultVersion107),
            // 10.3 has no SMALL_CACHE flag; selecting it always implies the 16 MB cache.
            RDPGFXCapabilitySet(version: Version.version103, flags: Flags.avcThinClient),
            RDPGFXCapabilitySet(version: Version.version102, flags: Flags.smallCache),
            .version101,
            RDPGFXCapabilitySet(version: Version.version10, flags: Flags.smallCache),
            RDPGFXCapabilitySet(version: Version.version81, flags: Flags.defaultVersion81),
            RDPGFXCapabilitySet(version: Version.version8, flags: Flags.defaultVersion8),
        ]
    }()
}

struct RDPGFXHeader: Equatable, Sendable {
    var commandID: UInt16
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

    static func encoded(commandID: UInt16, payload: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(commandID)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(UInt32(8 + payload.count))
        data.append(payload)
        return data
    }

    static func parse(from data: Data) throws -> RDPGFXHeader {
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
        let pduLength = try Int(cursor.readLittleEndianUInt32())
        guard flags == 0,
              pduLength >= 8,
              pduLength - 8 <= cursor.remaining
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try RDPGFXHeader(commandID: commandID, payload: cursor.readData(count: pduLength - 8))
    }
}

/// Tracks the frameId of the logical frame being received. A StartFrame inside an
/// open frame starts a new one; nothing is dropped, so every EndFrame is
/// acknowledged with its own frameId (MS-RDPEGFX 3.3.5.12).
struct RDPGFXLogicalFrameTracker: Equatable, Sendable {
    private(set) var activeFrameID: UInt32?

    mutating func track(_ message: RDPGFXHeader) throws {
        switch message.commandID {
        case RDPGFXCommandID.startFrame:
            activeFrameID = try RDPGFXStartFramePDU.parse(from: message).frameID
        case RDPGFXCommandID.endFrame:
            activeFrameID = nil
        default:
            break
        }
    }

    /// Always true; kept until ConnectionPreflight calls `track(_:)`.
    mutating func shouldProcess(_ message: RDPGFXHeader) throws -> Bool {
        try track(message)
        return true
    }
}

struct RDPGFXCapabilitySet: Equatable, Sendable {
    /// RDPGFX_CAPSET_VERSION101 carries 16 reserved bytes instead of flags.
    static let version101 = RDPGFXCapabilitySet(
        version: RDPGFXCapabilityVersion.version101,
        data: Data(count: 16)
    )

    var version: UInt32
    var data: Data

    init(version: UInt32, data: Data) {
        precondition(Self.expectedDataLength(for: version).map { $0 == data.count } ?? true)
        self.version = version
        self.data = data
    }

    init(version: UInt32, flags: UInt32) {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        self.init(version: version, data: data)
    }

    static func version8(flags: UInt32) -> RDPGFXCapabilitySet {
        RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version8, flags: flags)
    }

    static func version81(flags: UInt32) -> RDPGFXCapabilitySet {
        RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version81, flags: flags)
    }

    static func version107(flags: UInt32) -> RDPGFXCapabilitySet {
        RDPGFXCapabilitySet(version: RDPGFXCapabilityVersion.version107, flags: flags)
    }

    var encoded: Data {
        var bytes = Data()
        bytes.appendLittleEndianUInt32(version)
        bytes.appendLittleEndianUInt32(UInt32(data.count))
        bytes.append(data)
        return bytes
    }

    var flags: UInt32? {
        guard version != RDPGFXCapabilityVersion.version101 else {
            return nil
        }
        var cursor = ByteCursor(data)
        return try? cursor.readLittleEndianUInt32()
    }

    static func parse(from data: Data) throws -> RDPGFXCapabilitySet {
        var cursor = ByteCursor(data)
        let capabilitySet = try parse(from: &cursor)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return capabilitySet
    }

    /// Validates the versions MS-RDPEGFX 2.2.3 defines; other versions are returned
    /// as is so callers can ignore or reject them.
    static func parse(from cursor: inout ByteCursor) throws -> RDPGFXCapabilitySet {
        guard cursor.remaining >= 8 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let version = try cursor.readLittleEndianUInt32()
        let dataLength = try Int(cursor.readLittleEndianUInt32())
        guard dataLength <= cursor.remaining else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let data = try cursor.readData(count: dataLength)
        guard isValid(version: version, data: data) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXCapabilitySet(version: version, data: data)
    }

    static func isKnownVersion(_ version: UInt32) -> Bool {
        expectedDataLength(for: version) != nil
    }

    private static func expectedDataLength(for version: UInt32) -> Int? {
        if version == RDPGFXCapabilityVersion.version101 {
            return 16
        }
        return definedFlags(for: version) == nil ? nil : 4
    }

    private static func definedFlags(for version: UInt32) -> UInt32? {
        typealias Flags = RDPGFXCapabilityFlags
        switch version {
        case RDPGFXCapabilityVersion.version8:
            return Flags.thinClient | Flags.smallCache
        case RDPGFXCapabilityVersion.version81:
            return Flags.thinClient | Flags.smallCache | Flags.avc420Enabled
        case RDPGFXCapabilityVersion.version10,
             RDPGFXCapabilityVersion.version102:
            return Flags.smallCache | Flags.avcDisabled
        case RDPGFXCapabilityVersion.version103:
            return Flags.avcDisabled | Flags.avcThinClient
        case RDPGFXCapabilityVersion.version104,
             RDPGFXCapabilityVersion.version105,
             RDPGFXCapabilityVersion.version106:
            return Flags.smallCache | Flags.avcDisabled | Flags.avcThinClient
        case RDPGFXCapabilityVersion.version107:
            return Flags.smallCache | Flags.avcDisabled | Flags.avcThinClient | Flags.scaledMapDisabled
        default:
            return nil
        }
    }

    private static func isValid(version: UInt32, data: Data) -> Bool {
        guard let expectedDataLength = expectedDataLength(for: version) else {
            return true
        }
        guard data.count == expectedDataLength else {
            return false
        }
        guard let definedFlags = definedFlags(for: version) else {
            return data.allSatisfy { $0 == 0 }
        }
        var cursor = ByteCursor(data)
        guard let flags = try? cursor.readLittleEndianUInt32() else {
            return false
        }
        // AVC_THINCLIENT and AVC_DISABLED MUST NOT be set together (MS-RDPEGFX 2.2.3.6).
        let avcFlags = RDPGFXCapabilityFlags.avcDisabled | RDPGFXCapabilityFlags.avcThinClient
        return flags & ~definedFlags == 0 && flags & avcFlags != avcFlags
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
        var payload = Data()
        payload.appendLittleEndianUInt16(UInt16(capabilitySets.count))
        for capabilitySet in capabilitySets {
            payload.append(capabilitySet.encoded)
        }
        return RDPGFXHeader.encoded(commandID: RDPGFXCommandID.capsAdvertise, payload: payload)
    }

    /// Capability sets with versions MS-RDPEGFX 2.2.3 does not define are skipped, as
    /// a server selecting among them does (MS-RDPEGFX 3.2.5.19).
    static func parseIfPresent(from data: Data) throws -> RDPGFXCapsAdvertisePDU? {
        let header = try RDPGFXHeader.parse(from: data)
        guard header.commandID == RDPGFXCommandID.capsAdvertise else {
            return nil
        }

        var cursor = ByteCursor(header.payload)
        guard cursor.remaining >= 2 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let capabilitySetCount = try cursor.readLittleEndianUInt16()
        var capabilitySets: [RDPGFXCapabilitySet] = []
        for _ in 0 ..< capabilitySetCount {
            let capabilitySet = try RDPGFXCapabilitySet.parse(from: &cursor)
            if RDPGFXCapabilitySet.isKnownVersion(capabilitySet.version) {
                capabilitySets.append(capabilitySet)
            }
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

    /// Returns nil for other commands. A capability set with an unknown version is
    /// returned so the caller can reject it as one the client did not advertise.
    static func parse(from header: RDPGFXHeader) throws -> RDPGFXCapsConfirmPDU? {
        guard header.commandID == RDPGFXCommandID.capsConfirm else {
            return nil
        }
        return try RDPGFXCapsConfirmPDU(capabilitySet: RDPGFXCapabilitySet.parse(from: header.payload))
    }
}

struct RDPGFXRect16: Equatable, Sendable {
    var left: UInt16
    var top: UInt16
    var right: UInt16
    var bottom: UInt16

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

struct RDPGFXPoint16: Equatable, Sendable {
    var x: Int16
    var y: Int16

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXPoint16 {
        try RDPGFXPoint16(
            x: Int16(bitPattern: cursor.readLittleEndianUInt16()),
            y: Int16(bitPattern: cursor.readLittleEndianUInt16())
        )
    }
}

struct RDPGFXColor32: Equatable, Sendable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8

    static func parse(_ cursor: inout ByteCursor) throws -> RDPGFXColor32 {
        try RDPGFXColor32(
            blue: cursor.readUInt8(),
            green: cursor.readUInt8(),
            red: cursor.readUInt8(),
            alpha: cursor.readUInt8()
        )
    }
}

/// Reads a counted array that MUST fill the rest of the PDU.
private func parseTrailingArray<Element>(
    count: UInt16,
    elementByteCount: Int,
    from cursor: inout ByteCursor,
    _ parseElement: (inout ByteCursor) throws -> Element
) throws -> [Element] {
    guard cursor.remaining == Int(count) * elementByteCount else {
        throw RDPDecodeError.invalidRDPGFXPDU
    }
    var elements: [Element] = []
    elements.reserveCapacity(Int(count))
    for _ in 0 ..< count {
        try elements.append(parseElement(&cursor))
    }
    return elements
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
    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        RDPAnnexB.nalUnitTypes(from: data, codec: .h264)
    }

    public static func sample(from data: Data) -> RDPH264AnnexBSample {
        let sample = RDPAnnexB.lengthPrefixedSample(from: data, codec: .h264)
        return RDPH264AnnexBSample(
            lengthPrefixedData: sample.data,
            sequenceParameterSet: sample.parameterSets[7],
            pictureParameterSet: sample.parameterSets[8]
        )
    }
}

public enum RDPHEVCAnnexB {
    public static func nalUnitTypes(from data: Data) -> [UInt8] {
        RDPAnnexB.nalUnitTypes(from: data, codec: .hevc)
    }

    public static func sample(from data: Data) -> RDPHEVCAnnexBSample {
        let sample = RDPAnnexB.lengthPrefixedSample(from: data, codec: .hevc)
        return RDPHEVCAnnexBSample(
            lengthPrefixedData: sample.data,
            videoParameterSet: sample.parameterSets[32],
            sequenceParameterSet: sample.parameterSets[33],
            pictureParameterSet: sample.parameterSets[34]
        )
    }
}

/// Splits ITU-T H.264/H.265 Annex B byte streams at their start codes.
enum RDPAnnexB {
    enum Codec {
        case h264
        case hevc

        /// NAL units shorter than their header are skipped.
        var headerByteCount: Int {
            self == .h264 ? 1 : 2
        }

        var parameterSetTypes: [UInt8] {
            self == .h264 ? [7, 8] : [32, 33, 34]
        }

        func nalUnitType(_ firstHeaderByte: UInt8) -> UInt8 {
            self == .h264 ? firstHeaderByte & 0x1F : (firstHeaderByte >> 1) & 0x3F
        }
    }

    static func nalUnitTypes(from data: Data, codec: Codec) -> [UInt8] {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return nalUnitPayloadRanges(in: bytes, codec: codec).map { range in
                codec.nalUnitType(bytes[range.lowerBound])
            }
        }
    }

    /// Converts NAL units to the 4-byte big-endian length-prefixed form, keeping the
    /// first payload of each parameter-set NAL unit type.
    static func lengthPrefixedSample(
        from data: Data,
        codec: Codec
    ) -> (data: Data, parameterSets: [UInt8: Data]) {
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            let ranges = nalUnitPayloadRanges(in: bytes, codec: codec)
            var lengthPrefixedData = Data()
            lengthPrefixedData.reserveCapacity(ranges.reduce(0) { $0 + 4 + $1.count })
            var parameterSets: [UInt8: Data] = [:]
            for range in ranges {
                let payload = UnsafeBufferPointer(rebasing: bytes[range])
                let type = codec.nalUnitType(payload[0])
                if codec.parameterSetTypes.contains(type), parameterSets[type] == nil {
                    parameterSets[type] = Data(payload)
                }
                withUnsafeBytes(of: UInt32(range.count).bigEndian) { lengthBytes in
                    lengthPrefixedData.append(contentsOf: lengthBytes)
                }
                lengthPrefixedData.append(payload)
            }
            return (lengthPrefixedData, parameterSets)
        }
    }

    static func nalUnitPayloadRanges(in bytes: UnsafeBufferPointer<UInt8>, codec: Codec) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        var searchOffset = 0
        while let startCode = nextStartCode(in: bytes, from: searchOffset) {
            if let payloadStart, payloadStart < startCode.index {
                ranges.append(payloadStart ..< startCode.index)
            }
            payloadStart = startCode.index + startCode.length
            searchOffset = startCode.index + startCode.length
        }
        if let payloadStart, payloadStart < bytes.count {
            ranges.append(payloadStart ..< bytes.count)
        }
        return ranges.filter { $0.count >= codec.headerByteCount }
    }

    private static func nextStartCode(
        in bytes: UnsafeBufferPointer<UInt8>,
        from offset: Int
    ) -> (index: Int, length: Int)? {
        var index = offset
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    return (index, 3)
                }
                if bytes[index + 2] == 0, index + 3 < bytes.count, bytes[index + 3] == 1 {
                    return (index, 4)
                }
            }
            index += 1
        }
        return nil
    }
}

struct RDPGFXAVC420BitmapStream: Equatable, Sendable {
    var regionRects: [RDPGFXRect16]
    var encodedBitstream: Data

    static func parse(from data: Data) throws -> RDPGFXAVC420BitmapStream {
        var cursor = ByteCursor(data)
        let regionCount = try cursor.readLittleEndianUInt32()
        // Each region has an RDPGFX_RECT16 and an RDPGFX_AVC420_QUANT_QUALITY.
        guard regionCount <= UInt32(cursor.remaining / 10) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var regionRects: [RDPGFXRect16] = []
        regionRects.reserveCapacity(Int(regionCount))
        for _ in 0 ..< regionCount {
            try regionRects.append(RDPGFXRect16.parse(&cursor))
        }
        // The quantization values are informational (MS-RDPEGFX 2.2.4.4.1); only
        // their ranges are checked (2.2.4.4.2).
        for _ in 0 ..< regionCount {
            let qpVal = try cursor.readUInt8()
            let qualityVal = try cursor.readUInt8()
            guard qpVal & 0x3F <= 51, qualityVal <= 100 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        let encodedBitstream = cursor.readRemainingData()
        guard !encodedBitstream.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXAVC420BitmapStream(regionRects: regionRects, encodedBitstream: encodedBitstream)
    }
}

/// The LC field of avc420EncodedBitstreamInfo (MS-RDPEGFX 2.2.4.5); 0x3 is invalid.
enum RDPGFXAVC444LayoutCode: UInt8, Equatable, Sendable {
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

/// RFX_AVC444_BITMAP_STREAM and RFX_AVC444V2_BITMAP_STREAM, which share a layout
/// (MS-RDPEGFX 2.2.4.5 and 2.2.4.6).
struct RDPGFXAVC444BitmapStream: Equatable, Sendable {
    var layoutCode: RDPGFXAVC444LayoutCode
    var firstStream: RDPGFXAVC420BitmapStream
    var secondStream: RDPGFXAVC420BitmapStream?

    var yuv420Stream: RDPGFXAVC420BitmapStream? {
        layoutCode == .chroma420Only ? nil : firstStream
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

    static func parse(from data: Data) throws -> RDPGFXAVC444BitmapStream {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let bitstreamInfo = try cursor.readLittleEndianUInt32()
        let firstStreamByteCount = Int(bitstreamInfo & 0x3FFF_FFFF)
        guard let layoutCode = RDPGFXAVC444LayoutCode(rawValue: UInt8(bitstreamInfo >> 30)) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let streamData = cursor.readRemainingData()
        switch layoutCode {
        case .yuv420AndChroma420:
            guard firstStreamByteCount > 0, firstStreamByteCount <= streamData.count else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData.prefix(firstStreamByteCount)),
                secondStream: RDPGFXAVC420BitmapStream.parse(from: streamData.dropFirst(firstStreamByteCount))
            )
        case .yuv420Only, .chroma420Only:
            // cbAvc420EncodedBitstream1 is zero when no YUV420 frame is present.
            let expectedByteCount = layoutCode == .yuv420Only ? streamData.count : 0
            guard firstStreamByteCount == expectedByteCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try RDPGFXAVC444BitmapStream(
                layoutCode: layoutCode,
                firstStream: RDPGFXAVC420BitmapStream.parse(from: streamData),
                secondStream: nil
            )
        }
    }
}

/// ALPHACODEC_BITMAP_STREAM (MS-RDPEGFX 2.2.4.3).
struct RDPGFXAlphaBitmapStream: Equatable, Sendable {
    private static let alphaSignature: UInt16 = 0x414C

    var alphaValues: Data

    static func parse(from data: Data, pixelCount: Int) throws -> RDPGFXAlphaBitmapStream {
        var cursor = ByteCursor(data)
        guard pixelCount >= 0,
              cursor.remaining >= 4,
              try cursor.readLittleEndianUInt16() == alphaSignature
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        guard try cursor.readLittleEndianUInt16() != 0 else {
            let alphaValues = cursor.readRemainingData()
            guard alphaValues.count == pixelCount else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return RDPGFXAlphaBitmapStream(alphaValues: alphaValues)
        }

        var alphaValues = Data()
        while cursor.remaining > 0 {
            let runValue = try cursor.readUInt8()
            let runLength = try readRunLength(&cursor)
            guard runLength <= pixelCount - alphaValues.count else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            alphaValues.append(contentsOf: repeatElement(runValue, count: runLength))
        }
        guard alphaValues.count == pixelCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXAlphaBitmapStream(alphaValues: alphaValues)
    }

    /// CLEARCODEC_ALPHA_RLE_SEGMENT run length (MS-RDPEGFX 2.2.4.3.1).
    private static func readRunLength(_ cursor: inout ByteCursor) throws -> Int {
        let firstFactor = try cursor.readUInt8()
        guard firstFactor == 0xFF else {
            return Int(firstFactor)
        }
        let secondFactor = try cursor.readLittleEndianUInt16()
        guard secondFactor == 0xFFFF else {
            return Int(secondFactor)
        }
        return try Int(cursor.readLittleEndianUInt32())
    }
}

struct RDPGFXResetGraphicsPDU: Equatable, Sendable {
    static let maximumDimension: UInt32 = 32_766
    static let maximumMonitorCount: UInt32 = 16

    var width: UInt32
    var height: UInt32

    /// The PDU is always 340 bytes long; monitorDefArray and the padding are not read.
    /// KRdp sends exclusive right/bottom monitor values although TS_MONITOR_DEF is
    /// inclusive, so the monitor rects must never be checked against the output size.
    static func parse(from message: RDPGFXHeader) throws -> RDPGFXResetGraphicsPDU {
        guard message.commandID == RDPGFXCommandID.resetGraphics,
              message.payload.count == 340 - 8
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var cursor = ByteCursor(message.payload)
        let width = try cursor.readLittleEndianUInt32()
        let height = try cursor.readLittleEndianUInt32()
        let monitorCount = try cursor.readLittleEndianUInt32()
        guard width <= maximumDimension,
              height <= maximumDimension,
              monitorCount <= maximumMonitorCount
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPGFXResetGraphicsPDU(width: width, height: height)
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
        return try RDPGFXMapSurfaceToOutputPDU(
            surfaceID: surfaceID,
            outputOriginX: cursor.readLittleEndianUInt32(),
            outputOriginY: cursor.readLittleEndianUInt32()
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
        return try RDPGFXSolidFillPDU(
            surfaceID: surfaceID,
            fillPixel: fillPixel,
            fillRects: parseTrailingArray(count: rectCount, elementByteCount: 8, from: &cursor, RDPGFXRect16.parse)
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
        let pointCount = try cursor.readLittleEndianUInt16()
        return try RDPGFXSurfaceToSurfacePDU(
            sourceSurfaceID: sourceSurfaceID,
            destinationSurfaceID: destinationSurfaceID,
            sourceRect: sourceRect,
            destinationPoints: parseTrailingArray(count: pointCount, elementByteCount: 4, from: &cursor, RDPGFXPoint16.parse)
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
        return try RDPGFXSurfaceToCachePDU(
            surfaceID: surfaceID,
            cacheKey: cacheKey,
            cacheSlot: cacheSlot,
            sourceRect: RDPGFXRect16.parse(&cursor)
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
        let pointCount = try cursor.readLittleEndianUInt16()
        return try RDPGFXCacheToSurfacePDU(
            cacheSlot: cacheSlot,
            surfaceID: surfaceID,
            destinationPoints: parseTrailingArray(count: pointCount, elementByteCount: 4, from: &cursor, RDPGFXPoint16.parse)
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
        guard RDPGFXCodecID.isValidWireToSurface1(codecID),
              RDPGFXPixelFormat.isValid(pixelFormat),
              Int(bitmapDataLength) == cursor.remaining
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXWireToSurface1PDU(
            surfaceID: surfaceID,
            codecID: codecID,
            pixelFormat: pixelFormat,
            destinationRect: destinationRect,
            bitmapData: cursor.readRemainingData()
        )
    }
}

struct RDPGFXWireToSurface2PDU: Equatable, Sendable {
    var surfaceID: UInt16
    var codecID: UInt16
    var codecContextID: UInt32
    var pixelFormat: UInt8
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
        let codecContextID = try cursor.readLittleEndianUInt32()
        let pixelFormat = try cursor.readUInt8()
        let bitmapDataLength = try cursor.readLittleEndianUInt32()
        guard RDPGFXCodecID.isValidWireToSurface2(codecID),
              RDPGFXPixelFormat.isValid(pixelFormat),
              Int(bitmapDataLength) == cursor.remaining
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return RDPGFXWireToSurface2PDU(
            surfaceID: surfaceID,
            codecID: codecID,
            codecContextID: codecContextID,
            pixelFormat: pixelFormat,
            bitmapData: cursor.readRemainingData()
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

struct RDPGFXFrameAcknowledgePDU: Equatable, Sendable {
    /// 0 is QUEUE_DEPTH_UNAVAILABLE; 0xFFFFFFFF is SUSPEND_FRAME_ACKNOWLEDGEMENT.
    var queueDepth: UInt32 = 0
    var frameID: UInt32
    var totalFramesDecoded: UInt32

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(queueDepth)
        payload.appendLittleEndianUInt32(frameID)
        payload.appendLittleEndianUInt32(totalFramesDecoded)
        return RDPGFXHeader.encoded(commandID: RDPGFXCommandID.frameAcknowledge, payload: payload)
    }
}

/// Diagnostic summary of a server graphics message.
public struct RDPGFXMessageSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var surfaceID: UInt16?
    public var width: UInt32?
    public var height: UInt32?
    public var pixelFormat: UInt8?
    public var codecID: UInt16?
    public var codecName: String?
    public var codecContextID: UInt32?
    public var bitmapDataLength: UInt32?
    public var frameID: UInt32?
    public var avc444Layout: String?
    public var avc444YUV420EncodedBitstreamLength: Int?
    public var avc444Chroma420EncodedBitstreamLength: Int?
    public var clearCodecResidualByteCount: UInt32?
    public var clearCodecBandsByteCount: UInt32?
    public var clearCodecSubcodecByteCount: UInt32?
    public var cavideoBlockTypeNames: [String]?
    public var cavideoTileSetEntropyAlgorithms: [String]?
    public var cavideoTileCount: Int?
    public var progressiveBlockTypeNames: [String]?
    public var progressiveContextTileSizes: [UInt16]?
    public var progressiveContextFlags: [UInt8]?
    public var progressiveFrameIndexes: [UInt32]?
    public var progressiveFrameRegionCounts: [UInt16]?
    public var progressiveRegionRects: [RDPFrameRect]?
    public var progressiveRegionTileCount: Int?
    public var progressiveTileSimpleCount: Int?
    public var progressiveTileFirstCount: Int?
    public var progressiveTileUpgradeCount: Int?

    /// Throws when the message is malformed; codec payload details are best effort.
    static func summarize(
        _ message: RDPGFXHeader,
        includeVideoDetails: Bool = true
    ) throws -> RDPGFXMessageSummary {
        var summary = RDPGFXMessageSummary(typeName: message.typeName)
        switch message.commandID {
        case RDPGFXCommandID.resetGraphics:
            let reset = try RDPGFXResetGraphicsPDU.parse(from: message)
            summary.width = reset.width
            summary.height = reset.height
        case RDPGFXCommandID.createSurface:
            let create = try RDPGFXCreateSurfacePDU.parse(from: message)
            summary.surfaceID = create.surfaceID
            summary.width = UInt32(create.width)
            summary.height = UInt32(create.height)
            summary.pixelFormat = create.pixelFormat
        case RDPGFXCommandID.deleteSurface:
            summary.surfaceID = try RDPGFXDeleteSurfacePDU.parse(from: message).surfaceID
        case RDPGFXCommandID.mapSurfaceToOutput:
            summary.surfaceID = try RDPGFXMapSurfaceToOutputPDU.parse(from: message).surfaceID
        case RDPGFXCommandID.mapSurfaceToScaledOutput:
            summary.surfaceID = try RDPGFXMapSurfaceToScaledOutputPDU.parse(from: message).surfaceID
        case RDPGFXCommandID.solidFill:
            summary.surfaceID = try RDPGFXSolidFillPDU.parse(from: message).surfaceID
        case RDPGFXCommandID.surfaceToSurface:
            summary.surfaceID = try RDPGFXSurfaceToSurfacePDU.parse(from: message).destinationSurfaceID
        case RDPGFXCommandID.surfaceToCache:
            summary.surfaceID = try RDPGFXSurfaceToCachePDU.parse(from: message).surfaceID
        case RDPGFXCommandID.cacheToSurface:
            summary.surfaceID = try RDPGFXCacheToSurfacePDU.parse(from: message).surfaceID
        case RDPGFXCommandID.startFrame:
            summary.frameID = try RDPGFXStartFramePDU.parse(from: message).frameID
        case RDPGFXCommandID.endFrame:
            summary.frameID = try RDPGFXEndFramePDU.parse(from: message).frameID
        case RDPGFXCommandID.deleteEncodingContext:
            let delete = try RDPGFXDeleteEncodingContextPDU.parse(from: message)
            summary.surfaceID = delete.surfaceID
            summary.codecContextID = delete.codecContextID
        case RDPGFXCommandID.wireToSurface1:
            try summary.addWireToSurface1(
                RDPGFXWireToSurface1PDU.parse(from: message),
                includeVideoDetails: includeVideoDetails
            )
        case RDPGFXCommandID.wireToSurface2:
            let wire = try RDPGFXWireToSurface2PDU.parse(from: message)
            summary.addBitmapCommand(
                surfaceID: wire.surfaceID,
                codecID: wire.codecID,
                pixelFormat: wire.pixelFormat,
                bitmapData: wire.bitmapData
            )
            summary.codecContextID = wire.codecContextID
            if let progressive = try? RDPGFXProgressiveStreamSummary(wire.bitmapData) {
                summary.progressiveBlockTypeNames = progressive.blockTypeNames
                summary.progressiveContextTileSizes = progressive.contextTileSizes
                summary.progressiveContextFlags = progressive.contextFlags
                summary.progressiveFrameIndexes = progressive.frameIndexes
                summary.progressiveFrameRegionCounts = progressive.frameRegionCounts
                summary.progressiveRegionRects = progressive.regionRects
                summary.progressiveRegionTileCount = progressive.tileSimpleCount
                    + progressive.tileFirstCount
                    + progressive.tileUpgradeCount
                summary.progressiveTileSimpleCount = progressive.tileSimpleCount
                summary.progressiveTileFirstCount = progressive.tileFirstCount
                summary.progressiveTileUpgradeCount = progressive.tileUpgradeCount
            }
        default:
            break
        }
        return summary
    }

    private mutating func addBitmapCommand(surfaceID: UInt16, codecID: UInt16, pixelFormat: UInt8, bitmapData: Data) {
        self.surfaceID = surfaceID
        self.codecID = codecID
        self.pixelFormat = pixelFormat
        codecName = RDPGFXCodecID.name(for: codecID)
        bitmapDataLength = UInt32(bitmapData.count)
    }

    private mutating func addWireToSurface1(_ wire: RDPGFXWireToSurface1PDU, includeVideoDetails: Bool) {
        addBitmapCommand(
            surfaceID: wire.surfaceID,
            codecID: wire.codecID,
            pixelFormat: wire.pixelFormat,
            bitmapData: wire.bitmapData
        )
        switch wire.codecID {
        case RDPGFXCodecID.clearCodec:
            guard let clearCodec = try? RDPClearCodecDecoder.summarize(wire.bitmapData) else {
                break
            }
            clearCodecResidualByteCount = clearCodec.residualByteCount
            clearCodecBandsByteCount = clearCodec.bandsByteCount
            clearCodecSubcodecByteCount = clearCodec.subcodecByteCount
        case RDPGFXCodecID.avc444, RDPGFXCodecID.avc444v2:
            guard includeVideoDetails,
                  let avc444 = try? RDPGFXAVC444BitmapStream.parse(from: wire.bitmapData)
            else {
                break
            }
            avc444Layout = avc444.layoutCode.description
            avc444YUV420EncodedBitstreamLength = avc444.yuv420Stream?.encodedBitstream.count
            avc444Chroma420EncodedBitstreamLength = avc444.chroma420Stream?.encodedBitstream.count
        case RDPGFXCodecID.cavideo:
            guard includeVideoDetails,
                  let cavideo = try? RDPGFXCAVideoStreamSummary(wire.bitmapData)
            else {
                break
            }
            cavideoBlockTypeNames = cavideo.blockTypeNames
            cavideoTileSetEntropyAlgorithms = cavideo.tileSetEntropyAlgorithms
            cavideoTileCount = cavideo.tileCount
        default:
            break
        }
    }
}

/// Reads a TS_RFX_BLOCKT or RFX_PROGRESSIVE_DATABLOCK header and body; blockLen
/// includes the 6-byte header.
private func readRemoteFXBlock(_ cursor: inout ByteCursor) throws -> (type: UInt16, body: Data) {
    let blockType = try cursor.readLittleEndianUInt16()
    let blockLength = try Int(cursor.readLittleEndianUInt32())
    guard blockLength >= 6, blockLength - 6 <= cursor.remaining else {
        throw RDPDecodeError.invalidRDPGFXPDU
    }
    return try (blockType, cursor.readData(count: blockLength - 6))
}

private func remoteFXBlockName(_ blockType: UInt16, names: [UInt16: String]) -> String {
    names[blockType] ?? "block-0x\(String(format: "%04x", blockType))"
}

/// Block-level walk of an RFX_PROGRESSIVE_BITMAP_STREAM (MS-RDPEGFX 2.2.4.2).
private struct RDPGFXProgressiveStreamSummary {
    private enum BlockType {
        static let frameBegin: UInt16 = 0xCCC1
        static let context: UInt16 = 0xCCC3
        static let region: UInt16 = 0xCCC4
        static let tileSimple: UInt16 = 0xCCC5
        static let tileFirst: UInt16 = 0xCCC6
        static let tileUpgrade: UInt16 = 0xCCC7
    }

    private static let blockNames: [UInt16: String] = [
        0xCCC0: "sync",
        0xCCC1: "frame-begin",
        0xCCC2: "frame-end",
        0xCCC3: "context",
        0xCCC4: "region",
        0xCCC5: "tile-simple",
        0xCCC6: "tile-first",
        0xCCC7: "tile-upgrade",
    ]

    var blockTypeNames: [String] = []
    var contextTileSizes: [UInt16] = []
    var contextFlags: [UInt8] = []
    var frameIndexes: [UInt32] = []
    var frameRegionCounts: [UInt16] = []
    var regionRects: [RDPFrameRect] = []
    var tileSimpleCount = 0
    var tileFirstCount = 0
    var tileUpgradeCount = 0

    init(_ data: Data) throws {
        var cursor = ByteCursor(data)
        while cursor.remaining > 0 {
            let block = try readRemoteFXBlock(&cursor)
            blockTypeNames.append(remoteFXBlockName(block.type, names: Self.blockNames))
            var body = ByteCursor(block.body)
            switch block.type {
            case BlockType.frameBegin:
                frameIndexes.append(try body.readLittleEndianUInt32())
                frameRegionCounts.append(try body.readLittleEndianUInt16())
            case BlockType.context:
                _ = try body.readUInt8()
                contextTileSizes.append(try body.readLittleEndianUInt16())
                contextFlags.append(try body.readUInt8())
            case BlockType.region:
                try addRegion(&body)
            default:
                break
            }
        }
    }

    private mutating func addRegion(_ cursor: inout ByteCursor) throws {
        _ = try cursor.readUInt8()
        let rectCount = try cursor.readLittleEndianUInt16()
        let quantCount = try cursor.readUInt8()
        let progressiveQuantCount = try cursor.readUInt8()
        _ = try cursor.readData(count: 7)
        for _ in 0 ..< rectCount {
            let x = try cursor.readLittleEndianUInt16()
            let y = try cursor.readLittleEndianUInt16()
            let width = try cursor.readLittleEndianUInt16()
            let height = try cursor.readLittleEndianUInt16()
            guard let right = UInt16(exactly: Int(x) + Int(width)),
                  let bottom = UInt16(exactly: Int(y) + Int(height))
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            regionRects.append(RDPFrameRect(left: x, top: y, right: right, bottom: bottom))
        }
        _ = try cursor.readData(count: Int(quantCount) * 5 + Int(progressiveQuantCount) * 16)
        while cursor.remaining > 0 {
            switch try readRemoteFXBlock(&cursor).type {
            case BlockType.tileSimple:
                tileSimpleCount += 1
            case BlockType.tileFirst:
                tileFirstCount += 1
            case BlockType.tileUpgrade:
                tileUpgradeCount += 1
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }
    }
}

/// Block-level walk of a RemoteFX (CAVIDEO) stream (MS-RDPRFX 2.2.2).
private struct RDPGFXCAVideoStreamSummary {
    private static let tileSetBlockType: UInt16 = 0xCCC7
    private static let tileBlockType: UInt16 = 0xCAC3
    private static let blockNames: [UInt16: String] = [
        0xCAC3: "tile",
        0xCCC0: "sync",
        0xCCC1: "codec-versions",
        0xCCC2: "channels",
        0xCCC3: "context",
        0xCCC4: "frame-begin",
        0xCCC5: "frame-end",
        0xCCC6: "region",
        0xCCC7: "tile-set",
    ]

    var blockTypeNames: [String] = []
    var tileSetEntropyAlgorithms: [String] = []
    var tileCount = 0

    init(_ data: Data) throws {
        var cursor = ByteCursor(data)
        while cursor.remaining > 0 {
            try addBlock(from: &cursor)
        }
    }

    private mutating func addBlock(from cursor: inout ByteCursor) throws {
        let block = try readRemoteFXBlock(&cursor)
        blockTypeNames.append(remoteFXBlockName(block.type, names: Self.blockNames))
        switch block.type {
        case Self.tileSetBlockType:
            // Channel header, subtype and idx precede the properties; the quant
            // count is followed by tileSize, numTiles, tilesDataSize and the quant values.
            var body = ByteCursor(block.body)
            _ = try body.readData(count: 6)
            let properties = try body.readLittleEndianUInt16()
            tileSetEntropyAlgorithms.append(Self.entropyAlgorithmName((properties >> 10) & 0x0F))
            let quantCount = try body.readUInt8()
            _ = try body.readData(count: 7 + Int(quantCount) * 5)
            while body.remaining > 0 {
                try addBlock(from: &body)
            }
        case Self.tileBlockType:
            tileCount += 1
        default:
            break
        }
    }

    private static func entropyAlgorithmName(_ value: UInt16) -> String {
        switch value {
        case 0x01:
            "rlgr1"
        case 0x04:
            "rlgr3"
        default:
            "entropy-0x\(String(format: "%x", value))"
        }
    }
}

final class RDPGFXServerTransportDecoder {
    private let zgfx = RDPZGFXDecompressor()

    /// Returns all the graphics messages in one server message.
    func decodeGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        guard let descriptor = data.first else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var cursor = switch descriptor {
        case 0xE0, 0xE1:
            try ByteCursor(zgfx.decompress(data))
        default:
            ByteCursor(data)
        }
        var messages: [RDPGFXHeader] = []
        while cursor.remaining > 0 {
            try messages.append(RDPGFXHeader.parse(from: &cursor))
        }
        return messages
    }
}
