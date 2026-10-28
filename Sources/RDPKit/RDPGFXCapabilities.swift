import Foundation

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

    /// Flags the version does not define are dropped; like FreeRDP, the client ignores them.
    var flags: UInt32? {
        guard version != RDPGFXCapabilityVersion.version101 else {
            return nil
        }
        var cursor = ByteCursor(data)
        return (try? cursor.readLittleEndianUInt32()).map { $0 & (Self.definedFlags(for: version) ?? .max) }
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
        // The 10.1 set's 16 bytes are reserved; their values are ignored.
        guard let flags = RDPGFXCapabilitySet(version: version, data: data).flags else {
            return true
        }
        // AVC_THINCLIENT and AVC_DISABLED MUST NOT be set together (MS-RDPEGFX 2.2.3.6).
        let avcFlags = RDPGFXCapabilityFlags.avcDisabled | RDPGFXCapabilityFlags.avcThinClient
        return flags & avcFlags != avcFlags
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
