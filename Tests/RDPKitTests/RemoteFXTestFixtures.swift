import Foundation
@testable import RDPKit

func cavideoRemoteFXGrayTileStream(
    frameIndex: UInt32 = 1,
    channelWidth: UInt16 = 64,
    channelHeight: UInt16 = 64,
    regionX: UInt16 = 0,
    regionY: UInt16 = 0,
    regionWidth: UInt16 = 64,
    regionHeight: UInt16 = 64,
    regionRectangleCount: UInt16 = 1,
    frameRegionCount: UInt16 = 1,
    tileXIndex: UInt16 = 0,
    tileYIndex: UInt16 = 0,
    codecVersionID: UInt8 = 1,
    codecVersion: UInt16 = 0x0100,
    contextID: UInt8 = 0,
    contextTileSize: UInt16 = 64,
    contextProperties: UInt16 = 0xA828,
    tileSetIndex: UInt16 = 0,
    tileSetProperties: UInt16 = 0x5051,
    tileSetTileSize: UInt8 = 64,
    quantData: Data = Data([0x66, 0x66, 0x77, 0x88, 0x98]),
    regionFlags: UInt8 = 1
) -> Data {
    let component = rlgrAllZeroComponent()
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendRFXBlock(type: 0xCCC0, body: sync)

    var codecVersions = Data()
    codecVersions.appendUInt8(1)
    codecVersions.appendUInt8(codecVersionID)
    codecVersions.appendLittleEndianUInt16(codecVersion)
    stream.appendRFXBlock(type: 0xCCC1, body: codecVersions)

    var channels = Data()
    channels.appendUInt8(1)
    channels.appendUInt8(0)
    channels.appendLittleEndianUInt16(channelWidth)
    channels.appendLittleEndianUInt16(channelHeight)
    stream.appendRFXBlock(type: 0xCCC2, body: channels)

    var context = Data()
    context.appendRFXChannelHeader(channelID: 0xFF)
    context.appendUInt8(contextID)
    context.appendLittleEndianUInt16(contextTileSize)
    context.appendLittleEndianUInt16(contextProperties)
    stream.appendRFXBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendRFXChannelHeader(channelID: 0)
    frameBegin.appendLittleEndianUInt32(frameIndex)
    frameBegin.appendLittleEndianUInt16(frameRegionCount)
    stream.appendRFXBlock(type: 0xCCC4, body: frameBegin)

    var region = Data()
    region.appendRFXChannelHeader(channelID: 0)
    region.appendUInt8(regionFlags)
    region.appendLittleEndianUInt16(regionRectangleCount)
    if regionRectangleCount > 0 {
        region.appendLittleEndianUInt16(regionX)
        region.appendLittleEndianUInt16(regionY)
        region.appendLittleEndianUInt16(regionWidth)
        region.appendLittleEndianUInt16(regionHeight)
    }
    region.appendLittleEndianUInt16(0xCAC1)
    region.appendLittleEndianUInt16(1)
    stream.appendRFXBlock(type: 0xCCC6, body: region)

    var tile = Data()
    tile.appendUInt8(0)
    tile.appendUInt8(0)
    tile.appendUInt8(0)
    tile.appendLittleEndianUInt16(tileXIndex)
    tile.appendLittleEndianUInt16(tileYIndex)
    tile.appendLittleEndianUInt16(UInt16(component.count))
    tile.appendLittleEndianUInt16(UInt16(component.count))
    tile.appendLittleEndianUInt16(UInt16(component.count))
    tile.append(component)
    tile.append(component)
    tile.append(component)
    var tileBlock = Data()
    tileBlock.appendRFXBlock(type: 0xCAC3, body: tile)

    var tileSet = Data()
    tileSet.appendRFXChannelHeader(channelID: 0)
    tileSet.appendLittleEndianUInt16(0xCAC2)
    tileSet.appendLittleEndianUInt16(tileSetIndex)
    tileSet.appendLittleEndianUInt16(tileSetProperties)
    tileSet.appendUInt8(1)
    tileSet.appendUInt8(tileSetTileSize)
    tileSet.appendLittleEndianUInt16(1)
    tileSet.appendLittleEndianUInt32(UInt32(tileBlock.count))
    tileSet.append(quantData)
    tileSet.append(tileBlock)
    stream.appendRFXBlock(type: 0xCCC7, body: tileSet)

    var frameEnd = Data()
    frameEnd.appendRFXChannelHeader(channelID: 0)
    stream.appendRFXBlock(type: 0xCCC5, body: frameEnd)

    return stream
}

func caprogressiveRemoteFXGrayTileStream(
    frameIndex: UInt32 = 1,
    regionX: UInt16 = 0,
    regionY: UInt16 = 0,
    regionWidth: UInt16 = 64,
    regionHeight: UInt16 = 64,
    tileXIndex: UInt16 = 0,
    tileYIndex: UInt16 = 0,
    tileFlags: UInt8 = 0,
    tailData: Data = Data()
) -> Data {
    caprogressiveRemoteFXGrayTilesStream(
        frameIndex: frameIndex,
        regionX: regionX,
        regionY: regionY,
        regionWidth: regionWidth,
        regionHeight: regionHeight,
        tiles: [CAPROGRESSIVERemoteFXGrayTile(
            xIndex: tileXIndex,
            yIndex: tileYIndex,
            flags: tileFlags,
            tailData: tailData
        )]
    )
}

struct CAPROGRESSIVERemoteFXGrayTile {
    var blockType: UInt16 = 0xCCC5
    var yQuantIndex: UInt8 = 0
    var cbQuantIndex: UInt8 = 0
    var crQuantIndex: UInt8 = 0
    var xIndex: UInt16
    var yIndex: UInt16
    var flags: UInt8 = 0
    var progressiveQuality: UInt8 = 0xFF
    var tailData: Data = Data()
    var advertisedTailByteCount: UInt16? = nil
    var yData: Data? = nil
    var cbData: Data? = nil
    var crData: Data? = nil
    var ySrlData: Data? = nil
    var yRawData: Data? = nil
    var cbSrlData: Data? = nil
    var cbRawData: Data? = nil
    var crSrlData: Data? = nil
    var crRawData: Data? = nil
}

func caprogressiveRemoteFXGrayTilesStream(
    frameIndex: UInt32 = 1,
    regionX: UInt16 = 0,
    regionY: UInt16 = 0,
    regionWidth: UInt16 = 64,
    regionHeight: UInt16 = 64,
    tileSize: UInt8 = 64,
    rectangleCount: UInt16 = 1,
    quantCount: UInt8 = 1,
    regionFlags: UInt8 = 1,
    progressiveQuantTables: [Data] = [],
    advertisedTileCount: UInt16? = nil,
    advertisedTileDataSize: UInt32? = nil,
    tiles: [CAPROGRESSIVERemoteFXGrayTile]
) -> Data {
    precondition(!tiles.isEmpty)
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendRFXBlock(type: 0xCCC0, body: sync)

    var context = Data()
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(64)
    context.appendUInt8(1)
    stream.appendRFXBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendLittleEndianUInt32(frameIndex)
    frameBegin.appendLittleEndianUInt16(1)
    stream.appendRFXBlock(type: 0xCCC1, body: frameBegin)

    stream.append(caprogressiveRemoteFXGrayRegionBlock(
        regionX: regionX,
        regionY: regionY,
        regionWidth: regionWidth,
        regionHeight: regionHeight,
        tileSize: tileSize,
        rectangleCount: rectangleCount,
        quantCount: quantCount,
        regionFlags: regionFlags,
        progressiveQuantTables: progressiveQuantTables,
        advertisedTileCount: advertisedTileCount,
        advertisedTileDataSize: advertisedTileDataSize,
        tiles: tiles
    ))

    stream.appendRFXBlock(type: 0xCCC2, body: Data())

    return stream
}

func caprogressiveRemoteFXRegionsStream(
    frameIndex: UInt32 = 1,
    regions: [Data]
) -> Data {
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendRFXBlock(type: 0xCCC0, body: sync)

    var context = Data()
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(64)
    context.appendUInt8(1)
    stream.appendRFXBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendLittleEndianUInt32(frameIndex)
    frameBegin.appendLittleEndianUInt16(UInt16(regions.count))
    stream.appendRFXBlock(type: 0xCCC1, body: frameBegin)
    for region in regions {
        stream.append(region)
    }
    stream.appendRFXBlock(type: 0xCCC2, body: Data())
    return stream
}

func caprogressiveRemoteFXGrayRegionBlock(
    regionX: UInt16 = 0,
    regionY: UInt16 = 0,
    regionWidth: UInt16 = 64,
    regionHeight: UInt16 = 64,
    tileSize: UInt8 = 64,
    rectangleCount: UInt16 = 1,
    quantCount: UInt8 = 1,
    regionFlags: UInt8 = 1,
    progressiveQuantTables: [Data] = [],
    advertisedTileCount: UInt16? = nil,
    advertisedTileDataSize: UInt32? = nil,
    tiles: [CAPROGRESSIVERemoteFXGrayTile]
) -> Data {
    precondition(progressiveQuantTables.allSatisfy { $0.count == 16 })
    let component = rlgrAllZeroComponent()
    var tileBlock = Data()
    for tileSpec in tiles {
        let yData = tileSpec.yData ?? component
        let cbData = tileSpec.cbData ?? component
        let crData = tileSpec.crData ?? component
        var tile = Data()
        tile.appendUInt8(tileSpec.yQuantIndex)
        tile.appendUInt8(tileSpec.cbQuantIndex)
        tile.appendUInt8(tileSpec.crQuantIndex)
        tile.appendLittleEndianUInt16(tileSpec.xIndex)
        tile.appendLittleEndianUInt16(tileSpec.yIndex)
        if tileSpec.blockType == 0xCCC7 {
            tile.appendUInt8(tileSpec.progressiveQuality)
            let streams = [
                tileSpec.ySrlData ?? Data(), tileSpec.yRawData ?? Data(),
                tileSpec.cbSrlData ?? Data(), tileSpec.cbRawData ?? Data(),
                tileSpec.crSrlData ?? Data(), tileSpec.crRawData ?? Data(),
            ]
            for stream in streams {
                tile.appendLittleEndianUInt16(UInt16(stream.count))
            }
            for stream in streams {
                tile.append(stream)
            }
        } else {
            tile.appendUInt8(tileSpec.flags)
            if tileSpec.blockType == 0xCCC6 {
                tile.appendUInt8(tileSpec.progressiveQuality)
            }
            tile.appendLittleEndianUInt16(UInt16(yData.count))
            tile.appendLittleEndianUInt16(UInt16(cbData.count))
            tile.appendLittleEndianUInt16(UInt16(crData.count))
            tile.appendLittleEndianUInt16(tileSpec.advertisedTailByteCount ?? UInt16(tileSpec.tailData.count))
            tile.append(yData)
            tile.append(cbData)
            tile.append(crData)
            tile.append(tileSpec.tailData)
        }
        tileBlock.appendRFXBlock(type: tileSpec.blockType, body: tile)
    }

    var region = Data()
    region.appendUInt8(tileSize)
    region.appendLittleEndianUInt16(rectangleCount)
    region.appendUInt8(quantCount)
    region.appendUInt8(UInt8(progressiveQuantTables.count))
    region.appendUInt8(regionFlags)
    region.appendLittleEndianUInt16(advertisedTileCount ?? UInt16(tiles.count))
    region.appendLittleEndianUInt32(advertisedTileDataSize ?? UInt32(tileBlock.count))
    for _ in 0 ..< rectangleCount {
        region.appendLittleEndianUInt16(regionX)
        region.appendLittleEndianUInt16(regionY)
        region.appendLittleEndianUInt16(regionWidth)
        region.appendLittleEndianUInt16(regionHeight)
    }
    for _ in 0 ..< quantCount {
        region.append(contentsOf: [0x66, 0x66, 0x77, 0x88, 0x98])
    }
    for table in progressiveQuantTables {
        region.append(table)
    }
    region.append(tileBlock)
    var block = Data()
    block.appendRFXBlock(type: 0xCCC4, body: region)
    return block
}

private func rlgrAllZeroComponent() -> Data {
    var writer = BitWriter()
    var zeroCount: UInt32 = 64 * 64
    var k: UInt32 = 1
    var kp = k << 3
    var runMax: UInt32 = 1 << k
    while zeroCount >= runMax {
        writer.appendBit(0)
        zeroCount -= runMax
        kp = min(kp + 4, 80)
        k = kp >> 3
        runMax = 1 << k
    }
    writer.appendBit(1)
    writer.appendBits(zeroCount, count: Int(k))
    return writer.data()
}

func srlAllZeroComponent(count: UInt32 = 64 * 64) -> Data {
    var writer = BitWriter()
    var zeroCount = count
    var kp: UInt32 = 8
    var k = kp / 8
    while zeroCount >= 1 << k {
        writer.appendBit(0)
        zeroCount -= 1 << k
        kp = min(kp + 4, 80)
        k = kp / 8
    }
    writer.appendBit(1)
    writer.appendBits(zeroCount, count: Int(k))
    var data = writer.data()
    data.appendUInt8(0)
    return data
}

func rlgrSingleOneComponent() -> Data {
    var writer = BitWriter()
    writer.appendBit(1)
    writer.appendBit(0)
    writer.appendBit(0)
    writer.appendBit(0)
    writer.appendBit(0)
    writer.appendBit(0)
    writer.appendBit(0)

    var zeroCount: UInt32 = 64 * 64 - 3
    var k: UInt32 = 1
    var kp: UInt32 = 8
    while zeroCount > 0 {
        let runMax: UInt32 = 1 << k
        if zeroCount >= runMax {
            writer.appendBit(0)
            zeroCount -= runMax
            kp = min(kp + 4, 80)
            k = kp >> 3
        } else {
            writer.appendBit(1)
            writer.appendBits(zeroCount, count: Int(k))
            zeroCount = 0
        }
    }
    return writer.data()
}

private extension Data {
    mutating func appendRFXBlock(type: UInt16, body: Data) {
        appendLittleEndianUInt16(type)
        appendLittleEndianUInt32(UInt32(6 + body.count))
        append(body)
    }

    mutating func appendRFXChannelHeader(channelID: UInt8) {
        appendUInt8(1)
        appendUInt8(channelID)
    }
}

private struct BitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func appendBit(_ bit: UInt8) {
        if bitCount % 8 == 0 {
            bytes.append(0)
        }
        if bit != 0 {
            bytes[bytes.count - 1] |= 1 << UInt8(7 - bitCount % 8)
        }
        bitCount += 1
    }

    mutating func appendBits(_ value: UInt32, count: Int) {
        guard count > 0 else {
            return
        }
        for bitIndex in stride(from: count - 1, through: 0, by: -1) {
            appendBit(UInt8((value >> UInt32(bitIndex)) & 0x01))
        }
    }

    func data() -> Data {
        Data(bytes)
    }
}
