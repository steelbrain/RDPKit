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
    var updateCode: RDPFastPathUpdateCode
    var fragmentation: RDPFastPathFragmentation
    var compressionFlags: UInt8?
    var updateData: Data

    var typeName: String {
        updateCode.typeName
    }

    var isCompressedPayload: Bool {
        compressionFlags.map { $0 & RDPFastPathCompressionFlags.compressed != 0 } ?? false
    }

    var pointerUpdate: RDPServerPointerUpdate? {
        guard fragmentation == .single,
              !isCompressedPayload
        else {
            return nil
        }
        switch updateCode {
        case .pointerNull:
            guard updateData.isEmpty else {
                return nil
            }
            return .system(type: 0x0000_0000)
        case .pointerDefault:
            guard updateData.isEmpty else {
                return nil
            }
            return .system(type: 0x0000_7F00)
        case .pointerPosition:
            guard let position = try? Self.parsePointerPosition(updateData) else {
                return nil
            }
            return .position(position)
        case .colorPointer:
            var cursor = ByteCursor(updateData)
            guard let color = try? RDPColorPointerAttribute.parse(from: &cursor) else {
                return nil
            }
            return .color(color)
        case .cachedPointer:
            guard updateData.count == 2 else {
                return nil
            }
            return .cached(cacheIndex: updateData.littleEndianUInt16(at: 0))
        case .newPointer:
            var cursor = ByteCursor(updateData)
            guard let pointer = try? Self.parseNewPointer(from: &cursor) else {
                return nil
            }
            return .pointer(pointer)
        case .largePointer:
            var cursor = ByteCursor(updateData)
            guard let pointer = try? Self.parseLargePointer(from: &cursor) else {
                return nil
            }
            return .largePointer(pointer)
        default:
            return nil
        }
    }

    var surfaceCommands: [RDPSurfaceCommand]? {
        guard updateCode == .surfaceCommands,
              fragmentation == .single,
              !isCompressedPayload
        else {
            return nil
        }
        return try? RDPSurfaceCommand.parsePayload(updateData)
    }

    var bitmapUpdate: RDPBitmapUpdate? {
        guard updateCode == .bitmap,
              fragmentation == .single,
              !isCompressedPayload
        else {
            return nil
        }
        return try? RDPSlowPathGraphicsUpdate.parseBitmapPayload(updateData)
    }

    var paletteUpdate: RDPPaletteUpdate? {
        guard updateCode == .palette,
              fragmentation == .single,
              !isCompressedPayload
        else {
            return nil
        }
        return try? RDPSlowPathGraphicsUpdate.parsePalettePayload(updateData)
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
        let updateData = try cursor.readData(count: updateDataByteCount)

        try validate(
            updateCode: updateCode,
            fragmentation: fragmentation,
            compressionFlags: compressionFlags,
            updateData: updateData
        )
        return RDPFastPathOutputUpdate(
            updateCode: updateCode,
            fragmentation: fragmentation,
            compressionFlags: compressionFlags,
            updateData: updateData
        )
    }

    static func reassembled(
        updateCode: RDPFastPathUpdateCode,
        compressionFlags: UInt8?,
        updateData: Data
    ) throws -> RDPFastPathOutputUpdate {
        try validate(
            updateCode: updateCode,
            fragmentation: .single,
            compressionFlags: compressionFlags,
            updateData: updateData
        )
        return RDPFastPathOutputUpdate(
            updateCode: updateCode,
            fragmentation: .single,
            compressionFlags: compressionFlags,
            updateData: updateData
        )
    }

    private static func validate(
        updateCode: RDPFastPathUpdateCode,
        fragmentation: RDPFastPathFragmentation,
        compressionFlags: UInt8?,
        updateData: Data
    ) throws {
        if fragmentation != .single || compressionFlags.map({ $0 & RDPFastPathCompressionFlags.compressed != 0 }) == true {
            return
        }

        switch updateCode {
        case .bitmap:
            do {
                _ = try RDPSlowPathGraphicsUpdate.parseBitmapPayload(updateData)
            } catch {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        case .palette:
            do {
                _ = try RDPSlowPathGraphicsUpdate.parsePalettePayload(updateData)
            } catch {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        case .surfaceCommands:
            do {
                _ = try RDPSurfaceCommand.parsePayload(updateData)
            } catch {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        case .synchronize, .pointerNull, .pointerDefault:
            guard updateData.isEmpty else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        case .pointerPosition:
            _ = try parsePointerPosition(updateData)
        case .cachedPointer:
            guard updateData.count == 2 else {
                throw RDPDecodeError.invalidFastPathOutputPDU
            }
        default:
            return
        }
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

    private static func parsePointerPosition(_ data: Data) throws -> RDPPoint16 {
        guard data.count == 4 else {
            throw RDPDecodeError.invalidFastPathOutputPDU
        }
        var cursor = ByteCursor(data)
        return try RDPPoint16.parse(from: &cursor)
    }

    private static func parseNewPointer(from cursor: inout ByteCursor) throws -> RDPNewPointerAttribute {
        let xorBitsPerPixel = try cursor.readLittleEndianUInt16()
        let colorPointer = try RDPColorPointerAttribute.parse(
            from: &cursor,
            xorBitsPerPixel: xorBitsPerPixel
        )
        return RDPNewPointerAttribute(
            xorBitsPerPixel: xorBitsPerPixel,
            colorPointer: colorPointer
        )
    }

    private static func parseLargePointer(from cursor: inout ByteCursor) throws -> RDPNewPointerAttribute {
        let xorBitsPerPixel = try cursor.readLittleEndianUInt16()
        let colorPointer = try RDPColorPointerAttribute.parseLargeFastPath(
            from: &cursor,
            xorBitsPerPixel: xorBitsPerPixel
        )
        return RDPNewPointerAttribute(
            xorBitsPerPixel: xorBitsPerPixel,
            colorPointer: colorPointer
        )
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
    static let flushed: UInt8 = 0x80
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

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }
}
