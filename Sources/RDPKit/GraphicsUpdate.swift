import Foundation

enum RDPSlowPathUpdateType: UInt16, Sendable {
    case orders = 0x0000
    case bitmap = 0x0001
    case palette = 0x0002
    case synchronize = 0x0003

    var typeName: String {
        switch self {
        case .orders:
            "update-orders"
        case .bitmap:
            "update-bitmap"
        case .palette:
            "update-palette"
        case .synchronize:
            "update-synchronize"
        }
    }
}

struct RDPBitmapUpdateRectangle: Equatable, Sendable {
    var destinationLeft: UInt16
    var destinationTop: UInt16
    var destinationRight: UInt16
    var destinationBottom: UInt16
    var width: UInt16
    var height: UInt16
    var bitsPerPixel: UInt16
    var flags: UInt16
    var compressedHeader: Data?
    var bitmapDataStream: Data

    var isCompressed: Bool {
        flags & RDPBitmapUpdateFlags.compression != 0
    }
}

struct RDPBitmapUpdate: Equatable, Sendable {
    var rectangles: [RDPBitmapUpdateRectangle]
}

struct RDPPaletteUpdate: Equatable, Sendable {
    var entries: Data
}

enum RDPSurfaceCommandType: UInt16, Sendable {
    case setSurfaceBits = 0x0001
    case frameMarker = 0x0004
    case streamSurfaceBits = 0x0006

    var typeName: String {
        switch self {
        case .setSurfaceBits:
            "surface-set-bits"
        case .frameMarker:
            "surface-frame-marker"
        case .streamSurfaceBits:
            "surface-stream-bits"
        }
    }
}

struct RDPExtendedBitmapData: Equatable, Sendable {
    var bitsPerPixel: UInt8
    var flags: UInt8
    var codecID: UInt8
    var width: UInt16
    var height: UInt16
    var extendedCompressionHeader: Data?
    var bitmapData: Data
}

struct RDPSurfaceBitsCommand: Equatable, Sendable {
    var destinationLeft: UInt16
    var destinationTop: UInt16
    var destinationRight: UInt16
    var destinationBottom: UInt16
    var bitmapData: RDPExtendedBitmapData
}

struct RDPSurfaceFrameMarkerCommand: Equatable, Sendable {
    var frameAction: UInt16
    var frameID: UInt32
}

enum RDPSurfaceCommand: Equatable, Sendable {
    case setSurfaceBits(RDPSurfaceBitsCommand)
    case streamSurfaceBits(RDPSurfaceBitsCommand)
    case frameMarker(RDPSurfaceFrameMarkerCommand)

    var typeName: String {
        switch self {
        case .setSurfaceBits:
            "surface-set-bits"
        case .streamSurfaceBits:
            "surface-stream-bits"
        case .frameMarker:
            "surface-frame-marker"
        }
    }

    static func parsePayload(_ payload: Data) throws -> [RDPSurfaceCommand] {
        guard !payload.isEmpty else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        var cursor = ByteCursor(payload)
        var commands: [RDPSurfaceCommand] = []
        while cursor.remaining > 0 {
            commands.append(try parse(from: &cursor))
        }
        return commands
    }

    private static func parse(from cursor: inout ByteCursor) throws -> RDPSurfaceCommand {
        let rawCommandType = try cursor.readLittleEndianUInt16()
        guard let commandType = RDPSurfaceCommandType(rawValue: rawCommandType) else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        switch commandType {
        case .setSurfaceBits:
            return .setSurfaceBits(try parseSurfaceBitsCommand(
                from: &cursor,
                validatesDestinationExtents: false
            ))
        case .streamSurfaceBits:
            return .streamSurfaceBits(try parseSurfaceBitsCommand(
                from: &cursor,
                validatesDestinationExtents: true
            ))
        case .frameMarker:
            let frameAction = try cursor.readLittleEndianUInt16()
            let frameID = try cursor.readLittleEndianUInt32()
            guard frameAction == 0 || frameAction == 1 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            return .frameMarker(RDPSurfaceFrameMarkerCommand(
                frameAction: frameAction,
                frameID: frameID
            ))
        }
    }

    private static func parseSurfaceBitsCommand(
        from cursor: inout ByteCursor,
        validatesDestinationExtents: Bool
    ) throws -> RDPSurfaceBitsCommand {
        let destinationLeft = try cursor.readLittleEndianUInt16()
        let destinationTop = try cursor.readLittleEndianUInt16()
        let destinationRight = try cursor.readLittleEndianUInt16()
        let destinationBottom = try cursor.readLittleEndianUInt16()
        if validatesDestinationExtents {
            guard destinationRight >= destinationLeft,
                  destinationBottom >= destinationTop
            else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
        }

        let bitmapData = try parseExtendedBitmapData(from: &cursor)
        if validatesDestinationExtents {
            guard destinationRight - destinationLeft == bitmapData.width,
                  destinationBottom - destinationTop == bitmapData.height
            else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
        }

        return RDPSurfaceBitsCommand(
            destinationLeft: destinationLeft,
            destinationTop: destinationTop,
            destinationRight: destinationRight,
            destinationBottom: destinationBottom,
            bitmapData: bitmapData
        )
    }

    private static func parseExtendedBitmapData(from cursor: inout ByteCursor) throws -> RDPExtendedBitmapData {
        let bitsPerPixel = try cursor.readUInt8()
        let flags = try cursor.readUInt8()
        let reserved = try cursor.readUInt8()
        let codecID = try cursor.readUInt8()
        let width = try cursor.readLittleEndianUInt16()
        let height = try cursor.readLittleEndianUInt16()
        let bitmapDataLength = try Int(cursor.readLittleEndianUInt32())
        let hasExtendedCompressionHeader = flags & 0x01 != 0
        guard reserved == 0,
              flags & 0xFE == 0,
              width > 0,
              height > 0
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let extendedCompressionHeader: Data?
        if hasExtendedCompressionHeader {
            extendedCompressionHeader = try cursor.readData(count: 24)
        } else {
            extendedCompressionHeader = nil
        }
        guard bitmapDataLength <= cursor.remaining else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        return RDPExtendedBitmapData(
            bitsPerPixel: bitsPerPixel,
            flags: flags,
            codecID: codecID,
            width: width,
            height: height,
            extendedCompressionHeader: extendedCompressionHeader,
            bitmapData: try cursor.readData(count: bitmapDataLength)
        )
    }
}

enum RDPSlowPathGraphicsUpdate: Equatable, Sendable {
    case orders(Data)
    case bitmap(RDPBitmapUpdate)
    case palette(RDPPaletteUpdate)
    case synchronize

    var typeName: String {
        switch self {
        case .orders:
            "update-orders"
        case .bitmap:
            "update-bitmap"
        case .palette:
            "update-palette"
        case .synchronize:
            "update-synchronize"
        }
    }

    static func parsePayload(_ payload: Data) throws -> RDPSlowPathGraphicsUpdate {
        var cursor = ByteCursor(payload)
        let rawUpdateType = try cursor.readLittleEndianUInt16()
        guard let updateType = RDPSlowPathUpdateType(rawValue: rawUpdateType) else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        switch updateType {
        case .orders:
            return .orders(cursor.readRemainingData())
        case .bitmap:
            return .bitmap(try parseBitmap(from: &cursor))
        case .palette:
            return .palette(try parsePalette(from: &cursor))
        case .synchronize:
            _ = try cursor.readLittleEndianUInt16()
            guard cursor.remaining == 0 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            return .synchronize
        }
    }

    static func parseBitmapPayload(_ payload: Data) throws -> RDPBitmapUpdate {
        var cursor = ByteCursor(payload)
        let rawUpdateType = try cursor.readLittleEndianUInt16()
        guard rawUpdateType == RDPSlowPathUpdateType.bitmap.rawValue else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        return try parseBitmap(from: &cursor)
    }

    static func parsePalettePayload(_ payload: Data) throws -> RDPPaletteUpdate {
        var cursor = ByteCursor(payload)
        let rawUpdateType = try cursor.readLittleEndianUInt16()
        guard rawUpdateType == RDPSlowPathUpdateType.palette.rawValue else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        return try parsePalette(from: &cursor)
    }

    private static func parsePalette(from cursor: inout ByteCursor) throws -> RDPPaletteUpdate {
        _ = try cursor.readLittleEndianUInt16()
        let numberColors = try cursor.readLittleEndianUInt32()
        guard numberColors == 256, cursor.remaining == 256 * 3 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        return RDPPaletteUpdate(entries: try cursor.readData(count: 256 * 3))
    }

    private static func parseBitmap(from cursor: inout ByteCursor) throws -> RDPBitmapUpdate {
        let numberRectangles = try Int(cursor.readLittleEndianUInt16())
        guard numberRectangles > 0 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        var rectangles: [RDPBitmapUpdateRectangle] = []
        rectangles.reserveCapacity(numberRectangles)
        for _ in 0 ..< numberRectangles {
            rectangles.append(try parseBitmapRectangle(from: &cursor))
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }
        return RDPBitmapUpdate(rectangles: rectangles)
    }

    private static func parseBitmapRectangle(from cursor: inout ByteCursor) throws -> RDPBitmapUpdateRectangle {
        let destinationLeft = try cursor.readLittleEndianUInt16()
        let destinationTop = try cursor.readLittleEndianUInt16()
        let destinationRight = try cursor.readLittleEndianUInt16()
        let destinationBottom = try cursor.readLittleEndianUInt16()
        let width = try cursor.readLittleEndianUInt16()
        let height = try cursor.readLittleEndianUInt16()
        let bitsPerPixel = try cursor.readLittleEndianUInt16()
        let flags = try cursor.readLittleEndianUInt16()
        let bitmapLength = try Int(cursor.readLittleEndianUInt16())
        guard destinationRight >= destinationLeft,
              destinationBottom >= destinationTop,
              width > 0,
              height > 0,
              flags & ~RDPBitmapUpdateFlags.validMask == 0,
              flags & RDPBitmapUpdateFlags.noCompressionHeader == 0 || flags & RDPBitmapUpdateFlags.compression != 0,
              bitmapLength <= cursor.remaining
        else {
            throw RDPDecodeError.invalidGraphicsUpdatePDU
        }

        let hasCompressionHeader = flags & RDPBitmapUpdateFlags.compression != 0
            && flags & RDPBitmapUpdateFlags.noCompressionHeader == 0
        let compressedHeader: Data?
        let bitmapDataStreamLength: Int
        if hasCompressionHeader {
            guard bitmapLength >= 8 else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            let header = try cursor.readData(count: 8)
            var headerCursor = ByteCursor(header)
            let compressedFirstRowSize = try headerCursor.readLittleEndianUInt16()
            let compressedMainBodySize = try Int(headerCursor.readLittleEndianUInt16())
            let scanWidth = try headerCursor.readLittleEndianUInt16()
            _ = try headerCursor.readLittleEndianUInt16()
            let dataStreamLength = bitmapLength - 8
            guard compressedFirstRowSize == 0,
                  compressedMainBodySize == dataStreamLength,
                  scanWidth.isMultiple(of: 4)
            else {
                throw RDPDecodeError.invalidGraphicsUpdatePDU
            }
            compressedHeader = header
            bitmapDataStreamLength = dataStreamLength
        } else {
            compressedHeader = nil
            bitmapDataStreamLength = bitmapLength
        }
        let bitmapDataStream = try cursor.readData(count: bitmapDataStreamLength)

        return RDPBitmapUpdateRectangle(
            destinationLeft: destinationLeft,
            destinationTop: destinationTop,
            destinationRight: destinationRight,
            destinationBottom: destinationBottom,
            width: width,
            height: height,
            bitsPerPixel: bitsPerPixel,
            flags: flags,
            compressedHeader: compressedHeader,
            bitmapDataStream: bitmapDataStream
        )
    }
}

private enum RDPBitmapUpdateFlags {
    static let compression: UInt16 = 0x0001
    static let noCompressionHeader: UInt16 = 0x0400
    static let validMask: UInt16 = compression | noCompressionHeader
}
