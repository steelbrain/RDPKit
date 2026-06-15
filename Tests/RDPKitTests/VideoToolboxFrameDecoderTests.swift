import CoreVideo
import Foundation
@testable import RDPKit
import Testing

@Test func videoToolboxFrameDecoderCopiesBitmapFramesThroughReusableDecoder() throws {
    let decoder = RDPVideoToolboxFrameDecoder()

    let first = try decoder.decodeDetailed(bitmapFrame(pixels: [
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ]))
    let second = try decoder.decodeDetailed(bitmapFrame(pixels: [
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
        0x70, 0x80, 0x90, 0xFF,
        0xA0, 0xB0, 0xC0, 0xFF,
    ]))

    #expect(CVPixelBufferGetWidth(first.imageBuffer) == 2)
    #expect(CVPixelBufferGetHeight(first.imageBuffer) == 2)
    #expect(CVPixelBufferGetPixelFormatType(first.imageBuffer) == kCVPixelFormatType_32BGRA)
    #expect(try bgraPixel(atX: 1, y: 0, in: first.imageBuffer) == [0x04, 0x05, 0x06, 0xFF])

    #expect(CVPixelBufferGetWidth(second.imageBuffer) == 2)
    #expect(CVPixelBufferGetHeight(second.imageBuffer) == 2)
    #expect(CVPixelBufferGetPixelFormatType(second.imageBuffer) == kCVPixelFormatType_32BGRA)
    #expect(try bgraPixel(atX: 0, y: 1, in: second.imageBuffer) == [0x70, 0x80, 0x90, 0xFF])
}

private func bitmapFrame(pixels: [UInt8]) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 0x20,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data(pixels),
        decodedBitmapBytesPerRow: 8
    )
}

private func bgraPixel(atX x: Int, y: Int, in imageBuffer: CVImageBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
        throw PixelReadError.missingBaseAddress
    }

    let offset = y * CVPixelBufferGetBytesPerRow(imageBuffer) + x * 4
    let pixel = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    return [pixel[0], pixel[1], pixel[2], pixel[3]]
}

private enum PixelReadError: Error {
    case missingBaseAddress
}
