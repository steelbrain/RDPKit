import Foundation

public struct RDPRemotePointerImage: Equatable, Sendable {
    public var cacheIndex: UInt16
    public var hotSpot: RDPRemotePoint
    public var width: UInt16
    public var height: UInt16
    public var xorBitsPerPixel: UInt16
    public var xorMaskData: Data
    /// Empty for a 32-bpp pointer sent without an AND mask; its XOR alpha channel alone defines the shape.
    public var andMaskData: Data

    public init(
        cacheIndex: UInt16,
        hotSpot: RDPRemotePoint,
        width: UInt16,
        height: UInt16,
        xorBitsPerPixel: UInt16,
        xorMaskData: Data,
        andMaskData: Data
    ) {
        self.cacheIndex = cacheIndex
        self.hotSpot = hotSpot
        self.width = width
        self.height = height
        self.xorBitsPerPixel = xorBitsPerPixel
        self.xorMaskData = xorMaskData
        self.andMaskData = andMaskData
    }
}

public enum RDPRemotePointerUpdate: Equatable, Sendable {
    case position(RDPRemotePoint)
    case hidden
    case systemDefault
    case image(RDPRemotePointerImage)
    case cachedImage(RDPRemotePointerImage)
    case unresolvedCachedImage(cacheIndex: UInt16)
}

struct RDPPoint16: Equatable, Sendable {
    var x: UInt16
    var y: UInt16

    static func parse(from cursor: inout ByteCursor) throws -> RDPPoint16 {
        RDPPoint16(
            x: try cursor.readLittleEndianUInt16(),
            y: try cursor.readLittleEndianUInt16()
        )
    }
}

struct RDPColorPointerAttribute: Equatable, Sendable {
    var cacheIndex: UInt16
    var hotSpot: RDPPoint16
    var width: UInt16
    var height: UInt16
    var xorMaskData: Data
    var andMaskData: Data

    // TS_COLORPOINTERATTRIBUTE (MS-RDPBCGR 2.2.9.1.1.4.4); TS_POINTERATTRIBUTE wraps it with another XOR depth.
    static func parse(
        from cursor: inout ByteCursor,
        xorBitsPerPixel: UInt16 = 24
    ) throws -> RDPColorPointerAttribute {
        try parse(from: &cursor, xorBitsPerPixel: xorBitsPerPixel, isLarge: false)
    }

    // TS_FP_LARGEPOINTERATTRIBUTE after xorBpp (2.2.9.1.2.1.11): 32-bit mask lengths and up to 384x384 pixels.
    static func parseLargeFastPath(
        from cursor: inout ByteCursor,
        xorBitsPerPixel: UInt16
    ) throws -> RDPColorPointerAttribute {
        try parse(from: &cursor, xorBitsPerPixel: xorBitsPerPixel, isLarge: true)
    }

    private static func parse(
        from cursor: inout ByteCursor,
        xorBitsPerPixel: UInt16,
        isLarge: Bool
    ) throws -> RDPColorPointerAttribute {
        guard cursor.remaining >= (isLarge ? 18 : 14) else {
            throw RDPDecodeError.invalidPointerPDU
        }

        let cacheIndex = try cursor.readLittleEndianUInt16()
        let hotSpot = try RDPPoint16.parse(from: &cursor)
        let width = try cursor.readLittleEndianUInt16()
        let height = try cursor.readLittleEndianUInt16()
        let andMaskLength = try isLarge ? Int(cursor.readLittleEndianUInt32()) : Int(cursor.readLittleEndianUInt16())
        let xorMaskLength = try isLarge ? Int(cursor.readLittleEndianUInt32()) : Int(cursor.readLittleEndianUInt16())
        let maximumDimension: UInt16 = isLarge ? 384 : 96
        // KRdp sends 32-bpp pointers without an AND mask (lengthAndMask = 0).
        let omitsAndMask = andMaskLength == 0 && xorBitsPerPixel == 32
        guard width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              xorMaskLength == pointerMaskByteCount(width: width, height: height, bitsPerPixel: xorBitsPerPixel),
              omitsAndMask || andMaskLength == pointerMaskByteCount(width: width, height: height, bitsPerPixel: 1),
              xorMaskLength + andMaskLength <= cursor.remaining
        else {
            throw RDPDecodeError.invalidPointerPDU
        }

        let xorMaskData = try cursor.readData(count: xorMaskLength)
        let andMaskData = try cursor.readData(count: andMaskLength)
        // The optional pad byte MUST be ignored.
        if cursor.remaining == 1 {
            _ = try cursor.readUInt8()
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidPointerPDU
        }

        return RDPColorPointerAttribute(
            cacheIndex: cacheIndex,
            hotSpot: hotSpot,
            width: width,
            height: height,
            xorMaskData: xorMaskData,
            andMaskData: andMaskData
        )
    }
}

struct RDPNewPointerAttribute: Equatable, Sendable {
    var xorBitsPerPixel: UInt16
    var colorPointer: RDPColorPointerAttribute
}

enum RDPServerPointerUpdate: Equatable, Sendable {
    case position(RDPPoint16)
    case system(type: UInt32)
    case color(RDPColorPointerAttribute)
    case cached(cacheIndex: UInt16)
    case pointer(RDPNewPointerAttribute)
    case largePointer(RDPNewPointerAttribute)

    var typeName: String {
        switch self {
        case .position:
            "pointer-position"
        case let .system(type):
            switch type {
            case 0x0000_0000:
                "pointer-system-hidden"
            case 0x0000_7F00:
                "pointer-system-default"
            default:
                "pointer-system-0x\(String(format: "%08x", type))"
            }
        case .color:
            "pointer-color"
        case .cached:
            "pointer-cached"
        case .pointer:
            "pointer-new"
        case .largePointer:
            "pointer-large"
        }
    }

    static func parsePayload(_ payload: Data) throws -> RDPServerPointerUpdate {
        guard payload.count >= 4 else {
            throw RDPDecodeError.invalidPointerPDU
        }

        var cursor = ByteCursor(payload)
        let messageType = try cursor.readLittleEndianUInt16()
        _ = try cursor.readLittleEndianUInt16()
        switch messageType {
        case 0x0001:
            let systemPointerType = try cursor.readLittleEndianUInt32()
            guard cursor.remaining == 0,
                  systemPointerType == 0x0000_0000 || systemPointerType == 0x0000_7F00
            else {
                throw RDPDecodeError.invalidPointerPDU
            }
            return .system(type: systemPointerType)
        case 0x0003:
            let position = try RDPPoint16.parse(from: &cursor)
            guard cursor.remaining == 0 else {
                throw RDPDecodeError.invalidPointerPDU
            }
            return .position(position)
        case 0x0006:
            return .color(try RDPColorPointerAttribute.parse(from: &cursor))
        case 0x0007:
            let cacheIndex = try cursor.readLittleEndianUInt16()
            guard cursor.remaining == 0 else {
                throw RDPDecodeError.invalidPointerPDU
            }
            return .cached(cacheIndex: cacheIndex)
        case 0x0008:
            let xorBitsPerPixel = try cursor.readLittleEndianUInt16()
            let colorPointer = try RDPColorPointerAttribute.parse(
                from: &cursor,
                xorBitsPerPixel: xorBitsPerPixel
            )
            return .pointer(RDPNewPointerAttribute(
                xorBitsPerPixel: xorBitsPerPixel,
                colorPointer: colorPointer
            ))
        default:
            throw RDPDecodeError.invalidPointerPDU
        }
    }
}

final class RDPRemotePointerState {
    // Matches the pointerCacheSize advertised in the client Pointer Capability Set.
    static let cacheSize: UInt16 = 32

    private var images: [UInt16: RDPRemotePointerImage] = [:]

    func apply(_ update: RDPServerPointerUpdate) throws -> RDPRemotePointerUpdate {
        switch update {
        case let .position(point):
            return .position(RDPRemotePoint(x: point.x, y: point.y))
        case let .system(type):
            switch type {
            case 0x0000_0000:
                return .hidden
            case 0x0000_7F00:
                return .systemDefault
            default:
                throw RDPDecodeError.invalidPointerPDU
            }
        case let .color(attribute):
            return try cache(attribute, xorBitsPerPixel: 24)
        case let .pointer(attribute), let .largePointer(attribute):
            return try cache(attribute.colorPointer, xorBitsPerPixel: attribute.xorBitsPerPixel)
        case let .cached(cacheIndex):
            guard cacheIndex < Self.cacheSize else {
                throw RDPDecodeError.invalidPointerPDU
            }
            guard let image = images[cacheIndex] else {
                return .unresolvedCachedImage(cacheIndex: cacheIndex)
            }
            return .cachedImage(image)
        }
    }

    private func cache(
        _ attribute: RDPColorPointerAttribute,
        xorBitsPerPixel: UInt16
    ) throws -> RDPRemotePointerUpdate {
        guard attribute.cacheIndex < Self.cacheSize else {
            throw RDPDecodeError.invalidPointerPDU
        }
        // MS-RDPBCGR 2.2.9.1.1.4.4 does not bound hotSpot. Clamp it onto the image so clients need no
        // range check; no target server is known to send one outside (FreeRDP resets such a coordinate to 0).
        let image = RDPRemotePointerImage(
            cacheIndex: attribute.cacheIndex,
            hotSpot: RDPRemotePoint(
                x: min(attribute.hotSpot.x, max(attribute.width, 1) - 1),
                y: min(attribute.hotSpot.y, max(attribute.height, 1) - 1)
            ),
            width: attribute.width,
            height: attribute.height,
            xorBitsPerPixel: xorBitsPerPixel,
            xorMaskData: attribute.xorMaskData,
            andMaskData: attribute.andMaskData
        )
        images[attribute.cacheIndex] = image
        return .image(image)
    }
}

// Mask scan-lines are padded to a 2-byte boundary (2.2.9.1.1.4.4); nil for an unusable depth.
private func pointerMaskByteCount(width: UInt16, height: UInt16, bitsPerPixel: UInt16) -> Int? {
    guard bitsPerPixel > 0 else {
        return nil
    }
    let rowBytes = (Int(width) * Int(bitsPerPixel) + 7) / 8
    return ((rowBytes + 1) & ~1) * Int(height)
}
