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
    tileXIndex: UInt16 = 0,
    tileYIndex: UInt16 = 0,
    contextProperties: UInt16 = 0xA828,
    tileSetProperties: UInt16 = 0x5051
) -> Data {
    let component = rlgrAllZeroComponent()
    var stream = Data()

    var sync = Data()
    sync.appendLittleEndianUInt32(0xCACC_ACCA)
    sync.appendLittleEndianUInt16(0x0100)
    stream.appendRFXBlock(type: 0xCCC0, body: sync)

    stream.appendRFXBlock(type: 0xCCC1, body: Data([
        0x01,
        0x01, 0x00, 0x01,
    ]))

    var channels = Data()
    channels.appendUInt8(1)
    channels.appendUInt8(0)
    channels.appendLittleEndianUInt16(channelWidth)
    channels.appendLittleEndianUInt16(channelHeight)
    stream.appendRFXBlock(type: 0xCCC2, body: channels)

    var context = Data()
    context.appendRFXChannelHeader(channelID: 0xFF)
    context.appendUInt8(0)
    context.appendLittleEndianUInt16(64)
    context.appendLittleEndianUInt16(contextProperties)
    stream.appendRFXBlock(type: 0xCCC3, body: context)

    var frameBegin = Data()
    frameBegin.appendRFXChannelHeader(channelID: 0)
    frameBegin.appendLittleEndianUInt32(frameIndex)
    frameBegin.appendLittleEndianUInt16(1)
    stream.appendRFXBlock(type: 0xCCC4, body: frameBegin)

    var region = Data()
    region.appendRFXChannelHeader(channelID: 0)
    region.appendUInt8(1)
    region.appendLittleEndianUInt16(1)
    region.appendLittleEndianUInt16(regionX)
    region.appendLittleEndianUInt16(regionY)
    region.appendLittleEndianUInt16(regionWidth)
    region.appendLittleEndianUInt16(regionHeight)
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
    tileSet.appendLittleEndianUInt16(0)
    tileSet.appendLittleEndianUInt16(tileSetProperties)
    tileSet.appendUInt8(1)
    tileSet.appendUInt8(64)
    tileSet.appendLittleEndianUInt16(1)
    tileSet.appendLittleEndianUInt32(UInt32(tileBlock.count))
    tileSet.append(contentsOf: [0x66, 0x66, 0x77, 0x88, 0x98])
    tileSet.append(tileBlock)
    stream.appendRFXBlock(type: 0xCCC7, body: tileSet)

    var frameEnd = Data()
    frameEnd.appendRFXChannelHeader(channelID: 0)
    stream.appendRFXBlock(type: 0xCCC5, body: frameEnd)

    return stream
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
