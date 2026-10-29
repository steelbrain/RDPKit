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
        _ = try cursor.readLittleEndianUInt16() // flags: unused (MS-RDPEGFX 2.2.1.5)
        let pduLength = try Int(cursor.readLittleEndianUInt32())
        guard pduLength >= 8, pduLength - 8 <= cursor.remaining else {
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

/// TS_MONITOR_DEF ([MS-RDPBCGR] 2.2.1.3.6.1): a monitor in desktop coordinates, which put the
/// primary monitor's top-left at 0,0, so the others' can be negative. Right and bottom are
/// inclusive.
struct RDPMonitorDefinition: Equatable, Sendable {
    static let primary: UInt32 = 0x0000_0001

    var left: Int32
    var top: Int32
    var right: Int32
    var bottom: Int32
    var flags: UInt32

    static func parse(_ cursor: inout ByteCursor) throws -> RDPMonitorDefinition {
        try RDPMonitorDefinition(
            left: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            top: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            right: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            bottom: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            flags: cursor.readLittleEndianUInt32()
        )
    }
}

struct RDPGFXResetGraphicsPDU: Equatable, Sendable {
    static let maximumDimension: UInt32 = 32_766
    static let maximumMonitorCount: UInt32 = 16

    var width: UInt32
    var height: UInt32
    var monitors: [RDPMonitorDefinition]

    /// The monitors where they are in the graphics output, in the server's order. The output
    /// holds the desktop from the smallest left and top of any monitor. Each monitor is
    /// clipped to the output, and one with nothing in it is left out: KRdp 6.8 sends right
    /// and bottom exclusive (Fixtures/krdp-negotiation-transcript.json, sequence 39: monitor
    /// (0,0)-(3840,2400) in a 3840x2400 output), which clipping reads as the whole output.
    var outputMonitors: [RDPRemoteMonitor] {
        guard let originX = monitors.map(\.left).min(),
              let originY = monitors.map(\.top).min()
        else {
            return []
        }
        func outputCoordinate(_ value: Int, origin: Int32, limit: UInt32) -> UInt16 {
            UInt16(min(max(value - Int(origin), 0), Int(limit)))
        }
        return monitors.compactMap { monitor in
            let rect = RDPFrameRect(
                left: outputCoordinate(Int(monitor.left), origin: originX, limit: width),
                top: outputCoordinate(Int(monitor.top), origin: originY, limit: height),
                right: outputCoordinate(Int(monitor.right) + 1, origin: originX, limit: width),
                bottom: outputCoordinate(Int(monitor.bottom) + 1, origin: originY, limit: height)
            )
            guard rect.width > 0, rect.height > 0 else {
                return nil
            }
            return RDPRemoteMonitor(rect: rect, isPrimary: monitor.flags & RDPMonitorDefinition.primary != 0)
        }
    }

    /// The PDU is always 340 bytes long; padding follows monitorDefArray.
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
        let monitors = try (0 ..< monitorCount).map { _ in try RDPMonitorDefinition.parse(&cursor) }
        return RDPGFXResetGraphicsPDU(width: width, height: height, monitors: monitors)
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
        _ = try cursor.readLittleEndianUInt16() // reserved
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
        _ = try cursor.readLittleEndianUInt16() // reserved
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

        // Nothing reads the timestamp, so its field ranges (MS-RDPEGFX 2.2.2.11) are not checked.
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

final class RDPGFXServerTransportDecoder {
    private let zgfx = RDPZGFXDecompressor()

    /// Unwraps the RDP_SEGMENTED_DATA that carries every server message (MS-RDPEGFX
    /// 2.2.5.1) and returns all the graphics messages it contains.
    func decodeGraphicsMessages(from data: Data) throws -> [RDPGFXHeader] {
        var cursor = try ByteCursor(zgfx.decompress(data))
        var messages: [RDPGFXHeader] = []
        while cursor.remaining > 0 {
            try messages.append(RDPGFXHeader.parse(from: &cursor))
        }
        return messages
    }
}
