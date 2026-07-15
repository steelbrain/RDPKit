import Foundation

struct RDPRemoteFXDecodedTile: Equatable, Sendable {
    var x: Int
    var y: Int
    var bgraData: Data
    var bytesPerRow: Int
}

struct RDPRemoteFXDecodedFrame: Equatable, Sendable {
    var frameIndex: UInt32?
    var tiles: [RDPRemoteFXDecodedTile]
    var regionRects: [RDPFrameRect] = []
}

private struct RDPProgressiveTileKey: Hashable {
    var surfaceID: UInt16
    var codecContextID: UInt32
    var xIndex: Int
    var yIndex: Int
}

private struct RDPSubBandDiffingTileKey: Hashable {
    var surfaceID: UInt16
    var xIndex: Int
    var yIndex: Int
}

private struct RDPSubBandDiffingTileState {
    var y: [Int16]
    var cb: [Int16]
    var cr: [Int16]
    var usesReduceExtrapolate: Bool
}

private struct RDPProgressiveRefinementState {
    var y: RDPProgressiveComponentState
    var cb: RDPProgressiveComponentState
    var cr: RDPProgressiveComponentState
}

private struct RDPProgressiveTileState {
    var y: [Int16]
    var cb: [Int16]
    var cr: [Int16]
    var usesReduceExtrapolate: Bool
    var yProgressive: RDPProgressiveComponentState?
    var cbProgressive: RDPProgressiveComponentState?
    var crProgressive: RDPProgressiveComponentState?
}

private struct RDPProgressiveComponentState {
    var signs: [Int8]
    var bitPositions: [UInt8]
}

private final class RDPProgressiveReferenceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tileStates: [RDPSubBandDiffingTileKey: RDPSubBandDiffingTileState] = [:]
    private var refinementStates: [RDPProgressiveTileKey: RDPProgressiveRefinementState] = [:]

    func apply(
        key: RDPProgressiveTileKey,
        y: [Int16],
        cb: [Int16],
        cr: [Int16],
        isDifference: Bool,
        usesReduceExtrapolate: Bool,
        yProgressive: RDPProgressiveComponentState? = nil,
        cbProgressive: RDPProgressiveComponentState? = nil,
        crProgressive: RDPProgressiveComponentState? = nil
    ) throws -> RDPProgressiveTileState {
        lock.lock()
        defer { lock.unlock() }
        let tileKey = RDPSubBandDiffingTileKey(
            surfaceID: key.surfaceID,
            xIndex: key.xIndex,
            yIndex: key.yIndex
        )
        var updated = RDPSubBandDiffingTileState(
            y: y,
            cb: cb,
            cr: cr,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        if isDifference {
            guard let previous = tileStates[tileKey],
                  previous.usesReduceExtrapolate == usesReduceExtrapolate
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            for index in 0 ..< updated.y.count {
                updated.y[index] = Int16(clamping: Int(previous.y[index]) + Int(updated.y[index]))
                updated.cb[index] = Int16(clamping: Int(previous.cb[index]) + Int(updated.cb[index]))
                updated.cr[index] = Int16(clamping: Int(previous.cr[index]) + Int(updated.cr[index]))
            }
        }
        tileStates[tileKey] = updated
        if let yProgressive, let cbProgressive, let crProgressive {
            refinementStates[key] = RDPProgressiveRefinementState(
                y: yProgressive,
                cb: cbProgressive,
                cr: crProgressive
            )
        } else {
            refinementStates[key] = nil
        }
        return RDPProgressiveTileState(
            y: updated.y,
            cb: updated.cb,
            cr: updated.cr,
            usesReduceExtrapolate: updated.usesReduceExtrapolate,
            yProgressive: yProgressive,
            cbProgressive: cbProgressive,
            crProgressive: crProgressive
        )
    }

    func remove(surfaceID: UInt16) {
        lock.lock()
        tileStates = tileStates.filter { $0.key.surfaceID != surfaceID }
        refinementStates = refinementStates.filter { $0.key.surfaceID != surfaceID }
        lock.unlock()
    }

    func remove(surfaceID: UInt16, codecContextID: UInt32) {
        lock.lock()
        refinementStates = refinementStates.filter {
            $0.key.surfaceID != surfaceID || $0.key.codecContextID != codecContextID
        }
        lock.unlock()
    }

    func state(for key: RDPProgressiveTileKey) throws -> RDPProgressiveTileState {
        lock.lock()
        defer { lock.unlock() }
        let tileKey = RDPSubBandDiffingTileKey(
            surfaceID: key.surfaceID,
            xIndex: key.xIndex,
            yIndex: key.yIndex
        )
        guard let tileState = tileStates[tileKey],
              let refinementState = refinementStates[key]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPProgressiveTileState(
            y: tileState.y,
            cb: tileState.cb,
            cr: tileState.cr,
            usesReduceExtrapolate: tileState.usesReduceExtrapolate,
            yProgressive: refinementState.y,
            cbProgressive: refinementState.cb,
            crProgressive: refinementState.cr
        )
    }

    func replace(_ state: RDPProgressiveTileState, for key: RDPProgressiveTileKey) {
        lock.lock()
        let tileKey = RDPSubBandDiffingTileKey(
            surfaceID: key.surfaceID,
            xIndex: key.xIndex,
            yIndex: key.yIndex
        )
        tileStates[tileKey] = RDPSubBandDiffingTileState(
            y: state.y,
            cb: state.cb,
            cr: state.cr,
            usesReduceExtrapolate: state.usesReduceExtrapolate
        )
        if let yProgressive = state.yProgressive,
           let cbProgressive = state.cbProgressive,
           let crProgressive = state.crProgressive
        {
            refinementStates[key] = RDPProgressiveRefinementState(
                y: yProgressive,
                cb: cbProgressive,
                cr: crProgressive
            )
        }
        lock.unlock()
    }
}

private final class RDPProgressiveTileDecodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedTiles: [RDPRemoteFXDecodedTile?]
    private var firstError: Error?

    init(tileCount: Int) {
        decodedTiles = Array(repeating: nil, count: tileCount)
    }

    var shouldSkipDecode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstError != nil
    }

    func store(_ tile: RDPRemoteFXDecodedTile, at index: Int) {
        lock.lock()
        decodedTiles[index] = tile
        lock.unlock()
    }

    func store(_ error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func resolvedTiles(expectedCount: Int) throws -> [RDPRemoteFXDecodedTile] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError {
            throw firstError
        }

        let tiles = decodedTiles.compactMap { $0 }
        guard tiles.count == expectedCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return tiles
    }
}

final class RDPRemoteFXDecoder {
    private static let minimumParallelProgressiveTileCount = 8
    private static let originalProgressiveLL3Range = 4032 ..< 4096
    private static let originalProgressiveBandRanges = [
        0 ..< 1024,
        1024 ..< 2048,
        2048 ..< 3072,
        3072 ..< 3328,
        3328 ..< 3584,
        3584 ..< 3840,
        3840 ..< 3904,
        3904 ..< 3968,
        3968 ..< 4032,
        originalProgressiveLL3Range,
    ]
    private static let progressiveLL3Range = 4015 ..< 4096
    private static let progressiveBandRanges = [
        0 ..< 1023,
        1023 ..< 2046,
        2046 ..< 3007,
        3007 ..< 3279,
        3279 ..< 3551,
        3551 ..< 3807,
        3807 ..< 3879,
        3879 ..< 3951,
        3951 ..< 4015,
        progressiveLL3Range,
    ]

    private enum BlockType {
        static let tile: UInt16 = 0xCAC3
        static let sync: UInt16 = 0xCCC0
        static let progressiveFrameBegin: UInt16 = 0xCCC1
        static let progressiveFrameEnd: UInt16 = 0xCCC2
        static let progressiveContext: UInt16 = 0xCCC3
        static let progressiveRegion: UInt16 = 0xCCC4
        static let progressiveTileSimple: UInt16 = 0xCCC5
        static let progressiveTileFirst: UInt16 = 0xCCC6
        static let progressiveTileUpgrade: UInt16 = 0xCCC7
        static let codecVersions: UInt16 = 0xCCC1
        static let channels: UInt16 = 0xCCC2
        static let context: UInt16 = 0xCCC3
        static let frameBegin: UInt16 = 0xCCC4
        static let frameEnd: UInt16 = 0xCCC5
        static let region: UInt16 = 0xCCC6
        static let tileSet: UInt16 = 0xCCC7
    }

    private enum EntropyAlgorithm {
        case rlgr1
        case rlgr3
    }

    private enum ClassicDataBlockState {
        case frameBegin
        case region
        case tileSet
        case frameEnd
    }

    private enum PropertyMask {
        static let dwt: UInt16 = 0x01E0
        static let tileSetEntropy: UInt16 = 0x3C00
    }

    private enum PropertyValue {
        static let dwt53A: UInt16 = 0x0020
    }

    private struct Block {
        var type: UInt16
        var body: Data
    }

    struct Quant: Equatable {
        var ll3: UInt8
        var lh3: UInt8
        var hl3: UInt8
        var hh3: UInt8
        var lh2: UInt8
        var hl2: UInt8
        var hh2: UInt8
        var lh1: UInt8
        var hl1: UInt8
        var hh1: UInt8
    }

    private struct Tile {
        var yQuantIndex: Int
        var cbQuantIndex: Int
        var crQuantIndex: Int
        var xIndex: Int
        var yIndex: Int
        var yData: Data
        var cbData: Data
        var crData: Data
    }

    private struct ProgressiveQuant {
        var y: Quant
        var cb: Quant
        var cr: Quant
    }

    private var channelWidth: Int?
    private var channelHeight: Int?
    private var hasClassicSync = false
    private var hasClassicCodecVersions = false
    private var hasClassicChannels = false
    private var hasClassicContext = false
    private var classicDataBlockState: ClassicDataBlockState = .frameBegin
    private var classicRegionRects: [RDPFrameRect] = []
    private let progressiveReferenceStore = RDPProgressiveReferenceStore()

    func decodeProgressive(
        _ data: Data,
        surfaceID: UInt16 = 0,
        codecContextID: UInt32 = 0,
        permitsUpgrade: Bool = true
    ) throws -> RDPRemoteFXDecodedFrame {
        var cursor = ByteCursor(data)
        var frameIndex: UInt32?
        var expectedRegionCount: Int?
        var regionCount = 0
        var decodedTiles: [RDPRemoteFXDecodedTile] = []
        var decodedRegionRects: [RDPFrameRect] = []
        var hasSeenBlock = false
        var hasSeenFrameBegin = false
        var hasSeenFrameEnd = false
        var isInsideFrame = false

        while cursor.remaining > 0 {
            let block = try Self.readBlock(from: &cursor)
            switch block.type {
            case BlockType.sync:
                if !hasSeenBlock {
                    try Self.parseProgressiveSync(block.body)
                }
            case BlockType.progressiveContext:
                try Self.parseProgressiveContext(block.body)
            case BlockType.progressiveFrameBegin:
                guard !hasSeenFrameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let frameBegin = try Self.parseProgressiveFrameBegin(block.body)
                frameIndex = frameBegin.frameIndex
                expectedRegionCount = frameBegin.regionCount
                hasSeenFrameBegin = true
                isInsideFrame = true
            case BlockType.progressiveRegion:
                guard isInsideFrame else {
                    break
                }
                regionCount += 1
                let region = try decodeProgressiveRegion(
                    block.body,
                    surfaceID: surfaceID,
                    codecContextID: codecContextID,
                    permitsUpgrade: permitsUpgrade
                )
                decodedTiles += region.tiles
                decodedRegionRects += region.rectangles
            case BlockType.progressiveFrameEnd:
                guard isInsideFrame, !hasSeenFrameEnd else {
                    break
                }
                guard block.body.isEmpty else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                hasSeenFrameEnd = true
                isInsideFrame = false
            default:
                break
            }
            hasSeenBlock = true
        }

        if let expectedRegionCount,
           expectedRegionCount < regionCount {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return RDPRemoteFXDecodedFrame(
            frameIndex: frameIndex,
            tiles: decodedTiles,
            regionRects: decodedRegionRects
        )
    }

    func removeProgressiveState(surfaceID: UInt16) {
        progressiveReferenceStore.remove(surfaceID: surfaceID)
    }

    func removeProgressiveState(surfaceID: UInt16, codecContextID: UInt32) {
        progressiveReferenceStore.remove(surfaceID: surfaceID, codecContextID: codecContextID)
    }

    func decode(_ data: Data) throws -> RDPRemoteFXDecodedFrame {
        var cursor = ByteCursor(data)
        var frameIndex: UInt32?
        var decodedTiles: [RDPRemoteFXDecodedTile] = []
        var decodedRegionRects: [RDPFrameRect] = []

        while cursor.remaining > 0 {
            let block = try Self.readBlock(from: &cursor)
            guard hasClassicSync || block.type == BlockType.sync else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            switch block.type {
            case BlockType.sync:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseSync(block.body)
                hasClassicSync = true
            case BlockType.codecVersions:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseCodecVersions(block.body)
                hasClassicCodecVersions = true
            case BlockType.channels:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try parseChannels(block.body)
                hasClassicChannels = true
            case BlockType.context:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseContext(block.body)
                hasClassicContext = true
            case BlockType.frameBegin:
                guard classicDataBlockState == .frameBegin,
                      hasClassicCodecVersions,
                      hasClassicChannels,
                      hasClassicContext
                else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                frameIndex = try Self.parseFrameBegin(block.body)
                classicRegionRects = []
                classicDataBlockState = .region
            case BlockType.region:
                guard classicDataBlockState == .region else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                classicRegionRects = try parseRegion(block.body)
                decodedRegionRects = classicRegionRects
                classicDataBlockState = .tileSet
            case BlockType.tileSet:
                guard classicDataBlockState == .tileSet else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                decodedTiles += try decodeTileSet(block.body)
                decodedRegionRects = classicRegionRects
                classicDataBlockState = .frameEnd
            case BlockType.frameEnd:
                guard classicDataBlockState == .frameEnd else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseFrameEnd(block.body)
                classicRegionRects = []
                classicDataBlockState = .frameBegin
            default:
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        return RDPRemoteFXDecodedFrame(
            frameIndex: frameIndex,
            tiles: decodedTiles,
            regionRects: decodedRegionRects
        )
    }

    private static func readBlock(from cursor: inout ByteCursor) throws -> Block {
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
        return Block(
            type: blockType,
            body: try cursor.readData(count: Int(blockLength - 6))
        )
    }

    private static func parseCodecChannelHeader(_ cursor: inout ByteCursor, channelID: UInt8) throws {
        guard cursor.remaining >= 2,
              try cursor.readUInt8() == 1,
              try cursor.readUInt8() == channelID
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
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

    private static func parseProgressiveSync(_ data: Data) throws {
        guard data.count == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseProgressiveContext(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 4 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        guard try cursor.readLittleEndianUInt16() == 64 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
    }

    private static func parseProgressiveFrameBegin(_ data: Data) throws -> (
        frameIndex: UInt32,
        regionCount: Int
    ) {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let frameIndex = try cursor.readLittleEndianUInt32()
        let regionCount = try Int(cursor.readLittleEndianUInt16())
        return (frameIndex, regionCount)
    }

    private static func parseCodecVersions(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 4,
              try cursor.readUInt8() == 1
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        _ = try cursor.readLittleEndianUInt16()
    }

    private func parseChannels(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let channelCount = try Int(cursor.readUInt8())
        guard channelCount > 0,
              cursor.remaining == channelCount * 5
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        for channelIndex in 0 ..< channelCount {
            guard try cursor.readUInt8() == 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let width = try Int(cursor.readLittleEndianUInt16())
            let height = try Int(cursor.readLittleEndianUInt16())
            if channelIndex == 0 {
                channelWidth = width
                channelHeight = height
            }
        }
    }

    private static func parseContext(_ data: Data) throws {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0xFF)
        guard cursor.remaining == 5 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        guard try cursor.readLittleEndianUInt16() == 64,
              try cursor.readLittleEndianUInt16() & PropertyMask.dwt == PropertyValue.dwt53A
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func parseFrameBegin(_ data: Data) throws -> UInt32 {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining == 6 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let frameIndex = try cursor.readLittleEndianUInt32()
        guard try cursor.readLittleEndianUInt16() == 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return frameIndex
    }

    private static func parseFrameEnd(_ data: Data) throws {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private func parseRegion(_ data: Data) throws -> [RDPFrameRect] {
        var cursor = ByteCursor(data)
        try Self.parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 7 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        guard let channelWidth,
              let channelHeight,
              channelWidth > 0,
              channelHeight > 0,
              cursor.remaining >= rectangleCount * 8 + 4
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var rectangles: [RDPFrameRect] = []
        rectangles.reserveCapacity(max(rectangleCount, 1))
        for _ in 0 ..< rectangleCount {
            let left = try Int(cursor.readLittleEndianUInt16())
            let top = try Int(cursor.readLittleEndianUInt16())
            let right = min(left + (try Int(cursor.readLittleEndianUInt16())), channelWidth)
            let bottom = min(top + (try Int(cursor.readLittleEndianUInt16())), channelHeight)
            if right > left, bottom > top, left < channelWidth, top < channelHeight {
                rectangles.append(RDPFrameRect(
                    left: UInt16(left),
                    top: UInt16(top),
                    right: UInt16(right),
                    bottom: UInt16(bottom)
                ))
            }
        }
        guard try cursor.readLittleEndianUInt16() == 0xCAC1,
              try cursor.readLittleEndianUInt16() == 1,
              cursor.remaining == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if rectangleCount == 0 {
            rectangles.append(RDPFrameRect(
                left: 0,
                top: 0,
                right: UInt16(channelWidth),
                bottom: UInt16(channelHeight)
            ))
        }
        return rectangles
    }

    private func decodeTileSet(_ data: Data) throws -> [RDPRemoteFXDecodedTile] {
        var cursor = ByteCursor(data)
        try Self.parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 14,
              try cursor.readLittleEndianUInt16() == 0xCAC2
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readLittleEndianUInt16()
        let properties = try cursor.readLittleEndianUInt16()
        let entropyAlgorithm = try Self.entropyAlgorithm(fromTileSetProperties: properties)
        let quantCount = try Int(cursor.readUInt8())
        _ = try cursor.readUInt8()
        let expectedTileCount = try Int(cursor.readLittleEndianUInt16())
        let tilesDataSize = try Int(cursor.readLittleEndianUInt32())
        guard cursor.remaining == quantCount * 5 + tilesDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var quants: [Quant] = []
        quants.reserveCapacity(quantCount)
        for _ in 0 ..< quantCount {
            quants.append(try Self.parseQuant(from: &cursor))
        }

        var tileCursor = ByteCursor(try cursor.readData(count: tilesDataSize))
        var tiles: [Tile] = []
        tiles.reserveCapacity(expectedTileCount)
        while tileCursor.remaining > 0 {
            tiles.append(try Self.parseTileBlock(from: &tileCursor))
        }
        guard tiles.count == expectedTileCount,
              cursor.remaining == 0
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return try tiles.map { tile in
            guard tile.yQuantIndex < quants.count,
                  tile.cbQuantIndex < quants.count,
                  tile.crQuantIndex < quants.count
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let y = try Self.decodeComponent(
                tile.yData,
                quant: quants[tile.yQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            let cb = try Self.decodeComponent(
                tile.cbData,
                quant: quants[tile.cbQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            let cr = try Self.decodeComponent(
                tile.crData,
                quant: quants[tile.crQuantIndex],
                entropyAlgorithm: entropyAlgorithm
            )
            return RDPRemoteFXDecodedTile(
                x: tile.xIndex * 64,
                y: tile.yIndex * 64,
                bgraData: Self.bgraData(y: y, cb: cb, cr: cr),
                bytesPerRow: 64 * 4
            )
        }
    }

    private func decodeProgressiveRegion(
        _ data: Data,
        surfaceID: UInt16,
        codecContextID: UInt32,
        permitsUpgrade: Bool
    ) throws -> (tiles: [RDPRemoteFXDecodedTile], rectangles: [RDPFrameRect]) {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 12 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let tileSize = try cursor.readUInt8()
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        let quantCount = try Int(cursor.readUInt8())
        let progressiveQuantCount = try Int(cursor.readUInt8())
        let flags = try cursor.readUInt8()
        let expectedTileCount = try Int(cursor.readLittleEndianUInt16())
        let tileDataSize = try Int(cursor.readLittleEndianUInt32())
        guard tileSize == 64,
              rectangleCount > 0,
              quantCount <= 7,
              flags & 0xFE == 0,
              cursor.remaining >= rectangleCount * 8 + quantCount * 5 + progressiveQuantCount * 16
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        var rectangles: [RDPFrameRect] = []
        rectangles.reserveCapacity(rectangleCount)
        for _ in 0 ..< rectangleCount {
            let left = try cursor.readLittleEndianUInt16()
            let top = try cursor.readLittleEndianUInt16()
            let width = try cursor.readLittleEndianUInt16()
            let height = try cursor.readLittleEndianUInt16()
            let (right, rightOverflow) = left.addingReportingOverflow(width)
            let (bottom, bottomOverflow) = top.addingReportingOverflow(height)
            guard !rightOverflow,
                  !bottomOverflow,
                  right > left,
                  bottom > top
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            rectangles.append(RDPFrameRect(left: left, top: top, right: right, bottom: bottom))
        }
        var quants: [Quant] = []
        quants.reserveCapacity(quantCount)
        for _ in 0 ..< quantCount {
            quants.append(try Self.parseProgressiveQuant(from: &cursor))
        }
        var progressiveQuants: [ProgressiveQuant] = []
        progressiveQuants.reserveCapacity(progressiveQuantCount)
        for _ in 0 ..< progressiveQuantCount {
            progressiveQuants.append(try Self.parseProgressiveCodecQuant(from: &cursor))
        }

        guard cursor.remaining == tileDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let tileBlocks = try Self.parseProgressiveTileBlocks(try cursor.readData(count: tileDataSize))
        guard tileBlocks.count == expectedTileCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let tiles = try decodeProgressiveTiles(
            tileBlocks,
            quants: quants,
            progressiveQuants: progressiveQuants,
            surfaceID: surfaceID,
            codecContextID: codecContextID,
            permitsUpgrade: permitsUpgrade,
            usesReduceExtrapolate: flags & 0x01 != 0
        )
        return (tiles, rectangles)
    }

    private static func parseProgressiveTileBlocks(_ data: Data) throws -> [Data] {
        var tileCursor = ByteCursor(data)
        var blocks: [Data] = []
        while tileCursor.remaining > 0 {
            let blockStart = tileCursor.currentOffset
            _ = try readBlock(from: &tileCursor)
            blocks.append(data.subdata(in: blockStart ..< tileCursor.currentOffset))
        }
        return blocks
    }

    private func decodeProgressiveTiles(
        _ tileBlocks: [Data],
        quants: [Quant],
        progressiveQuants: [ProgressiveQuant],
        surfaceID: UInt16,
        codecContextID: UInt32,
        permitsUpgrade: Bool,
        usesReduceExtrapolate: Bool
    ) throws -> [RDPRemoteFXDecodedTile] {
        let referenceStore = progressiveReferenceStore
        let tileDependencies = try tileBlocks.map(Self.progressiveTileDependency)
        let tileKeys = tileDependencies.map(\.key)
        let hasDuplicateTile = Set(tileKeys).count != tileKeys.count
        let requiresSequentialDecode = tileDependencies.contains { $0.dependsOnPreviousState }
            || hasDuplicateTile
        guard tileBlocks.count >= Self.minimumParallelProgressiveTileCount,
              !requiresSequentialDecode
        else {
            return try tileBlocks.map { tileBlock in
                var tileCursor = ByteCursor(tileBlock)
                return try Self.decodeProgressiveTile(
                    from: &tileCursor,
                    quants: quants,
                    progressiveQuants: progressiveQuants,
                    surfaceID: surfaceID,
                    codecContextID: codecContextID,
                    permitsUpgrade: permitsUpgrade,
                    usesReduceExtrapolate: usesReduceExtrapolate,
                    referenceStore: referenceStore
                )
            }
        }

        let state = RDPProgressiveTileDecodeState(tileCount: tileBlocks.count)
        DispatchQueue.concurrentPerform(iterations: tileBlocks.count) { index in
            guard state.shouldSkipDecode == false else {
                return
            }

            do {
                var tileCursor = ByteCursor(tileBlocks[index])
                let tile = try Self.decodeProgressiveTile(
                    from: &tileCursor,
                    quants: quants,
                    progressiveQuants: progressiveQuants,
                    surfaceID: surfaceID,
                    codecContextID: codecContextID,
                    permitsUpgrade: permitsUpgrade,
                    usesReduceExtrapolate: usesReduceExtrapolate,
                    referenceStore: referenceStore
                )
                state.store(tile, at: index)
            } catch {
                state.store(error)
            }
        }
        return try state.resolvedTiles(expectedCount: tileBlocks.count)
    }

    private static func progressiveTileDependency(
        _ data: Data
    ) throws -> (key: RDPProgressiveTileKey, dependsOnPreviousState: Bool) {
        var cursor = ByteCursor(data)
        let block = try readBlock(from: &cursor)
        var body = ByteCursor(block.body)
        guard block.type == BlockType.progressiveTileSimple
            || block.type == BlockType.progressiveTileFirst
            || block.type == BlockType.progressiveTileUpgrade,
            body.remaining >= 7
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try body.readData(count: 3)
        let xIndex = try Int(body.readLittleEndianUInt16())
        let yIndex = try Int(body.readLittleEndianUInt16())
        let key = RDPProgressiveTileKey(surfaceID: 0, codecContextID: 0, xIndex: xIndex, yIndex: yIndex)
        if block.type == BlockType.progressiveTileUpgrade {
            return (key, true)
        }
        let flags = try body.readUInt8()
        return (key, flags & 0x01 != 0)
    }

    private static func decodeProgressiveTile(
        from cursor: inout ByteCursor,
        quants: [Quant],
        progressiveQuants: [ProgressiveQuant],
        surfaceID: UInt16,
        codecContextID: UInt32,
        permitsUpgrade: Bool,
        usesReduceExtrapolate: Bool,
        referenceStore: RDPProgressiveReferenceStore
    ) throws -> RDPRemoteFXDecodedTile {
        let block = try readBlock(from: &cursor)
        if block.type == BlockType.progressiveTileUpgrade {
            guard permitsUpgrade else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            return try decodeProgressiveUpgradeTile(
                block.body,
                quants: quants,
                progressiveQuants: progressiveQuants,
                surfaceID: surfaceID,
                codecContextID: codecContextID,
                usesReduceExtrapolate: usesReduceExtrapolate,
                referenceStore: referenceStore
            )
        }
        guard block.type == BlockType.progressiveTileSimple
            || block.type == BlockType.progressiveTileFirst
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var bodyCursor = ByteCursor(block.body)
        let minimumBodyLength = block.type == BlockType.progressiveTileFirst ? 17 : 16
        guard bodyCursor.remaining >= minimumBodyLength else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let yQuantIndex = try Int(bodyCursor.readUInt8())
        let cbQuantIndex = try Int(bodyCursor.readUInt8())
        let crQuantIndex = try Int(bodyCursor.readUInt8())
        let xIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let yIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let tileFlags = try bodyCursor.readUInt8()
        let progressiveQuality = block.type == BlockType.progressiveTileFirst
            ? try Int(bodyCursor.readUInt8())
            : nil
        let yByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let cbByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let crByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let tailByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        guard bodyCursor.remaining == yByteCount + cbByteCount + crByteCount + tailByteCount,
              yQuantIndex < quants.count,
              cbQuantIndex < quants.count,
              crQuantIndex < quants.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        let isDifference = tileFlags & 0x01 != 0
        let yData = try bodyCursor.readData(count: yByteCount)
        let cbData = try bodyCursor.readData(count: cbByteCount)
        let crData = try bodyCursor.readData(count: crByteCount)
        _ = try bodyCursor.readData(count: tailByteCount)
        if let progressiveQuality {
            let selectedProgressiveQuant = try progressiveQuant(
                at: progressiveQuality,
                from: progressiveQuants
            )
            let y = try decodeProgressiveFirstComponent(
                yData,
                quant: quants[yQuantIndex],
                progressiveQuant: selectedProgressiveQuant.y,
                usesReduceExtrapolate: usesReduceExtrapolate
            )
            let cb = try decodeProgressiveFirstComponent(
                cbData,
                quant: quants[cbQuantIndex],
                progressiveQuant: selectedProgressiveQuant.cb,
                usesReduceExtrapolate: usesReduceExtrapolate
            )
            let cr = try decodeProgressiveFirstComponent(
                crData,
                quant: quants[crQuantIndex],
                progressiveQuant: selectedProgressiveQuant.cr,
                usesReduceExtrapolate: usesReduceExtrapolate
            )
            let updated = try referenceStore.apply(
                key: RDPProgressiveTileKey(
                    surfaceID: surfaceID,
                    codecContextID: codecContextID,
                    xIndex: xIndex,
                    yIndex: yIndex
                ),
                y: y.coefficients,
                cb: cb.coefficients,
                cr: cr.coefficients,
                isDifference: isDifference,
                usesReduceExtrapolate: usesReduceExtrapolate,
                yProgressive: y.state,
                cbProgressive: cb.state,
                crProgressive: cr.state
            )
            return decodedProgressiveTile(xIndex: xIndex, yIndex: yIndex, state: updated)
        }

        let y = try decodeProgressiveComponent(
            yData,
            quant: quants[yQuantIndex],
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        let cb = try decodeProgressiveComponent(
            cbData,
            quant: quants[cbQuantIndex],
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        let cr = try decodeProgressiveComponent(
            crData,
            quant: quants[crQuantIndex],
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        let updated = try referenceStore.apply(
            key: RDPProgressiveTileKey(
                surfaceID: surfaceID,
                codecContextID: codecContextID,
                xIndex: xIndex,
                yIndex: yIndex
            ),
            y: y,
            cb: cb,
            cr: cr,
            isDifference: isDifference,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        return decodedProgressiveTile(xIndex: xIndex, yIndex: yIndex, state: updated)
    }

    private static func decodedProgressiveTile(
        xIndex: Int,
        yIndex: Int,
        state: RDPProgressiveTileState
    ) -> RDPRemoteFXDecodedTile {
        var decodedY = state.y
        var decodedCb = state.cb
        var decodedCr = state.cr
        if state.usesReduceExtrapolate {
            Self.decodeProgressiveDWT(&decodedY)
            Self.decodeProgressiveDWT(&decodedCb)
            Self.decodeProgressiveDWT(&decodedCr)
        } else {
            var temp = [Int16](repeating: 0, count: 64 * 64)
            Self.decodeDWT(&decodedY, temp: &temp)
            Self.decodeDWT(&decodedCb, temp: &temp)
            Self.decodeDWT(&decodedCr, temp: &temp)
        }
        return RDPRemoteFXDecodedTile(
            x: xIndex * 64,
            y: yIndex * 64,
            bgraData: Self.bgraData(y: decodedY, cb: decodedCb, cr: decodedCr),
            bytesPerRow: 64 * 4
        )
    }

    private static func decodeProgressiveUpgradeTile(
        _ data: Data,
        quants: [Quant],
        progressiveQuants: [ProgressiveQuant],
        surfaceID: UInt16,
        codecContextID: UInt32,
        usesReduceExtrapolate: Bool,
        referenceStore: RDPProgressiveReferenceStore
    ) throws -> RDPRemoteFXDecodedTile {
        var cursor = ByteCursor(data)
        guard cursor.remaining >= 20 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let yQuantIndex = try Int(cursor.readUInt8())
        let cbQuantIndex = try Int(cursor.readUInt8())
        let crQuantIndex = try Int(cursor.readUInt8())
        let xIndex = try Int(cursor.readLittleEndianUInt16())
        let yIndex = try Int(cursor.readLittleEndianUInt16())
        let progressiveQuality = try Int(cursor.readUInt8())
        let lengths = try (0 ..< 6).map { _ in try Int(cursor.readLittleEndianUInt16()) }
        guard yQuantIndex < quants.count,
              cbQuantIndex < quants.count,
              crQuantIndex < quants.count,
              cursor.remaining == lengths.reduce(0, +)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let streams = try lengths.map { try cursor.readData(count: $0) }
        let targetQuant = try progressiveQuant(at: progressiveQuality, from: progressiveQuants)
        let key = RDPProgressiveTileKey(
            surfaceID: surfaceID,
            codecContextID: codecContextID,
            xIndex: xIndex,
            yIndex: yIndex
        )
        var state = try referenceStore.state(for: key)
        guard state.usesReduceExtrapolate == usesReduceExtrapolate,
              let yProgressive = state.yProgressive,
              let cbProgressive = state.cbProgressive,
              let crProgressive = state.crProgressive
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        (state.y, state.yProgressive) = try decodeProgressiveUpgradeComponent(
            coefficients: state.y,
            state: yProgressive,
            regularQuant: quants[yQuantIndex],
            targetQuant: targetQuant.y,
            usesReduceExtrapolate: usesReduceExtrapolate,
            srlData: streams[0],
            rawData: streams[1]
        )
        (state.cb, state.cbProgressive) = try decodeProgressiveUpgradeComponent(
            coefficients: state.cb,
            state: cbProgressive,
            regularQuant: quants[cbQuantIndex],
            targetQuant: targetQuant.cb,
            usesReduceExtrapolate: usesReduceExtrapolate,
            srlData: streams[2],
            rawData: streams[3]
        )
        (state.cr, state.crProgressive) = try decodeProgressiveUpgradeComponent(
            coefficients: state.cr,
            state: crProgressive,
            regularQuant: quants[crQuantIndex],
            targetQuant: targetQuant.cr,
            usesReduceExtrapolate: usesReduceExtrapolate,
            srlData: streams[4],
            rawData: streams[5]
        )
        referenceStore.replace(state, for: key)
        return decodedProgressiveTile(xIndex: xIndex, yIndex: yIndex, state: state)
    }

    private static func decodeProgressiveUpgradeComponent(
        coefficients: [Int16],
        state: RDPProgressiveComponentState,
        regularQuant: Quant,
        targetQuant: Quant,
        usesReduceExtrapolate: Bool,
        srlData: Data,
        rawData: Data
    ) throws -> ([Int16], RDPProgressiveComponentState) {
        var updatedCoefficients = coefficients
        var updatedState = state
        let targetBitPositions = progressiveBitPositions(
            targetQuant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        guard state.signs.count == coefficients.count,
              state.bitPositions.count == coefficients.count
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var bitCounts = [Int](repeating: 0, count: coefficients.count)
        for index in coefficients.indices {
            guard state.bitPositions[index] >= targetBitPositions[index] else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            bitCounts[index] = Int(state.bitPositions[index] - targetBitPositions[index])
        }
        let ll3Range = progressiveLL3Range(usesReduceExtrapolate: usesReduceExtrapolate)
        let srlIndices = coefficients.indices.filter {
            $0 < ll3Range.lowerBound && bitCounts[$0] > 0 && state.signs[$0] == 0
        }
        var srlReader = RDPProgressiveSRLReader(srlData)
        var srlValues = [Int: Int16]()
        srlValues.reserveCapacity(srlIndices.count)
        for (position, index) in srlIndices.enumerated() {
            srlValues[index] = try srlReader.readValue(
                magnitudeBitCount: bitCounts[index],
                remainingValueCount: srlIndices.count - position
            )
        }
        var rawReader = BitReader(rawData)
        let regularFactors = progressiveBitPositions(
            regularQuant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        guard regularFactors.allSatisfy({ $0 >= 1 }) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let regularShifts = regularFactors.map { Int($0 - 1) }
        for index in coefficients.indices where bitCounts[index] > 0 {
            let input: Int
            if let srlValue = srlValues[index] {
                input = Int(srlValue)
                if srlValue < 0 {
                    updatedState.signs[index] = -1
                } else if srlValue > 0 {
                    updatedState.signs[index] = 1
                }
            } else {
                guard let rawValue = rawReader.readBits(count: bitCounts[index]) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                input = index < ll3Range.lowerBound && state.signs[index] < 0
                    ? -Int(rawValue)
                    : Int(rawValue)
            }
            let shift = Int(targetBitPositions[index]) + regularShifts[index]
            updatedCoefficients[index] = updatedCoefficients[index]
                &+ Int16(truncatingIfNeeded: input << shift)
        }
        updatedState.bitPositions = targetBitPositions
        return (updatedCoefficients, updatedState)
    }

    private static func progressiveQuant(
        at index: Int,
        from quants: [ProgressiveQuant]
    ) throws -> ProgressiveQuant {
        if index == 0xFF {
            let fullQuality = Quant(
                ll3: 0, lh3: 0, hl3: 0, hh3: 0,
                lh2: 0, hl2: 0, hh2: 0,
                lh1: 0, hl1: 0, hh1: 0
            )
            return ProgressiveQuant(y: fullQuality, cb: fullQuality, cr: fullQuality)
        }
        guard index < quants.count else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return quants[index]
    }

    private static func decodeProgressiveFirstComponent(
        _ data: Data,
        quant: Quant,
        progressiveQuant: Quant,
        usesReduceExtrapolate: Bool
    ) throws -> (coefficients: [Int16], state: RDPProgressiveComponentState) {
        guard !data.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var coefficients = [Int16](repeating: 0, count: 64 * 64)
        try decodeRLGR(data, algorithm: .rlgr1, output: &coefficients)
        let ll3Range = progressiveLL3Range(usesReduceExtrapolate: usesReduceExtrapolate)
        decodeDifferential(
            &coefficients,
            start: ll3Range.lowerBound,
            count: ll3Range.count
        )
        var signs = coefficients.map { value -> Int8 in
            value < 0 ? -1 : (value > 0 ? 1 : 0)
        }
        for index in ll3Range {
            signs[index] = 0
        }
        let bitPositions = progressiveBitPositions(
            progressiveQuant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        decodeProgressiveQuantization(
            &coefficients,
            quant: progressiveQuant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        try decodeProgressiveRegularQuantization(
            &coefficients,
            quant: quant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        return (
            coefficients,
            RDPProgressiveComponentState(signs: signs, bitPositions: bitPositions)
        )
    }

    private static func decodeProgressiveComponent(
        _ data: Data,
        quant: Quant,
        usesReduceExtrapolate: Bool
    ) throws -> [Int16] {
        guard !data.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var buffer = [Int16](repeating: 0, count: 64 * 64)
        try decodeRLGR(data, algorithm: .rlgr1, output: &buffer)
        let ll3Range = progressiveLL3Range(usesReduceExtrapolate: usesReduceExtrapolate)
        decodeDifferential(
            &buffer,
            start: ll3Range.lowerBound,
            count: ll3Range.count
        )
        try decodeProgressiveRegularQuantization(
            &buffer,
            quant: quant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        return buffer
    }

    private static func parseQuant(from cursor: inout ByteCursor) throws -> Quant {
        let ll3lh3 = try cursor.readUInt8()
        let hl3hh3 = try cursor.readUInt8()
        let lh2hl2 = try cursor.readUInt8()
        let hh2lh1 = try cursor.readUInt8()
        let hl1hh1 = try cursor.readUInt8()
        let quant = Quant(
            ll3: ll3lh3 & 0x0F,
            lh3: ll3lh3 >> 4,
            hl3: hl3hh3 & 0x0F,
            hh3: hl3hh3 >> 4,
            lh2: lh2hl2 & 0x0F,
            hl2: lh2hl2 >> 4,
            hh2: hh2lh1 & 0x0F,
            lh1: hh2lh1 >> 4,
            hl1: hl1hh1 & 0x0F,
            hh1: hl1hh1 >> 4
        )
        guard quantFactors(quant).allSatisfy({ 6 ... 15 ~= $0 }) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return quant
    }

    static func parseProgressiveQuant(from cursor: inout ByteCursor) throws -> Quant {
        let ll3hl3 = try cursor.readUInt8()
        let lh3hh3 = try cursor.readUInt8()
        let hl2lh2 = try cursor.readUInt8()
        let hh2hl1 = try cursor.readUInt8()
        let lh1hh1 = try cursor.readUInt8()
        return Quant(
            ll3: ll3hl3 & 0x0F,
            lh3: lh3hh3 & 0x0F,
            hl3: ll3hl3 >> 4,
            hh3: lh3hh3 >> 4,
            lh2: hl2lh2 >> 4,
            hl2: hl2lh2 & 0x0F,
            hh2: hh2hl1 & 0x0F,
            lh1: lh1hh1 & 0x0F,
            hl1: hh2hl1 >> 4,
            hh1: lh1hh1 >> 4
        )
    }

    private static func parseProgressiveCodecQuant(from cursor: inout ByteCursor) throws -> ProgressiveQuant {
        _ = try cursor.readUInt8()
        let y = try parseProgressiveQuant(from: &cursor)
        let cb = try parseProgressiveQuant(from: &cursor)
        let cr = try parseProgressiveQuant(from: &cursor)
        guard quantFactors(y).allSatisfy({ $0 <= 8 }),
              quantFactors(cb).allSatisfy({ $0 <= 8 }),
              quantFactors(cr).allSatisfy({ $0 <= 8 })
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return ProgressiveQuant(y: y, cb: cb, cr: cr)
    }

    private static func quantFactors(_ quant: Quant) -> [UInt8] {
        [
            quant.hl1, quant.lh1, quant.hh1,
            quant.hl2, quant.lh2, quant.hh2,
            quant.hl3, quant.lh3, quant.hh3,
            quant.ll3,
        ]
    }

    private static func progressiveBitPositions(
        _ quant: Quant,
        usesReduceExtrapolate: Bool
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 64 * 64)
        let factors = quantFactors(quant)
        let ranges = progressiveBandRanges(usesReduceExtrapolate: usesReduceExtrapolate)
        for (range, factor) in zip(ranges, factors) {
            for index in range {
                result[index] = factor
            }
        }
        return result
    }

    private static func decodeProgressiveQuantization(
        _ buffer: inout [Int16],
        quant: Quant,
        usesReduceExtrapolate: Bool
    ) {
        let factors = progressiveBitPositions(
            quant,
            usesReduceExtrapolate: usesReduceExtrapolate
        )
        for index in buffer.indices where factors[index] > 0 {
            buffer[index] = Int16(truncatingIfNeeded: Int(buffer[index]) << Int(factors[index]))
        }
    }

    private static func decodeProgressiveRegularQuantization(
        _ buffer: inout [Int16],
        quant: Quant,
        usesReduceExtrapolate: Bool
    ) throws {
        let ranges = progressiveBandRanges(usesReduceExtrapolate: usesReduceExtrapolate)
        for (range, factor) in zip(ranges, quantFactors(quant)) {
            try shift(buffer: &buffer, range: range, factor: factor)
        }
    }

    private static func progressiveBandRanges(usesReduceExtrapolate: Bool) -> [Range<Int>] {
        usesReduceExtrapolate ? progressiveBandRanges : originalProgressiveBandRanges
    }

    private static func progressiveLL3Range(usesReduceExtrapolate: Bool) -> Range<Int> {
        usesReduceExtrapolate ? progressiveLL3Range : originalProgressiveLL3Range
    }

    private static func parseTileBlock(from cursor: inout ByteCursor) throws -> Tile {
        let block = try readBlock(from: &cursor)
        guard block.type == BlockType.tile else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var bodyCursor = ByteCursor(block.body)
        guard bodyCursor.remaining >= 13 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let yQuantIndex = try Int(bodyCursor.readUInt8())
        let cbQuantIndex = try Int(bodyCursor.readUInt8())
        let crQuantIndex = try Int(bodyCursor.readUInt8())
        let xIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let yIndex = try Int(bodyCursor.readLittleEndianUInt16())
        let yByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let cbByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        let crByteCount = try Int(bodyCursor.readLittleEndianUInt16())
        guard bodyCursor.remaining == yByteCount + cbByteCount + crByteCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return Tile(
            yQuantIndex: yQuantIndex,
            cbQuantIndex: cbQuantIndex,
            crQuantIndex: crQuantIndex,
            xIndex: xIndex,
            yIndex: yIndex,
            yData: try bodyCursor.readData(count: yByteCount),
            cbData: try bodyCursor.readData(count: cbByteCount),
            crData: try bodyCursor.readData(count: crByteCount)
        )
    }

    private static func entropyAlgorithm(from bits: UInt16) throws -> EntropyAlgorithm {
        switch bits {
        case 0x01:
            return .rlgr1
        case 0x04:
            return .rlgr3
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
    }

    private static func entropyAlgorithm(fromTileSetProperties properties: UInt16) throws -> EntropyAlgorithm {
        return try entropyAlgorithm(from: (properties & PropertyMask.tileSetEntropy) >> 10)
    }

    private static func decodeComponent(
        _ data: Data,
        quant: Quant,
        entropyAlgorithm: EntropyAlgorithm
    ) throws -> [Int16] {
        guard !data.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var buffer = [Int16](repeating: 0, count: 64 * 64)
        try decodeRLGR(data, algorithm: entropyAlgorithm, output: &buffer)
        decodeDifferential(&buffer, start: 4032, count: 64)
        try decodeQuantization(&buffer, quant: quant)
        var temp = [Int16](repeating: 0, count: 64 * 64)
        decodeDWT(&buffer, temp: &temp)
        return buffer
    }

    private static func decodeRLGR(_ data: Data, algorithm: EntropyAlgorithm, output: inout [Int16]) throws {
        var k: UInt32 = 1
        var kr: UInt32 = 1
        var kp = k << 3
        var krp = kr << 3
        var outputIndex = 0
        var bits = BitReader(data)

        while outputIndex < output.count {
            guard !bits.isEmpty else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            if k != 0 {
                let leadingZeros = bits.consumeLeading(bit: 0)
                let leadingRun = countRun(
                    leadingZeros,
                    k: &k,
                    kp: &kp,
                    limit: output.count - outputIndex
                )
                if leadingRun > 0 {
                    for index in outputIndex ..< outputIndex + leadingRun {
                        output[index] = 0
                    }
                    outputIndex += leadingRun
                }
                guard outputIndex < output.count else {
                    break
                }
                guard bits.readBits(count: 1) != nil else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                guard let runRemainder = bits.readBits(count: Int(k)) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let remainderRun = min(Int(runRemainder), output.count - outputIndex)
                if remainderRun > 0 {
                    for index in outputIndex ..< outputIndex + remainderRun {
                        output[index] = 0
                    }
                    outputIndex += remainderRun
                }
                guard outputIndex < output.count else {
                    break
                }

                guard let signBit = bits.readBits(count: 1) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let leadingOnes = bits.consumeLeading(bit: 1)
                guard bits.readBits(count: 1) != nil,
                      let codeRemainderBits = bits.readBits(count: Int(kr))
                else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let codeRemainder = codeRemainderBits + (UInt32(leadingOnes) << kr)
                updateGRParameters(leadingOnes, kr: &kr, krp: &krp)
                kp = kp.saturatingSubtracting(6)
                k = kp >> 3
                let magnitude = try rlMagnitude(signBit: signBit, codeRemainder: codeRemainder)

                output[outputIndex] = magnitude
                outputIndex += 1
            } else {
                let leadingOnes = bits.consumeLeading(bit: 1)
                guard bits.readBits(count: 1) != nil,
                      let codeRemainderBits = bits.readBits(count: Int(kr))
                else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let codeRemainder = codeRemainderBits + (UInt32(leadingOnes) << kr)
                updateGRParameters(leadingOnes, kr: &kr, krp: &krp)

                switch algorithm {
                case .rlgr1:
                    let magnitude = try rlgr1Magnitude(codeRemainder: codeRemainder, k: &k, kp: &kp)
                    if outputIndex < output.count {
                        output[outputIndex] = magnitude
                        outputIndex += 1
                    }
                case .rlgr3:
                    let nIndex = nIndex(codeRemainder)
                    guard let val1 = bits.readBits(count: nIndex) else {
                        throw RDPDecodeError.invalidRDPGFXPDU
                    }
                    guard val1 <= codeRemainder else {
                        throw RDPDecodeError.invalidRDPGFXPDU
                    }
                    let val2 = codeRemainder - val1
                    if val1 != 0, val2 != 0 {
                        kp = kp.saturatingSubtracting(6)
                        k = kp >> 3
                    } else if val1 == 0, val2 == 0 {
                        kp = min(kp + 6, 80)
                        k = kp >> 3
                    }
                    if outputIndex < output.count {
                        output[outputIndex] = try rlgr3Magnitude(val1)
                        outputIndex += 1
                    }
                    if outputIndex < output.count {
                        output[outputIndex] = try rlgr3Magnitude(val2)
                        outputIndex += 1
                    }
                }
            }
        }

    }

    private static func countRun(
        _ leadingZeros: Int,
        k: inout UInt32,
        kp: inout UInt32,
        limit: Int
    ) -> Int {
        var run = 0
        for _ in 0 ..< leadingZeros {
            run = min(limit, run + Int(1 << k))
            kp = min(kp + 4, 80)
            k = kp >> 3
        }
        return run
    }

    private static func updateGRParameters(_ leadingOnes: Int, kr: inout UInt32, krp: inout UInt32) {
        if leadingOnes == 0 {
            krp = krp.saturatingSubtracting(2)
        } else if leadingOnes > 1 {
            krp = min(krp + UInt32(leadingOnes), 80)
        }
        kr = krp >> 3
    }

    private static func rlMagnitude(signBit: UInt32, codeRemainder: UInt32) throws -> Int16 {
        guard codeRemainder < UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let magnitude = Int16(codeRemainder + 1)
        return signBit == 0 ? magnitude : -magnitude
    }

    private static func rlgr1Magnitude(codeRemainder: UInt32, k: inout UInt32, kp: inout UInt32) throws -> Int16 {
        if codeRemainder == 0 {
            kp = min(kp + 3, 80)
            k = kp >> 3
            return 0
        }

        kp = kp.saturatingSubtracting(3)
        k = kp >> 3
        let magnitude = codeRemainder.isMultiple(of: 2)
            ? codeRemainder >> 1
            : (codeRemainder + 1) >> 1
        guard magnitude <= UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let value = Int16(magnitude)
        return codeRemainder.isMultiple(of: 2) ? value : -value
    }

    private static func rlgr3Magnitude(_ value: UInt32) throws -> Int16 {
        let magnitude = value.isMultiple(of: 2) ? value >> 1 : (value + 1) >> 1
        guard magnitude <= UInt32(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let decoded = Int16(magnitude)
        return value.isMultiple(of: 2) ? decoded : -decoded
    }

    private static func nIndex(_ value: UInt32) -> Int {
        value == 0 ? 0 : 32 - value.leadingZeroBitCount
    }

    private static func decodeDifferential(_ buffer: inout [Int16], start: Int, count: Int) {
        guard count > 1 else {
            return
        }
        for index in start + 1 ..< start + count {
            buffer[index] = buffer[index] &+ buffer[index - 1]
        }
    }

    private static func decodeQuantization(_ buffer: inout [Int16], quant: Quant) throws {
        try shift(buffer: &buffer, range: 0 ..< 1024, factor: quant.hl1)
        try shift(buffer: &buffer, range: 1024 ..< 2048, factor: quant.lh1)
        try shift(buffer: &buffer, range: 2048 ..< 3072, factor: quant.hh1)
        try shift(buffer: &buffer, range: 3072 ..< 3328, factor: quant.hl2)
        try shift(buffer: &buffer, range: 3328 ..< 3584, factor: quant.lh2)
        try shift(buffer: &buffer, range: 3584 ..< 3840, factor: quant.hh2)
        try shift(buffer: &buffer, range: 3840 ..< 3904, factor: quant.hl3)
        try shift(buffer: &buffer, range: 3904 ..< 3968, factor: quant.lh3)
        try shift(buffer: &buffer, range: 3968 ..< 4032, factor: quant.hh3)
        try shift(buffer: &buffer, range: 4032 ..< 4096, factor: quant.ll3)
    }

    private static func shift(buffer: inout [Int16], range: Range<Int>, factor quant: UInt8) throws {
        guard quant >= 1 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let shift = Int(quant - 1)
        guard shift > 0 else {
            return
        }
        for index in range {
            buffer[index] = Int16(truncatingIfNeeded: Int(buffer[index]) << shift)
        }
    }

    private static func decodeDWT(_ buffer: inout [Int16], temp: inout [Int16]) {
        decodeDWTBlock(buffer: &buffer, start: 3840, temp: &temp, subbandWidth: 8)
        decodeDWTBlock(buffer: &buffer, start: 3072, temp: &temp, subbandWidth: 16)
        decodeDWTBlock(buffer: &buffer, start: 0, temp: &temp, subbandWidth: 32)
    }

    static func decodeProgressiveDWT(_ buffer: inout [Int16]) {
        let level3 = inverseProgressiveDWTBlock(
            buffer,
            start: 3807,
            lowWidth: 9,
            lowHeight: 9,
            serializedHighWidth: 8,
            serializedHighHeight: 8
        )
        buffer.replaceSubrange(3807 ..< 4096, with: level3)

        let level2 = inverseProgressiveDWTBlock(
            buffer,
            start: 3007,
            lowWidth: 17,
            lowHeight: 17,
            serializedHighWidth: 16,
            serializedHighHeight: 16
        )
        buffer.replaceSubrange(3007 ..< 4096, with: level2)

        let level1 = inverseProgressiveDWTBlock(
            buffer,
            start: 0,
            lowWidth: 33,
            lowHeight: 33,
            serializedHighWidth: 31,
            serializedHighHeight: 31
        )
        buffer.replaceSubrange(0 ..< 4096, with: level1)
    }

    private static func inverseProgressiveDWTBlock(
        _ buffer: [Int16],
        start: Int,
        lowWidth: Int,
        lowHeight: Int,
        serializedHighWidth: Int,
        serializedHighHeight: Int
    ) -> [Int16] {
        let totalWidth = lowWidth + serializedHighWidth
        let totalHeight = lowHeight + serializedHighHeight
        let hlBase = start
        let lhBase = hlBase + serializedHighWidth * lowHeight
        let hhBase = lhBase + lowWidth * serializedHighHeight
        let llBase = hhBase + serializedHighWidth * serializedHighHeight
        var horizontal = [Int16](repeating: 0, count: totalWidth * totalHeight)
        inverseProgressiveDWTLines(
            source: buffer,
            lowBase: llBase,
            lowElementStep: 1,
            lowLineStep: lowWidth,
            highBase: hlBase,
            highElementStep: 1,
            highLineStep: serializedHighWidth,
            destination: &horizontal,
            destinationBase: 0,
            destinationElementStep: 1,
            destinationLineStep: totalWidth,
            lowCount: lowWidth,
            highCount: serializedHighWidth,
            lineCount: lowHeight
        )
        inverseProgressiveDWTLines(
            source: buffer,
            lowBase: lhBase,
            lowElementStep: 1,
            lowLineStep: lowWidth,
            highBase: hhBase,
            highElementStep: 1,
            highLineStep: serializedHighWidth,
            destination: &horizontal,
            destinationBase: lowHeight * totalWidth,
            destinationElementStep: 1,
            destinationLineStep: totalWidth,
            lowCount: lowWidth,
            highCount: serializedHighWidth,
            lineCount: serializedHighHeight
        )

        var output = [Int16](repeating: 0, count: totalWidth * totalHeight)
        inverseProgressiveDWTLines(
            source: horizontal,
            lowBase: 0,
            lowElementStep: totalWidth,
            lowLineStep: 1,
            highBase: lowHeight * totalWidth,
            highElementStep: totalWidth,
            highLineStep: 1,
            destination: &output,
            destinationBase: 0,
            destinationElementStep: totalWidth,
            destinationLineStep: 1,
            lowCount: lowHeight,
            highCount: serializedHighHeight,
            lineCount: totalWidth
        )
        return output
    }

    private static func inverseProgressiveDWTLines(
        source: [Int16],
        lowBase: Int,
        lowElementStep: Int,
        lowLineStep: Int,
        highBase: Int,
        highElementStep: Int,
        highLineStep: Int,
        destination: inout [Int16],
        destinationBase: Int,
        destinationElementStep: Int,
        destinationLineStep: Int,
        lowCount: Int,
        highCount: Int,
        lineCount: Int
    ) {
        precondition(lowCount == highCount + 1 || lowCount == highCount + 2)
        for line in 0 ..< lineCount {
            var lowIndex = lowBase + line * lowLineStep
            var highIndex = highBase + line * highLineStep
            var destinationIndex = destinationBase + line * destinationLineStep
            var high0 = Int(source[highIndex])
            var even0 = clampToInt16(Int(source[lowIndex]) - high0)
            var even2 = even0
            for _ in 0 ..< highCount - 1 {
                highIndex += highElementStep
                lowIndex += lowElementStep
                let high1 = Int(source[highIndex])
                even2 = clampToInt16(
                    Int(source[lowIndex]) - (high0 + high1) / 2
                )
                destination[destinationIndex] = even0
                destinationIndex += destinationElementStep
                destination[destinationIndex] = clampToInt16(
                    (Int(even0) + Int(even2)) / 2 + 2 * high0
                )
                destinationIndex += destinationElementStep
                even0 = even2
                high0 = high1
            }

            lowIndex += lowElementStep
            if lowCount == highCount + 1 {
                even0 = clampToInt16(Int(source[lowIndex]) - high0)
                destination[destinationIndex] = even2
                destinationIndex += destinationElementStep
                destination[destinationIndex] = clampToInt16(
                    (Int(even0) + Int(even2)) / 2 + 2 * high0
                )
                destinationIndex += destinationElementStep
                destination[destinationIndex] = even0
            } else {
                even0 = clampToInt16(Int(source[lowIndex]) - high0 / 2)
                destination[destinationIndex] = even2
                destinationIndex += destinationElementStep
                destination[destinationIndex] = clampToInt16(
                    (Int(even0) + Int(even2)) / 2 + 2 * high0
                )
                destinationIndex += destinationElementStep
                destination[destinationIndex] = even0
                lowIndex += lowElementStep
                destinationIndex += destinationElementStep
                destination[destinationIndex] = clampToInt16(
                    (Int(even0) + Int(source[lowIndex])) / 2
                )
            }
        }
    }

    private static func decodeDWTBlock(
        buffer: inout [Int16],
        start: Int,
        temp: inout [Int16],
        subbandWidth: Int
    ) {
        inverseHorizontal(buffer: buffer, start: start, temp: &temp, subbandWidth: subbandWidth)
        inverseVertical(buffer: &buffer, start: start, temp: temp, subbandWidth: subbandWidth)
    }

    private static func inverseHorizontal(
        buffer: [Int16],
        start: Int,
        temp: inout [Int16],
        subbandWidth: Int
    ) {
        let totalWidth = subbandWidth * 2
        let squared = subbandWidth * subbandWidth
        let hlBase = start
        let lhBase = start + squared
        let hhBase = start + squared * 2
        let llBase = start + squared * 3
        let hBase = squared * 2

        for row in 0 ..< subbandWidth {
            let subbandRow = row * subbandWidth
            let dstRow = row * totalWidth

            temp[dstRow] = wrapToInt16(
                Int(buffer[llBase + subbandRow]) - ((Int(buffer[hlBase + subbandRow]) * 2 + 1) >> 1)
            )
            temp[hBase + dstRow] = wrapToInt16(
                Int(buffer[lhBase + subbandRow]) - ((Int(buffer[hhBase + subbandRow]) * 2 + 1) >> 1)
            )

            for n in 1 ..< subbandWidth {
                let x = n * 2
                temp[dstRow + x] = wrapToInt16(
                    Int(buffer[llBase + subbandRow + n])
                        - ((Int(buffer[hlBase + subbandRow + n - 1]) + Int(buffer[hlBase + subbandRow + n]) + 1) >> 1)
                )
                temp[hBase + dstRow + x] = wrapToInt16(
                    Int(buffer[lhBase + subbandRow + n])
                        - ((Int(buffer[hhBase + subbandRow + n - 1]) + Int(buffer[hhBase + subbandRow + n]) + 1) >> 1)
                )
            }

            for n in 0 ..< subbandWidth - 1 {
                let x = n * 2
                temp[dstRow + x + 1] = wrapToInt16(
                    (Int(buffer[hlBase + subbandRow + n]) << 1)
                        + ((Int(temp[dstRow + x]) + Int(temp[dstRow + x + 2])) >> 1)
                )
                temp[hBase + dstRow + x + 1] = wrapToInt16(
                    (Int(buffer[hhBase + subbandRow + n]) << 1)
                        + ((Int(temp[hBase + dstRow + x]) + Int(temp[hBase + dstRow + x + 2])) >> 1)
                )
            }

            let n = subbandWidth - 1
            let x = n * 2
            temp[dstRow + x + 1] = wrapToInt16(
                (Int(buffer[hlBase + subbandRow + n]) << 1) + Int(temp[dstRow + x])
            )
            temp[hBase + dstRow + x + 1] = wrapToInt16(
                (Int(buffer[hhBase + subbandRow + n]) << 1) + Int(temp[hBase + dstRow + x])
            )
        }
    }

    private static func inverseVertical(
        buffer: inout [Int16],
        start: Int,
        temp: [Int16],
        subbandWidth: Int
    ) {
        let totalWidth = subbandWidth * 2
        let hBase = subbandWidth * subbandWidth * 2

        for column in 0 ..< totalWidth {
            buffer[start + column] = wrapToInt16(
                Int(temp[column]) - ((Int(temp[hBase + column]) * 2 + 1) >> 1)
            )

            for n in 1 ..< subbandWidth {
                let lIndex = n * totalWidth + column
                let hPreviousIndex = hBase + (n - 1) * totalWidth + column
                let hIndex = hBase + n * totalWidth + column
                let dstBase = start + (n - 1) * 2 * totalWidth + column
                let evenIndex = dstBase + 2 * totalWidth
                let oddIndex = dstBase + totalWidth

                buffer[evenIndex] = wrapToInt16(
                    Int(temp[lIndex]) - ((Int(temp[hPreviousIndex]) + Int(temp[hIndex]) + 1) >> 1)
                )
                buffer[oddIndex] = wrapToInt16(
                    (Int(temp[hPreviousIndex]) << 1)
                        + ((Int(buffer[dstBase]) + Int(buffer[evenIndex])) >> 1)
                )
            }

            let lastDst = start + (subbandWidth - 1) * 2 * totalWidth + column
            let hLast = hBase + (subbandWidth - 1) * totalWidth + column
            buffer[lastDst + totalWidth] = wrapToInt16(
                (Int(temp[hLast]) << 1) + ((Int(buffer[lastDst]) * 2) >> 1)
            )
        }
    }

    private static func bgraData(y: [Int16], cb: [Int16], cr: [Int16]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for index in 0 ..< 64 * 64 {
            let yValue = (Int(y[index]) + 4096) << 16
            let cbValue = Int(cb[index])
            let crValue = Int(cr[index])
            let red = (crValue * 91_916 + yValue) >> 21
            let green = (yValue - cbValue * 22_527 - crValue * 46_819) >> 21
            let blue = (cbValue * 115_992 + yValue) >> 21
            let offset = index * 4
            bytes[offset] = clip(blue)
            bytes[offset + 1] = clip(green)
            bytes[offset + 2] = clip(red)
            bytes[offset + 3] = 0xFF
        }
        return Data(bytes)
    }

    private static func clip(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }

    private static func wrapToInt16(_ value: Int) -> Int16 {
        Int16(truncatingIfNeeded: value)
    }

    private static func clampToInt16(_ value: Int) -> Int16 {
        Int16(clamping: value)
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isEmpty: Bool {
        bitOffset >= bytes.count * 8
    }

    mutating func consumeLeading(bit: UInt32) -> Int {
        var count = 0
        while let next = peekBit(), next == bit {
            bitOffset += 1
            count += 1
        }
        return count
    }

    mutating func readBits(count: Int) -> UInt32? {
        guard count >= 0,
              bytes.count * 8 - bitOffset >= count
        else {
            return nil
        }
        var value: UInt32 = 0
        for _ in 0 ..< count {
            value = (value << 1) | (readBit() ?? 0)
        }
        return value
    }

    private func peekBit() -> UInt32? {
        guard !isEmpty else {
            return nil
        }
        let byte = bytes[bitOffset / 8]
        let shift = 7 - bitOffset % 8
        return UInt32((byte >> UInt8(shift)) & 0x01)
    }

    private mutating func readBit() -> UInt32? {
        guard let bit = peekBit() else {
            return nil
        }
        bitOffset += 1
        return bit
    }
}

struct RDPProgressiveSRLReader {
    private var bits: BitReader
    private var kp = 8
    private var pendingZeroCount = 0
    private var expectsNonzero = false

    init(_ data: Data) {
        bits = BitReader(data)
    }

    mutating func readValue(magnitudeBitCount: Int, remainingValueCount: Int) throws -> Int16 {
        guard magnitudeBitCount > 0, remainingValueCount > 0 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if pendingZeroCount > 0 {
            pendingZeroCount -= 1
            return 0
        }
        if expectsNonzero {
            expectsNonzero = false
            return try readNonzero(magnitudeBitCount: magnitudeBitCount)
        }

        var zeroCount = 0
        while true {
            guard let marker = bits.readBits(count: 1) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            let k = kp / 8
            if marker == 1 {
                guard let remainder = bits.readBits(count: k) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                zeroCount += Int(remainder)
                kp = max(0, kp - 6)
                break
            }
            zeroCount += 1 << k
            if zeroCount >= remainingValueCount {
                zeroCount = remainingValueCount
                break
            }
            kp = min(80, kp + 4)
        }
        guard zeroCount <= remainingValueCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if zeroCount > 0 {
            pendingZeroCount = zeroCount - 1
            expectsNonzero = zeroCount < remainingValueCount
            return 0
        }
        return try readNonzero(magnitudeBitCount: magnitudeBitCount)
    }

    private mutating func readNonzero(magnitudeBitCount: Int) throws -> Int16 {
        guard magnitudeBitCount < Int.bitWidth - 1,
              let sign = bits.readBits(count: 1)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let maximumMagnitude = (1 << magnitudeBitCount) - 1
        var magnitude = 1
        while magnitude < maximumMagnitude {
            guard let terminator = bits.readBits(count: 1) else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            if terminator == 1 {
                break
            }
            magnitude += 1
        }
        guard magnitude <= Int(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let value = Int16(magnitude)
        return sign == 0 ? value : -value
    }
}

private extension UInt32 {
    func saturatingSubtracting(_ value: UInt32) -> UInt32 {
        self > value ? self - value : 0
    }
}
