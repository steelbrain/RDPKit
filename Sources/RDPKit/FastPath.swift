import Foundation

struct RDPFastPathOutputFlags: OptionSet, Sendable {
    var rawValue: UInt8

    static let secureChecksum = RDPFastPathOutputFlags(rawValue: 0x01)
    static let encrypted = RDPFastPathOutputFlags(rawValue: 0x02)
}

enum RDPFastPathUpdateCode: UInt8, Sendable {
    case orders = 0x0
    case bitmap = 0x1
    case palette = 0x2
    case synchronize = 0x3
    case surfaceCommands = 0x4
    case pointerNull = 0x5
    case pointerDefault = 0x6
    case pointerPosition = 0x8
    case colorPointer = 0x9
    case cachedPointer = 0xA
    case newPointer = 0xB
    case largePointer = 0xC

    var typeName: String {
        switch self {
        case .orders:
            "fastpath-orders"
        case .bitmap:
            "fastpath-bitmap"
        case .palette:
            "fastpath-palette"
        case .synchronize:
            "fastpath-synchronize"
        case .surfaceCommands:
            "fastpath-surface-commands"
        case .pointerNull:
            "fastpath-pointer-hidden"
        case .pointerDefault:
            "fastpath-pointer-default"
        case .pointerPosition:
            "fastpath-pointer-position"
        case .colorPointer:
            "fastpath-pointer-color"
        case .cachedPointer:
            "fastpath-pointer-cached"
        case .newPointer:
            "fastpath-pointer-new"
        case .largePointer:
            "fastpath-pointer-large"
        }
    }
}

enum RDPFastPathFragmentation: UInt8, Sendable {
    case single = 0x0
    case last = 0x1
    case first = 0x2
    case next = 0x3
}

struct RDPFastPathOutputUpdate: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case pointer(RDPServerPointerUpdate)
        case malformedPointer(RDPDecodeError)
        case surfaceCommands([RDPSurfaceCommand])
        case bitmap(RDPBitmapUpdate)
        case palette(RDPPaletteUpdate)
    }

    var updateCode: RDPFastPathUpdateCode
    var fragmentation: RDPFastPathFragmentation
    var compressionFlags: UInt8?
    var updateData: Data
    /// Decoded body of a complete, uncompressed update; nil for fragments,
    /// compressed payloads, Synchronize and Orders.
    private(set) var content: Content?

    var typeName: String {
        updateCode.typeName
    }

    var isCompressedPayload: Bool {
        compressionFlags.map { $0 & RDPFastPathCompressionFlags.compressed != 0 } ?? false
    }

    var pointerUpdate: RDPServerPointerUpdate? {
        guard case let .pointer(update) = content else {
            return nil
        }
        return update
    }

    /// Why a pointer update could not be decoded. Pointer shapes are cosmetic,
    /// so the session goes on; the caller records the error instead.
    var pointerDecodeError: RDPDecodeError? {
        guard case let .malformedPointer(error) = content else {
            return nil
        }
        return error
    }

    var surfaceCommands: [RDPSurfaceCommand]? {
        guard case let .surfaceCommands(commands) = content else {
            return nil
        }
        return commands
    }

    var bitmapUpdate: RDPBitmapUpdate? {
        guard case let .bitmap(update) = content else {
            return nil
        }
        return update
    }

    var paletteUpdate: RDPPaletteUpdate? {
        guard case let .palette(update) = content else {
            return nil
        }
        return update
    }

    private init(
        updateCode: RDPFastPathUpdateCode,
        fragmentation: RDPFastPathFragmentation,
        compressionFlags: UInt8?,
        updateData: Data
    ) throws {
        self.updateCode = updateCode
        self.fragmentation = fragmentation
        self.compressionFlags = compressionFlags
        self.updateData = updateData
        if fragmentation == .single, !isCompressedPayload {
            do {
                content = try Self.decodeContent(updateCode: updateCode, updateData: updateData)
            } catch {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        }
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPFastPathOutputUpdate {
        let updateHeader = try cursor.readUInt8()
        let updateCodeValue = updateHeader & 0x0F
        let fragmentationValue = (updateHeader >> 4) & 0x03
        let compressionValue = (updateHeader >> 6) & 0x03
        guard let updateCode = RDPFastPathUpdateCode(rawValue: updateCodeValue),
              let fragmentation = RDPFastPathFragmentation(rawValue: fragmentationValue),
              compressionValue == 0 || compressionValue == 0x02
        else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }

        let compressionFlags = compressionValue == 0x02 ? try cursor.readUInt8() : nil
        try validateCompressionFlags(compressionFlags)
        let updateDataByteCount = try Int(cursor.readLittleEndianUInt16())
        guard updateDataByteCount <= cursor.remaining else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        return try RDPFastPathOutputUpdate(
            updateCode: updateCode,
            fragmentation: fragmentation,
            compressionFlags: compressionFlags,
            updateData: cursor.readData(count: updateDataByteCount)
        )
    }

    static func reassembled(
        updateCode: RDPFastPathUpdateCode,
        compressionFlags: UInt8?,
        updateData: Data
    ) throws -> RDPFastPathOutputUpdate {
        try RDPFastPathOutputUpdate(
            updateCode: updateCode,
            fragmentation: .single,
            compressionFlags: compressionFlags,
            updateData: updateData
        )
    }

    /// [MS-RDPBCGR] 2.2.9.1.2.1.x update bodies. Malformed graphics bodies
    /// throw, like the slow-path Share Data parser; malformed pointers become
    /// `.malformedPointer` so the caller can record and skip them.
    private static func decodeContent(updateCode: RDPFastPathUpdateCode, updateData: Data) throws -> Content? {
        switch updateCode {
        case .orders:
            return nil
        case .bitmap:
            return try .bitmap(RDPSlowPathGraphicsUpdate.parseBitmapPayload(updateData))
        case .palette:
            return try .palette(RDPSlowPathGraphicsUpdate.parsePalettePayload(updateData))
        case .surfaceCommands:
            return try .surfaceCommands(RDPSurfaceCommand.parsePayload(updateData))
        case .synchronize:
            guard updateData.isEmpty else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
            return nil
        case .pointerNull, .pointerDefault, .pointerPosition, .colorPointer, .cachedPointer, .newPointer, .largePointer:
            do {
                return try .pointer(decodePointer(updateCode: updateCode, updateData: updateData))
            } catch let error as RDPDecodeError {
                return .malformedPointer(error)
            }
        }
    }

    private static func decodePointer(
        updateCode: RDPFastPathUpdateCode,
        updateData: Data
    ) throws -> RDPServerPointerUpdate {
        var cursor = ByteCursor(updateData)
        let update: RDPServerPointerUpdate
        switch updateCode {
        case .pointerNull:
            update = .system(type: 0x0000_0000)
        case .pointerDefault:
            update = .system(type: 0x0000_7F00)
        case .pointerPosition:
            update = try .position(RDPPoint16.parse(from: &cursor))
        case .colorPointer:
            update = try .color(RDPColorPointerAttribute.parse(from: &cursor))
        case .cachedPointer:
            update = try .cached(cacheIndex: cursor.readLittleEndianUInt16())
        case .newPointer:
            let xorBitsPerPixel = try cursor.readLittleEndianUInt16()
            update = try .pointer(RDPNewPointerAttribute(
                xorBitsPerPixel: xorBitsPerPixel,
                colorPointer: RDPColorPointerAttribute.parse(from: &cursor, xorBitsPerPixel: xorBitsPerPixel)
            ))
        case .largePointer:
            let xorBitsPerPixel = try cursor.readLittleEndianUInt16()
            update = try .largePointer(RDPNewPointerAttribute(
                xorBitsPerPixel: xorBitsPerPixel,
                colorPointer: RDPColorPointerAttribute.parseLargeFastPath(
                    from: &cursor,
                    xorBitsPerPixel: xorBitsPerPixel
                )
            ))
        case .orders, .bitmap, .palette, .synchronize, .surfaceCommands:
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidPointerPDU
        }
        return update
    }

    private static func validateCompressionFlags(_ compressionFlags: UInt8?) throws {
        guard let compressionFlags else {
            return
        }

        let compressionType = compressionFlags & RDPFastPathCompressionFlags.typeMask
        guard compressionType <= RDPFastPathCompressionFlags.rdp61Type else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        if compressionFlags & RDPFastPathCompressionFlags.atFront != 0 {
            guard compressionFlags & RDPFastPathCompressionFlags.compressed != 0 else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        }
        guard compressionFlags & RDPFastPathCompressionFlags.reserved == 0 else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
    }
}

struct RDPFastPathOutputFragmentReassembler: Sendable {
    private let maximumBufferedByteCount: Int
    private var activeUpdateCode: RDPFastPathUpdateCode?
    private var activeCompressionFlags: UInt8?
    private var payload = Data()

    var isActive: Bool {
        activeUpdateCode != nil
    }

    init(maximumBufferedByteCount: Int = RDPMultifragmentUpdateCapability.maxRequestSize) {
        precondition(maximumBufferedByteCount > 0)
        self.maximumBufferedByteCount = maximumBufferedByteCount
    }

    mutating func append(_ update: RDPFastPathOutputUpdate) throws -> RDPFastPathOutputUpdate? {
        switch update.fragmentation {
        case .single:
            guard !isActive else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
            return update

        case .first:
            guard !isActive,
                  update.updateData.count <= maximumBufferedByteCount
            else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
            activeUpdateCode = update.updateCode
            activeCompressionFlags = update.compressionFlags
            payload = update.updateData
            return nil

        case .next:
            try appendContinuation(update)
            return nil

        case .last:
            try appendContinuation(update)
            guard let activeUpdateCode else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
            let reassembledPayload = payload
            let reassembledCompressionFlags = activeCompressionFlags
            reset()
            return try RDPFastPathOutputUpdate.reassembled(
                updateCode: activeUpdateCode,
                compressionFlags: reassembledCompressionFlags,
                updateData: reassembledPayload
            )
        }
    }

    private mutating func appendContinuation(_ update: RDPFastPathOutputUpdate) throws {
        guard let activeUpdateCode,
              update.updateCode == activeUpdateCode,
              compressionFieldPresenceMatches(update.compressionFlags, activeCompressionFlags),
              payload.count <= maximumBufferedByteCount - update.updateData.count
        else {
            reset()
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        activeCompressionFlags = mergedCompressionFlags(activeCompressionFlags, update.compressionFlags)
        payload.append(update.updateData)
    }

    private func compressionFieldPresenceMatches(_ lhs: UInt8?, _ rhs: UInt8?) -> Bool {
        (lhs == nil) == (rhs == nil)
    }

    private func mergedCompressionFlags(_ lhs: UInt8?, _ rhs: UInt8?) -> UInt8? {
        guard let lhs, let rhs else {
            return lhs ?? rhs
        }
        return lhs | rhs
    }

    private mutating func reset() {
        activeUpdateCode = nil
        activeCompressionFlags = nil
        payload.removeAll(keepingCapacity: true)
    }
}

public struct RDPFastPathUpdateSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var fragmentation: String?
    public var compressed: Bool
    public var byteCount: Int
    public var pointerTypeName: String?
    public var surfaceCommandTypeNames: [String]?

    init(
        typeName: String,
        fragmentation: String?,
        compressed: Bool,
        byteCount: Int,
        pointerTypeName: String?,
        surfaceCommandTypeNames: [String]? = nil
    ) {
        self.typeName = typeName
        self.fragmentation = fragmentation
        self.compressed = compressed
        self.byteCount = byteCount
        self.pointerTypeName = pointerTypeName
        self.surfaceCommandTypeNames = surfaceCommandTypeNames
    }

    static func encryptedPayload(byteCount: Int) -> RDPFastPathUpdateSummary {
        RDPFastPathUpdateSummary(
            typeName: "fastpath-encrypted",
            fragmentation: nil,
            compressed: false,
            byteCount: byteCount,
            pointerTypeName: nil,
            surfaceCommandTypeNames: nil
        )
    }

    static func summarize(_ update: RDPFastPathOutputUpdate) -> RDPFastPathUpdateSummary {
        RDPFastPathUpdateSummary(
            typeName: update.typeName,
            fragmentation: update.fragmentation.name,
            compressed: update.isCompressedPayload,
            byteCount: update.updateData.count,
            pointerTypeName: update.pointerUpdate?.typeName,
            surfaceCommandTypeNames: update.surfaceCommands?.map(\.typeName)
        )
    }
}

struct RDPFastPathOutputPDU: Equatable, Sendable {
    var flags: RDPFastPathOutputFlags
    var dataSignature: Data?
    var encryptedPayload: Data?
    var updates: [RDPFastPathOutputUpdate]

    var summaries: [RDPFastPathUpdateSummary] {
        if let encryptedPayload {
            return [.encryptedPayload(byteCount: encryptedPayload.count)]
        }
        return updates.map(RDPFastPathUpdateSummary.summarize)
    }

    static func parse(_ packet: Data) throws -> RDPFastPathOutputPDU {
        var cursor = ByteCursor(packet)
        let outputHeader = try cursor.readUInt8()
        let action = outputHeader & 0x03
        let reserved = (outputHeader >> 2) & 0x0F
        let flags = RDPFastPathOutputFlags(rawValue: outputHeader >> 6)
        guard action == 0,
              reserved == 0,
              !flags.contains(.secureChecksum) || flags.contains(.encrypted)
        else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }

        let length = try readPacketLength(from: &cursor)
        guard length == packet.count else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }

        let dataSignature = flags.contains(.encrypted) ? try cursor.readData(count: 8) : nil
        if dataSignature != nil {
            return RDPFastPathOutputPDU(
                flags: flags,
                dataSignature: dataSignature,
                encryptedPayload: cursor.readRemainingData(),
                updates: []
            )
        }

        var updates: [RDPFastPathOutputUpdate] = []
        while cursor.remaining > 0 {
            updates.append(try RDPFastPathOutputUpdate.parse(from: &cursor))
        }
        return RDPFastPathOutputPDU(
            flags: flags,
            dataSignature: dataSignature,
            encryptedPayload: nil,
            updates: updates
        )
    }

    private static func readPacketLength(from cursor: inout ByteCursor) throws -> Int {
        let length1 = try cursor.readUInt8()
        let length: Int
        if length1 & 0x80 == 0 {
            length = Int(length1)
        } else {
            length = Int(length1 & 0x7F) << 8 | Int(try cursor.readUInt8())
        }
        guard length >= 3, length <= 0x8000 else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        return length
    }
}

private enum RDPFastPathCompressionFlags {
    static let typeMask: UInt8 = 0x0F
    static let rdp61Type: UInt8 = 0x03
    static let compressed: UInt8 = 0x20
    static let atFront: UInt8 = 0x40
    static let reserved: UInt8 = 0x10
}

private extension RDPFastPathFragmentation {
    var name: String {
        switch self {
        case .single:
            "single"
        case .last:
            "last"
        case .first:
            "first"
        case .next:
            "next"
        }
    }
}
