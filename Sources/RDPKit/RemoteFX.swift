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
    var regionRects: [RDPFrameRect]
}

/// Dequantized DWT coefficients of a tile, Y, Cb and Cr: the decoder's "current
/// frame" (MS-RDPEGFX, Progressive Entropy Decode).
private struct RDPProgressiveCoefficients {
    var components: [[Int16]]
    var usesReduceExtrapolate: Bool
}

/// The "persistent progressive state" of a component (MS-RDPEGFX, Progressive Entropy Decode): the
/// sign of the data received so far for each coefficient, and the progressive
/// bit positions that data reached.
private struct RDPProgressiveComponentState {
    var signs: [Int8]
    var bitPositions: RDPRemoteFXDecoder.Quant
}

/// Progressive tile state. Coefficients belong to the surface tile, because
/// difference tiles refine whatever the surface last showed there; refinement
/// state (Y, Cb, Cr) belongs to the codec context rendering the tile progressively.
private final class RDPProgressiveTileStore: @unchecked Sendable {
    /// A server that cycles codec context IDs without DeleteEncodingContext would otherwise grow
    /// refinement state without bound; the least recently used context of a surface is dropped.
    /// FreeRDP keeps a single progressive state per surface.
    static let maximumCodecContextsPerSurface = 4

    struct Key: Hashable {
        var surfaceID: UInt16
        var codecContextID: UInt32
        var xIndex: Int
        var yIndex: Int
    }

    private struct SurfaceTileKey: Hashable {
        var surfaceID: UInt16
        var xIndex: Int
        var yIndex: Int

        init(_ key: Key) {
            surfaceID = key.surfaceID
            xIndex = key.xIndex
            yIndex = key.yIndex
        }
    }

    private let lock = NSLock()
    private var coefficients: [SurfaceTileKey: RDPProgressiveCoefficients] = [:]
    private var refinements: [Key: [RDPProgressiveComponentState]] = [:]
    /// Codec context IDs with refinement state, per surface, least recently used first.
    private var codecContextIDs: [UInt16: [UInt32]] = [:]

    /// Stores a simple or first-pass tile, adding it to the surface tile's previous
    /// coefficients when it is a difference tile, and returns the stored tile.
    func store(
        _ tile: RDPProgressiveCoefficients,
        isDifference: Bool,
        refinement: [RDPProgressiveComponentState]?,
        for key: Key
    ) throws -> RDPProgressiveCoefficients {
        lock.lock()
        defer { lock.unlock() }
        var stored = tile
        if isDifference {
            guard let previous = coefficients[SurfaceTileKey(key)],
                  previous.usesReduceExtrapolate == tile.usesReduceExtrapolate
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            for component in stored.components.indices {
                for index in stored.components[component].indices {
                    stored.components[component][index] = Int16(
                        clamping: Int(previous.components[component][index]) + Int(tile.components[component][index])
                    )
                }
            }
        }
        coefficients[SurfaceTileKey(key)] = stored
        // A first pass or a whole tile clears the tile's progressive state, whichever codec
        // context refined it before (MS-RDPEGFX 3.3.8.2.1).
        for codecContextID in codecContextIDs[key.surfaceID, default: []] {
            var otherKey = key
            otherKey.codecContextID = codecContextID
            refinements[otherKey] = nil
        }
        setRefinement(refinement, for: key)
        return stored
    }

    func upgradeState(for key: Key) throws -> (RDPProgressiveCoefficients, [RDPProgressiveComponentState]) {
        lock.lock()
        defer { lock.unlock() }
        guard let tile = coefficients[SurfaceTileKey(key)],
              let refinement = refinements[key]
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return (tile, refinement)
    }

    func replace(
        _ tile: RDPProgressiveCoefficients,
        refinement: [RDPProgressiveComponentState],
        for key: Key
    ) {
        lock.lock()
        coefficients[SurfaceTileKey(key)] = tile
        setRefinement(refinement, for: key)
        lock.unlock()
    }

    func remove(surfaceID: UInt16) {
        lock.lock()
        coefficients = coefficients.filter { $0.key.surfaceID != surfaceID }
        refinements = refinements.filter { $0.key.surfaceID != surfaceID }
        codecContextIDs[surfaceID] = nil
        lock.unlock()
    }

    func remove(surfaceID: UInt16, codecContextID: UInt32) {
        lock.lock()
        removeRefinements(surfaceID: surfaceID, codecContextID: codecContextID)
        codecContextIDs[surfaceID]?.removeAll { $0 == codecContextID }
        lock.unlock()
    }

    /// Call with `lock` held.
    private func setRefinement(_ refinement: [RDPProgressiveComponentState]?, for key: Key) {
        refinements[key] = refinement
        var contextIDs = codecContextIDs[key.surfaceID, default: []]
        contextIDs.removeAll { $0 == key.codecContextID }
        contextIDs.append(key.codecContextID)
        if contextIDs.count > Self.maximumCodecContextsPerSurface {
            removeRefinements(surfaceID: key.surfaceID, codecContextID: contextIDs.removeFirst())
        }
        codecContextIDs[key.surfaceID] = contextIDs
    }

    /// Call with `lock` held.
    private func removeRefinements(surfaceID: UInt16, codecContextID: UInt32) {
        refinements = refinements.filter {
            $0.key.surfaceID != surfaceID || $0.key.codecContextID != codecContextID
        }
    }
}

private final class RDPConcurrentTileResults: @unchecked Sendable {
    private let lock = NSLock()
    private var decodedTiles: [RDPRemoteFXDecodedTile?]
    private var firstError: Error?

    init(count: Int) {
        decodedTiles = Array(repeating: nil, count: count)
    }

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstError != nil
    }

    func store(_ tile: RDPRemoteFXDecodedTile, at index: Int) {
        lock.lock()
        decodedTiles[index] = tile
        lock.unlock()
    }

    func fail(with error: Error) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
    }

    func tiles() throws -> [RDPRemoteFXDecodedTile] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError {
            throw firstError
        }
        return decodedTiles.compactMap { $0 }
    }
}

/// Decoder for RemoteFX (MS-RDPRFX) and RemoteFX Progressive (MS-RDPEGFX 2.2.4.2)
/// streams. Every decoded tile is 64x64 BGRA.
final class RDPRemoteFXDecoder {
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

        static let zero = Quant(ll3: 0, lh3: 0, hl3: 0, hh3: 0, lh2: 0, hl2: 0, hh2: 0, lh1: 0, hl1: 0, hh1: 0)

        /// The values in sub-band storage order: HL1, LH1, HH1, HL2, LH2, HH2, HL3, LH3, HH3, LL3.
        var bandOrder: [UInt8] {
            [hl1, lh1, hh1, hl2, lh2, hh2, hl3, lh3, hh3, ll3]
        }
    }

    private enum ClassicBlockType {
        static let sync: UInt16 = 0xCCC0
        static let codecVersions: UInt16 = 0xCCC1
        static let channels: UInt16 = 0xCCC2
        static let context: UInt16 = 0xCCC3
        static let frameBegin: UInt16 = 0xCCC4
        static let frameEnd: UInt16 = 0xCCC5
        static let region: UInt16 = 0xCCC6
        static let tileSet: UInt16 = 0xCCC7
        static let tile: UInt16 = 0xCAC3
    }

    private enum ProgressiveBlockType {
        static let sync: UInt16 = 0xCCC0
        static let frameBegin: UInt16 = 0xCCC1
        static let frameEnd: UInt16 = 0xCCC2
        static let context: UInt16 = 0xCCC3
        static let region: UInt16 = 0xCCC4
        static let tileSimple: UInt16 = 0xCCC5
        static let tileFirst: UInt16 = 0xCCC6
        static let tileUpgrade: UInt16 = 0xCCC7
    }

    private enum ClassicDataBlockState {
        case frameBegin
        case region
        case tileSet
        case frameEnd
    }

    enum EntropyAlgorithm {
        case rlgr1
        case rlgr3
    }

    private struct Block {
        var type: UInt16
        var body: Data
    }

    /// TS_RFX_TILE (MS-RDPRFX 2.2.2.3.4.1).
    private struct ClassicTile {
        /// Y, Cb, Cr.
        var quantIndices: [Int]
        var xIndex: Int
        var yIndex: Int
        /// Y, Cb, Cr.
        var components: [Data]
    }

    /// RFX_PROGRESSIVE_TILE_SIMPLE, _FIRST or _UPGRADE (MS-RDPEGFX 2.2.4.2.1.5.3-5).
    private struct ProgressiveTile {
        enum Kind {
            case simple
            case first
            case upgrade
        }

        var kind: Kind
        /// Y, Cb, Cr.
        var quantIndices: [Int]
        var xIndex: Int
        var yIndex: Int
        var isDifference: Bool
        var quality: Int
        /// Y, Cb, Cr data; for upgrades the SRL and raw streams: ySrl, yRaw, cbSrl, cbRaw, crSrl, crRaw.
        var streams: [Data]

        var dependsOnStoredTile: Bool {
            kind == .upgrade || isDifference
        }
    }

    private struct ProgressiveRegion {
        var quants: [Quant]
        /// Y, Cb, Cr tables of each RFX_PROGRESSIVE_CODEC_QUANT.
        var progressiveQuants: [[Quant]]
        var usesReduceExtrapolate: Bool
        var surfaceID: UInt16
        var codecContextID: UInt32
        var store: RDPProgressiveTileStore
    }

    private static let minimumConcurrentTileCount = 8
    private static let tileCoefficientCount = 64 * 64

    /// Coefficient ranges of a tile in sub-band storage order (see `Quant.bandOrder`).
    /// Each classic DWT level halves the band size (MS-RDPRFX 3.1.8.1.4).
    private static let classicBands = [
        0 ..< 1024, 1024 ..< 2048, 2048 ..< 3072,
        3072 ..< 3328, 3328 ..< 3584, 3584 ..< 3840,
        3840 ..< 3904, 3904 ..< 3968, 3968 ..< 4032,
        4032 ..< 4096,
    ]
    /// The Reduce-Extrapolate DWT keeps one extra low-pass sample per level, so
    /// HL1 is 31x33, LH1 33x31, HH1 31x31, and so on down to the 9x9 LL3 band.
    private static let reduceExtrapolateBands = [
        0 ..< 1023, 1023 ..< 2046, 2046 ..< 3007,
        3007 ..< 3279, 3279 ..< 3551, 3551 ..< 3807,
        3807 ..< 3879, 3879 ..< 3951, 3951 ..< 4015,
        4015 ..< 4096,
    ]

    private var channelWidth: Int?
    private var channelHeight: Int?
    private var hasClassicSync = false
    private var hasClassicCodecVersions = false
    private var hasClassicChannels = false
    private var hasClassicContext = false
    private var classicDataBlockState: ClassicDataBlockState = .frameBegin
    private var classicRegionRects: [RDPFrameRect] = []
    private let progressiveStore = RDPProgressiveTileStore()

    // MARK: - RemoteFX Progressive

    /// Decodes an RFX_PROGRESSIVE_BITMAP_STREAM. With `surfaceSize`, tiles outside
    /// the surface are rejected, which bounds the tile state kept per surface.
    func decodeProgressive(
        _ data: Data,
        surfaceID: UInt16 = 0,
        codecContextID: UInt32 = 0,
        surfaceSize: (width: Int, height: Int)? = nil
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
            case ProgressiveBlockType.sync:
                // Only the first block is a sync; a later one is ignored (MS-RDPEGFX 2.2.4.2.1.1).
                if !hasSeenBlock {
                    try Self.parseProgressiveSync(block.body)
                }
            case ProgressiveBlockType.context:
                try Self.parseProgressiveContext(block.body)
            case ProgressiveBlockType.frameBegin:
                guard !hasSeenFrameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let frameBegin = try Self.parseProgressiveFrameBegin(block.body)
                frameIndex = frameBegin.frameIndex
                expectedRegionCount = frameBegin.regionCount
                hasSeenFrameBegin = true
                isInsideFrame = true
            case ProgressiveBlockType.region:
                // Regions outside FRAME_BEGIN/FRAME_END are ignored (MS-RDPEGFX 2.2.4.2.1.5).
                guard isInsideFrame else {
                    break
                }
                regionCount += 1
                let region = try decodeProgressiveRegion(
                    block.body,
                    surfaceID: surfaceID,
                    codecContextID: codecContextID,
                    surfaceSize: surfaceSize
                )
                decodedTiles += region.tiles
                decodedRegionRects += region.rectangles
            case ProgressiveBlockType.frameEnd:
                guard isInsideFrame, !hasSeenFrameEnd else {
                    break
                }
                guard block.body.isEmpty else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                hasSeenFrameEnd = true
                isInsideFrame = false
            default:
                // Unknown block types are skipped (MS-RDPEGFX 2.2.4.2.1).
                break
            }
            hasSeenBlock = true
        }

        // A regionCount above the regions present SHOULD be ignored (MS-RDPEGFX 2.2.4.2.1.2).
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
        progressiveStore.remove(surfaceID: surfaceID)
    }

    func removeProgressiveState(surfaceID: UInt16, codecContextID: UInt32) {
        progressiveStore.remove(surfaceID: surfaceID, codecContextID: codecContextID)
    }

    private static func parseProgressiveSync(_ data: Data) throws {
        // magic and version SHOULD be ignored (MS-RDPEGFX 2.2.4.2.1.1).
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

    /// RFX_PROGRESSIVE_REGION (MS-RDPEGFX 2.2.4.2.1.5).
    private func decodeProgressiveRegion(
        _ data: Data,
        surfaceID: UInt16,
        codecContextID: UInt32,
        surfaceSize: (width: Int, height: Int)?
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
              cursor.remaining == rectangleCount * 8 + quantCount * 5 + progressiveQuantCount * 16 + tileDataSize
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
        let quants = try (0 ..< quantCount).map { _ in try Self.parseProgressiveQuant(from: &cursor) }
        let progressiveQuants = try (0 ..< progressiveQuantCount).map { _ in
            try Self.parseProgressiveCodecQuant(from: &cursor)
        }

        let tiles = try Self.parseTiles(cursor.readData(count: tileDataSize)) {
            try Self.parseProgressiveTile(
                from: &$0,
                quantCount: quants.count,
                progressiveQuantCount: progressiveQuants.count
            )
        }
        guard tiles.count == expectedTileCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if let surfaceSize {
            guard tiles.allSatisfy({ $0.xIndex * 64 < surfaceSize.width && $0.yIndex * 64 < surfaceSize.height })
            else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
        }

        let region = ProgressiveRegion(
            quants: quants,
            progressiveQuants: progressiveQuants,
            usesReduceExtrapolate: flags & 0x01 != 0,
            surfaceID: surfaceID,
            codecContextID: codecContextID,
            store: progressiveStore
        )
        // Tiles that build on stored state, or repeat a position, must decode in order.
        let positions = Set(tiles.map { $0.yIndex << 16 | $0.xIndex })
        let decodesConcurrently = tiles.count >= Self.minimumConcurrentTileCount
            && positions.count == tiles.count
            && !tiles.contains(where: \.dependsOnStoredTile)
        let decodedTiles = try Self.decodeTiles(count: tiles.count, concurrently: decodesConcurrently) { index in
            try Self.decodeProgressiveTile(tiles[index], in: region)
        }
        return (decodedTiles, rectangles)
    }

    private static func parseProgressiveTile(
        from cursor: inout ByteCursor,
        quantCount: Int,
        progressiveQuantCount: Int
    ) throws -> ProgressiveTile {
        let block = try readBlock(from: &cursor)
        let kind: ProgressiveTile.Kind
        switch block.type {
        case ProgressiveBlockType.tileSimple:
            kind = .simple
        case ProgressiveBlockType.tileFirst:
            kind = .first
        case ProgressiveBlockType.tileUpgrade:
            kind = .upgrade
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var body = ByteCursor(block.body)
        let headerLength = switch kind {
        case .simple: 16
        case .first: 17
        case .upgrade: 20
        }
        guard body.remaining >= headerLength else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let quantIndices = try (0 ..< 3).map { _ in try Int(body.readUInt8()) }
        let xIndex = try Int(body.readLittleEndianUInt16())
        let yIndex = try Int(body.readLittleEndianUInt16())
        // Only bit 0 (RFX_TILE_DIFFERENCE) of flags is defined; the rest MUST be ignored.
        let isDifference = kind == .upgrade ? false : try body.readUInt8() & 0x01 != 0
        let quality = kind == .simple ? 0xFF : try Int(body.readUInt8())
        let lengths = try (0 ..< (kind == .upgrade ? 6 : 4)).map { _ in
            try Int(body.readLittleEndianUInt16())
        }
        guard quantIndices.allSatisfy({ $0 < quantCount }),
              quality == 0xFF || quality < progressiveQuantCount,
              body.remaining == lengths.reduce(0, +)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var streams = try lengths.map { try body.readData(count: $0) }
        if kind != .upgrade {
            // tailData SHOULD be ignored.
            streams.removeLast()
        }
        return ProgressiveTile(
            kind: kind,
            quantIndices: quantIndices,
            xIndex: xIndex,
            yIndex: yIndex,
            isDifference: isDifference,
            quality: quality,
            streams: streams
        )
    }

    private static func decodeProgressiveTile(
        _ tile: ProgressiveTile,
        in region: ProgressiveRegion
    ) throws -> RDPRemoteFXDecodedTile {
        let bands = Self.bands(reduceExtrapolate: region.usesReduceExtrapolate)
        let quants = tile.quantIndices.map { region.quants[$0] }
        // Quality 0xFF selects the full-quality table, whose values are all zero.
        let targetQuants = tile.quality == 0xFF
            ? [Quant.zero, .zero, .zero]
            : region.progressiveQuants[tile.quality]
        let key = RDPProgressiveTileStore.Key(
            surfaceID: region.surfaceID,
            codecContextID: region.codecContextID,
            xIndex: tile.xIndex,
            yIndex: tile.yIndex
        )

        let coefficients: RDPProgressiveCoefficients
        if tile.kind == .upgrade {
            var (stored, refinement) = try region.store.upgradeState(for: key)
            guard stored.usesReduceExtrapolate == region.usesReduceExtrapolate else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            for component in 0 ..< 3 {
                try upgradeComponent(
                    &stored.components[component],
                    state: &refinement[component],
                    quant: quants[component],
                    targetBitPositions: targetQuants[component],
                    bands: bands,
                    srlData: tile.streams[component * 2],
                    rawData: tile.streams[component * 2 + 1]
                )
            }
            region.store.replace(stored, refinement: refinement, for: key)
            coefficients = stored
        } else {
            var components: [[Int16]] = []
            var refinement: [RDPProgressiveComponentState] = []
            for component in 0 ..< 3 {
                var values = try entropyDecode(tile.streams[component], algorithm: .rlgr1, bands: bands)
                if tile.kind == .first {
                    refinement.append(RDPProgressiveComponentState(
                        signs: values.map { Int8($0.signum()) },
                        bitPositions: targetQuants[component]
                    ))
                }
                try dequantize(
                    &values,
                    quant: quants[component],
                    progressiveQuant: targetQuants[component],
                    bands: bands
                )
                components.append(values)
            }
            // Simple tiles carry the whole tile, so they clear any progressive state.
            coefficients = try region.store.store(
                RDPProgressiveCoefficients(
                    components: components,
                    usesReduceExtrapolate: region.usesReduceExtrapolate
                ),
                isDifference: tile.isDifference,
                refinement: tile.kind == .first ? refinement : nil,
                for: key
            )
        }

        var components = coefficients.components
        for index in components.indices {
            if coefficients.usesReduceExtrapolate {
                decodeProgressiveDWT(&components[index])
            } else {
                inverseDWT(&components[index])
            }
        }
        return RDPRemoteFXDecodedTile(
            x: tile.xIndex * 64,
            y: tile.yIndex * 64,
            bgraData: bgraData(y: components[0], cb: components[1], cr: components[2]),
            bytesPerRow: 64 * 4
        )
    }

    /// Adds one upgrade pass to a component (MS-RDPEGFX 3.2.8.1.5.2). Coefficients
    /// whose received data is still zero are SRL coded; the others, and all of LL3,
    /// carry their magnitude as raw bits and keep the sign received so far.
    private static func upgradeComponent(
        _ coefficients: inout [Int16],
        state: inout RDPProgressiveComponentState,
        quant: Quant,
        targetBitPositions: Quant,
        bands: [Range<Int>],
        srlData: Data,
        rawData: Data
    ) throws {
        let previous = state.bitPositions.bandOrder
        let target = targetBitPositions.bandOrder
        let factors = quant.bandOrder
        guard zip(previous, target).allSatisfy({ $0 >= $1 }) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let ll3Band = bands.count - 1
        var remainingSRLValueCount = 0
        for band in 0 ..< ll3Band where previous[band] > target[band] {
            remainingSRLValueCount += state.signs[bands[band]].reduce(0) { $1 == 0 ? $0 + 1 : $0 }
        }

        var srlReader = RDPProgressiveSRLReader(srlData)
        var rawReader = BitReader(rawData)
        for (band, range) in bands.enumerated() where previous[band] > target[band] {
            let bitCount = Int(previous[band] - target[band])
            let shift = Int(target[band]) + Int(factors[band]) - 1
            guard shift >= 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            for index in range {
                let input: Int
                if band != ll3Band, state.signs[index] == 0 {
                    let value = try srlReader.readValue(
                        magnitudeBitCount: bitCount,
                        remainingValueCount: remainingSRLValueCount
                    )
                    remainingSRLValueCount -= 1
                    state.signs[index] = Int8(value.signum())
                    input = Int(value)
                } else {
                    guard let magnitude = rawReader.readBits(count: bitCount) else {
                        throw RDPDecodeError.invalidRDPGFXPDU
                    }
                    input = state.signs[index] < 0 && band != ll3Band ? -Int(magnitude) : Int(magnitude)
                }
                coefficients[index] &+= Int16(truncatingIfNeeded: input << shift)
            }
        }
        state.bitPositions = targetBitPositions
    }

    /// RFX_COMPONENT_CODEC_QUANT (MS-RDPEGFX 2.2.4.2.1.5.2): LL3, HL3, LH3, HH3, HL2,
    /// LH2, HH2, HL1, LH1, HH1, low nibble first.
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

    /// RFX_PROGRESSIVE_CODEC_QUANT (MS-RDPEGFX 2.2.4.2.1.5.1); returns the Y, Cb and Cr tables.
    private static func parseProgressiveCodecQuant(from cursor: inout ByteCursor) throws -> [Quant] {
        // quality SHOULD be ignored.
        _ = try cursor.readUInt8()
        let quants = try (0 ..< 3).map { _ in try parseProgressiveQuant(from: &cursor) }
        guard quants.allSatisfy({ $0.bandOrder.allSatisfy { $0 <= 8 } }) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return quants
    }

    private static func bands(reduceExtrapolate: Bool) -> [Range<Int>] {
        reduceExtrapolate ? reduceExtrapolateBands : classicBands
    }

    // MARK: - RemoteFX (classic)

    func decode(_ data: Data) throws -> RDPRemoteFXDecodedFrame {
        do {
            return try decodeClassicMessage(data)
        } catch {
            // The frame a failed message left open is lost; the next message starts afresh.
            classicDataBlockState = .frameBegin
            classicRegionRects = []
            throw error
        }
    }

    private func decodeClassicMessage(_ data: Data) throws -> RDPRemoteFXDecodedFrame {
        var cursor = ByteCursor(data)
        var frameIndex: UInt32?
        var decodedTiles: [RDPRemoteFXDecodedTile] = []
        var decodedRegionRects: [RDPFrameRect] = []

        while cursor.remaining > 0 {
            let block = try Self.readBlock(from: &cursor)
            guard hasClassicSync || block.type == ClassicBlockType.sync else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            switch block.type {
            case ClassicBlockType.sync:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseSync(block.body)
                hasClassicSync = true
            case ClassicBlockType.codecVersions:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseCodecVersions(block.body)
                hasClassicCodecVersions = true
            case ClassicBlockType.channels:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try parseChannels(block.body)
                hasClassicChannels = true
            case ClassicBlockType.context:
                guard classicDataBlockState == .frameBegin else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                try Self.parseContext(block.body)
                hasClassicContext = true
            case ClassicBlockType.frameBegin:
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
            case ClassicBlockType.region:
                guard classicDataBlockState == .region else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                classicRegionRects = try parseRegion(block.body)
                classicDataBlockState = .tileSet
            case ClassicBlockType.tileSet:
                guard classicDataBlockState == .tileSet else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                decodedTiles += try Self.decodeTileSet(block.body)
                // A later frame's tiles are drawn over an earlier one's, so its region adds to theirs.
                decodedRegionRects += classicRegionRects
                classicDataBlockState = .frameEnd
            case ClassicBlockType.frameEnd:
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
        let blockLength = try Int(cursor.readLittleEndianUInt32())
        guard blockLength >= 6,
              blockLength - 6 <= cursor.remaining
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try Block(type: blockType, body: cursor.readData(count: blockLength - 6))
    }

    /// TS_RFX_CODEC_CHANNELT (MS-RDPRFX 2.2.2.1.2).
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

    /// TS_RFX_CODEC_VERSIONS (MS-RDPRFX 2.2.2.2.2): one codec, ID 1, version 1.0.
    private static func parseCodecVersions(_ data: Data) throws {
        var cursor = ByteCursor(data)
        guard cursor.remaining == 4,
              try cursor.readUInt8() == 1,
              try cursor.readUInt8() == 1,
              try cursor.readLittleEndianUInt16() == 0x0100
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
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

    /// TS_RFX_CONTEXT (MS-RDPRFX 2.2.2.2.4): 64-pixel tiles and the DWT 5/3 transform.
    private static func parseContext(_ data: Data) throws {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0xFF)
        guard cursor.remaining == 5 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readUInt8()
        guard try cursor.readLittleEndianUInt16() == 64,
              try (cursor.readLittleEndianUInt16() >> 5) & 0x0F == 1
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

    /// TS_RFX_REGION (MS-RDPRFX 2.2.2.3.3), with rectangles clipped to the channel.
    private func parseRegion(_ data: Data) throws -> [RDPFrameRect] {
        var cursor = ByteCursor(data)
        try Self.parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 7 else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // regionFlags: the decoder SHOULD ignore lrf and MUST ignore the reserved bits.
        _ = try cursor.readUInt8()
        let rectangleCount = try Int(cursor.readLittleEndianUInt16())
        guard let channelWidth,
              let channelHeight,
              channelWidth > 0,
              channelHeight > 0,
              cursor.remaining == rectangleCount * 8 + 4
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var rectangles: [RDPFrameRect] = []
        rectangles.reserveCapacity(max(rectangleCount, 1))
        for _ in 0 ..< rectangleCount {
            let left = try Int(cursor.readLittleEndianUInt16())
            let top = try Int(cursor.readLittleEndianUInt16())
            let right = try min(left + Int(cursor.readLittleEndianUInt16()), channelWidth)
            let bottom = try min(top + Int(cursor.readLittleEndianUInt16()), channelHeight)
            if right > left, bottom > top {
                rectangles.append(RDPFrameRect(
                    left: UInt16(left),
                    top: UInt16(top),
                    right: UInt16(right),
                    bottom: UInt16(bottom)
                ))
            }
        }
        guard try cursor.readLittleEndianUInt16() == 0xCAC1,
              try cursor.readLittleEndianUInt16() == 1
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        // No rectangles means the whole channel.
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

    /// TS_RFX_TILESET (MS-RDPRFX 2.2.2.3.4).
    private static func decodeTileSet(_ data: Data) throws -> [RDPRemoteFXDecodedTile] {
        var cursor = ByteCursor(data)
        try parseCodecChannelHeader(&cursor, channelID: 0)
        guard cursor.remaining >= 14,
              try cursor.readLittleEndianUInt16() == 0xCAC2
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        _ = try cursor.readLittleEndianUInt16()
        let properties = try cursor.readLittleEndianUInt16()
        let algorithm: EntropyAlgorithm
        switch (properties >> 10) & 0x0F {
        case 0x01:
            algorithm = .rlgr1
        case 0x04:
            algorithm = .rlgr3
        default:
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let quantCount = try Int(cursor.readUInt8())
        _ = try cursor.readUInt8()
        let expectedTileCount = try Int(cursor.readLittleEndianUInt16())
        let tilesDataSize = try Int(cursor.readLittleEndianUInt32())
        guard cursor.remaining == quantCount * 5 + tilesDataSize else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let quants = try (0 ..< quantCount).map { _ in try parseQuant(from: &cursor) }

        let tiles = try parseTiles(cursor.readData(count: tilesDataSize)) {
            try parseTile(from: &$0, quantCount: quants.count)
        }
        guard tiles.count == expectedTileCount else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }

        return try decodeTiles(
            count: tiles.count,
            concurrently: tiles.count >= minimumConcurrentTileCount
        ) { index in
            let tile = tiles[index]
            let components = try (0 ..< 3).map { component in
                var values = try entropyDecode(tile.components[component], algorithm: algorithm, bands: classicBands)
                try dequantize(&values, quant: quants[tile.quantIndices[component]], bands: classicBands)
                inverseDWT(&values)
                return values
            }
            return RDPRemoteFXDecodedTile(
                x: tile.xIndex * 64,
                y: tile.yIndex * 64,
                bgraData: bgraData(y: components[0], cb: components[1], cr: components[2]),
                bytesPerRow: 64 * 4
            )
        }
    }

    private static func parseTile(from cursor: inout ByteCursor, quantCount: Int) throws -> ClassicTile {
        let block = try readBlock(from: &cursor)
        var body = ByteCursor(block.body)
        guard block.type == ClassicBlockType.tile,
              body.remaining >= 13
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        let quantIndices = try (0 ..< 3).map { _ in try Int(body.readUInt8()) }
        let xIndex = try Int(body.readLittleEndianUInt16())
        let yIndex = try Int(body.readLittleEndianUInt16())
        let lengths = try (0 ..< 3).map { _ in try Int(body.readLittleEndianUInt16()) }
        guard quantIndices.allSatisfy({ $0 < quantCount }),
              body.remaining == lengths.reduce(0, +)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return try ClassicTile(
            quantIndices: quantIndices,
            xIndex: xIndex,
            yIndex: yIndex,
            components: lengths.map { try body.readData(count: $0) }
        )
    }

    /// TS_RFX_CODEC_QUANT (MS-RDPRFX 2.2.2.1.5): LL3, LH3, HL3, HH3, LH2, HL2, HH2,
    /// LH1, HL1, HH1, low nibble first, each in 6...15.
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
        guard quant.bandOrder.allSatisfy({ 6 ... 15 ~= $0 }) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return quant
    }

    // MARK: - Shared tile pipeline

    private static func parseTiles<Tile>(
        _ data: Data,
        _ parse: (inout ByteCursor) throws -> Tile
    ) throws -> [Tile] {
        var cursor = ByteCursor(data)
        var tiles: [Tile] = []
        while cursor.remaining > 0 {
            try tiles.append(parse(&cursor))
        }
        return tiles
    }

    /// Runs `decode` for every tile index, concurrently when asked, keeping tile order.
    private static func decodeTiles(
        count: Int,
        concurrently: Bool,
        _ decode: @Sendable (Int) throws -> RDPRemoteFXDecodedTile
    ) throws -> [RDPRemoteFXDecodedTile] {
        guard concurrently else {
            return try (0 ..< count).map(decode)
        }
        let results = RDPConcurrentTileResults(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            guard !results.hasFailed else {
                return
            }
            do {
                try results.store(decode(index), at: index)
            } catch {
                results.fail(with: error)
            }
        }
        return try results.tiles()
    }

    /// RLGR-decodes a 64x64 component and undoes the differential coding of LL3
    /// (MS-RDPRFX 3.1.8.1.7).
    private static func entropyDecode(
        _ data: Data,
        algorithm: EntropyAlgorithm,
        bands: [Range<Int>]
    ) throws -> [Int16] {
        guard !data.isEmpty else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        var coefficients = [Int16](repeating: 0, count: tileCoefficientCount)
        try decodeRLGR(data, algorithm: algorithm, into: &coefficients)
        let ll3 = bands[bands.count - 1]
        for index in ll3.dropFirst() {
            coefficients[index] = coefficients[index] &+ coefficients[index - 1]
        }
        return coefficients
    }

    /// Shifts every sub-band left by its quantization factor plus its progressive
    /// bit position, minus one (MS-RDPEGFX 3.1.8.1.3).
    private static func dequantize(
        _ coefficients: inout [Int16],
        quant: Quant,
        progressiveQuant: Quant = .zero,
        bands: [Range<Int>]
    ) throws {
        for (band, (factor, bitPosition)) in zip(bands, zip(quant.bandOrder, progressiveQuant.bandOrder)) {
            let shift = Int(factor) + Int(bitPosition) - 1
            guard shift >= 0 else {
                throw RDPDecodeError.invalidRDPGFXPDU
            }
            guard shift > 0 else {
                continue
            }
            for index in band {
                coefficients[index] = Int16(truncatingIfNeeded: Int(coefficients[index]) << shift)
            }
        }
    }

    /// RLGR1/RLGR3 decoding per MS-RDPRFX 3.1.8.1.7. `output` starts zeroed, so zero
    /// runs only advance the write position.
    static func decodeRLGR(
        _ data: Data,
        algorithm: EntropyAlgorithm,
        into output: inout [Int16]
    ) throws {
        // KPMAX, UP_GR, DN_GR, UQ_GR and DQ_GR; k = kp >> 3 and kr = krp >> 3.
        let kpMax = 80
        let upGR = 4
        let downGR = 6
        let upQuantGR = 3
        let downQuantGR = 3
        var bits = BitReader(data)
        var kp = 8
        var krp = 8
        var index = 0

        while index < output.count {
            let k = kp >> 3
            if k > 0 {
                // Run-length mode: each 0 bit is a run of 1 << k zeros; a 1 bit ends
                // the run and is followed by k bits holding the rest of the run.
                for _ in 0 ..< bits.consumeRun(of: 0) {
                    index += 1 << (kp >> 3)
                    kp = min(kp + upGR, kpMax)
                }
                guard index < output.count else {
                    return
                }
                guard bits.readBits(count: 1) != nil,
                      let run = bits.readBits(count: kp >> 3)
                else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                index += Int(run)
                guard index < output.count else {
                    return
                }
                guard let sign = bits.readBits(count: 1) else {
                    throw RDPDecodeError.invalidRDPGFXPDU
                }
                let magnitude = try readGolombRice(&bits, krp: &krp) + 1
                output[index] = try coefficient(magnitude: magnitude, isNegative: sign == 1)
                index += 1
                kp = max(kp - downGR, 0)
            } else {
                // Golomb-Rice mode: values are coded as 2 * magnitude - sign.
                let code = try readGolombRice(&bits, krp: &krp)
                switch algorithm {
                case .rlgr1:
                    output[index] = try coefficient(twoMagnitudeMinusSign: code)
                    index += 1
                    kp = code == 0 ? min(kp + upQuantGR, kpMax) : max(kp - downQuantGR, 0)
                case .rlgr3:
                    // The code is the sum of two values; the first is sent in as many
                    // bits as the sum needs.
                    let firstBitCount = code == 0 ? 0 : Int.bitWidth - code.leadingZeroBitCount
                    guard let first = bits.readBits(count: firstBitCount).map(Int.init),
                          first <= code
                    else {
                        throw RDPDecodeError.invalidRDPGFXPDU
                    }
                    let second = code - first
                    if first != 0, second != 0 {
                        kp = max(kp - 2 * downQuantGR, 0)
                    } else if first == 0, second == 0 {
                        kp = min(kp + 2 * upQuantGR, kpMax)
                    }
                    output[index] = try coefficient(twoMagnitudeMinusSign: first)
                    index += 1
                    if index < output.count {
                        output[index] = try coefficient(twoMagnitudeMinusSign: second)
                        index += 1
                    }
                }
            }
        }
    }

    /// Reads a Golomb-Rice code with parameter krp >> 3 and adapts krp (GetGRCode).
    private static func readGolombRice(_ bits: inout BitReader, krp: inout Int) throws -> Int {
        let ones = bits.consumeRun(of: 1)
        let kr = krp >> 3
        guard bits.readBits(count: 1) != nil,
              let remainder = bits.readBits(count: kr)
        else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        if ones == 0 {
            krp = max(krp - 2, 0)
        } else if ones > 1 {
            krp = min(krp + ones, 80)
        }
        return ones << kr | Int(remainder)
    }

    private static func coefficient(twoMagnitudeMinusSign value: Int) throws -> Int16 {
        try coefficient(magnitude: (value + value & 1) >> 1, isNegative: value & 1 == 1)
    }

    private static func coefficient(magnitude: Int, isNegative: Bool) throws -> Int16 {
        guard magnitude <= Int(Int16.max) else {
            throw RDPDecodeError.invalidRDPGFXPDU
        }
        return isNegative ? -Int16(magnitude) : Int16(magnitude)
    }

    // MARK: - Inverse DWT

    /// Classic inverse DWT 5/3 of the three levels (MS-RDPRFX 3.1.8.2.4).
    private static func inverseDWT(_ buffer: inout [Int16]) {
        var temp = [Int16](repeating: 0, count: tileCoefficientCount)
        inverseDWTLevel(&buffer, start: 3840, temp: &temp, subbandWidth: 8)
        inverseDWTLevel(&buffer, start: 3072, temp: &temp, subbandWidth: 16)
        inverseDWTLevel(&buffer, start: 0, temp: &temp, subbandWidth: 32)
    }

    /// Reduce-Extrapolate inverse DWT (MS-RDPEGFX), using the
    /// `reduceExtrapolateBands` layout.
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

    private static func inverseDWTLevel(
        _ buffer: inout [Int16],
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

    // MARK: - Color conversion

    /// Converts 11.5 fixed-point YCbCr (Y offset by -4096) to BGRA with the
    /// fixed-point ICT coefficients of MS-RDPRFX 3.1.8.2.5 scaled by 2^16.
    private static func bgraData(y: [Int16], cb: [Int16], cr: [Int16]) -> Data {
        var data = Data(count: tileCoefficientCount * 4)
        data.withUnsafeMutableBytes { bytes in
            for index in 0 ..< tileCoefficientCount {
                let luma = (Int(y[index]) + 4096) << 16
                let blueDifference = Int(cb[index])
                let redDifference = Int(cr[index])
                let offset = index * 4
                bytes[offset] = clip((luma + blueDifference * 115_992) >> 21)
                bytes[offset + 1] = clip((luma - blueDifference * 22_527 - redDifference * 46_819) >> 21)
                bytes[offset + 2] = clip((luma + redDifference * 91_916) >> 21)
                bytes[offset + 3] = 0xFF
            }
        }
        return data
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

/// Most-significant-bit-first reader.
private struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    /// Consumes bits equal to `bit` up to the next other bit or the end, and returns how many.
    mutating func consumeRun(of bit: UInt8) -> Int {
        let start = bitOffset
        let mask: UInt8 = bit == 0 ? 0x00 : 0xFF
        while bitOffset < bytes.count * 8 {
            let usedBits = bitOffset & 7
            let availableBits = 8 - usedBits
            let run = min(((bytes[bitOffset >> 3] ^ mask) << usedBits).leadingZeroBitCount, availableBits)
            bitOffset += run
            if run < availableBits {
                break
            }
        }
        return bitOffset - start
    }

    /// Reads up to 32 bits, or returns nil when fewer remain.
    mutating func readBits(count: Int) -> UInt32? {
        guard (0 ... 32).contains(count),
              count <= bytes.count * 8 - bitOffset
        else {
            return nil
        }
        var value: UInt32 = 0
        var remaining = count
        while remaining > 0 {
            let availableBits = 8 - bitOffset & 7
            let taken = min(availableBits, remaining)
            let byte = UInt32(bytes[bitOffset >> 3])
            value = value << taken | (byte >> (availableBits - taken)) & ((1 << taken) - 1)
            bitOffset += taken
            remaining -= taken
        }
        return value
    }
}

/// Simplified Run-Length decoder for upgrade passes (MS-RDPEGFX 3.1.8.1.5): RLGR's
/// zero-run coding with unary-coded nonzero magnitudes.
struct RDPProgressiveSRLReader {
    private var bits: BitReader
    private var kp = 8
    private var pendingZeroCount = 0
    private var expectsNonzero = false

    init(_ data: Data) {
        bits = BitReader(data)
    }

    /// Reads the next value. `remainingValueCount` (this value included) bounds zero
    /// runs, which may run into the stream's zero padding.
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

    /// A sign bit, then the magnitude in unary (magnitude - 1 zeros and a terminating
    /// one, which is omitted at the largest magnitude that fits `magnitudeBitCount` bits).
    private mutating func readNonzero(magnitudeBitCount: Int) throws -> Int16 {
        guard magnitudeBitCount < 16,
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
        let value = Int16(magnitude)
        return sign == 0 ? value : -value
    }
}
