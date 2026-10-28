import Foundation

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
