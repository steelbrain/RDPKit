import CoreVideo
import Foundation
import Testing
@testable import RDPKit

@Test func reconstructsAVC444MacroblockChroma() throws {
    let main = try yuv420Frame(y: 128, u: 100, v: 150)
    var auxiliaryY = [UInt8](repeating: 40, count: 16 * 16)
    for row in 8 ..< 16 {
        auxiliaryY.replaceSubrange(row * 16 ..< (row + 1) * 16, with: repeatElement(200, count: 16))
    }
    let auxiliary = try RDPYUV420Frame(
        width: 16,
        height: 16,
        y: auxiliaryY,
        u: [UInt8](repeating: 50, count: 64),
        v: [UInt8](repeating: 190, count: 64)
    )

    let reconstructed = try RDPAVC444FrameStore().reconstruct(
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444,
        layout: .yuv420AndChroma420,
        firstFrame: main,
        secondFrame: auxiliary,
        chromaRegionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)]
    )

    #expect(pixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 50, v: 190))
    #expect(pixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 40, v: 200))
    #expect(pixel(x: 1, y: 1, in: reconstructed) == bgra(y: 128, u: 40, v: 200))
    #expect(pixel(x: 0, y: 0, in: reconstructed) == bgra(y: 128, u: 255, v: 10))
}

@Test func reconstructsAVC444v2FullFrameChroma() throws {
    let main = try yuv420Frame(y: 128, u: 100, v: 150)
    var auxiliaryY = [UInt8](repeating: 60, count: 16 * 16)
    for row in 0 ..< 16 {
        auxiliaryY.replaceSubrange(row * 16 + 8 ..< (row + 1) * 16, with: repeatElement(180, count: 8))
    }
    var auxiliaryU = [UInt8](repeating: 70, count: 64)
    var auxiliaryV = [UInt8](repeating: 80, count: 64)
    for row in 0 ..< 8 {
        auxiliaryU.replaceSubrange(row * 8 + 4 ..< (row + 1) * 8, with: repeatElement(170, count: 4))
        auxiliaryV.replaceSubrange(row * 8 + 4 ..< (row + 1) * 8, with: repeatElement(160, count: 4))
    }
    let auxiliary = try RDPYUV420Frame(
        width: 16,
        height: 16,
        y: auxiliaryY,
        u: auxiliaryU,
        v: auxiliaryV
    )

    let reconstructed = try RDPAVC444FrameStore().reconstruct(
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444v2,
        layout: .yuv420AndChroma420,
        firstFrame: main,
        secondFrame: auxiliary,
        chromaRegionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)]
    )

    #expect(pixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 60, v: 180))
    #expect(pixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 70, v: 170))
    #expect(pixel(x: 2, y: 1, in: reconstructed) == bgra(y: 128, u: 80, v: 160))
    #expect(pixel(x: 0, y: 0, in: reconstructed) == bgra(y: 128, u: 210, v: 70))
}

@Test func AVC444UsesChromaOnlyInsideChromaRegions() throws {
    let main = try yuv420Frame(y: 128, u: 100, v: 150)
    let auxiliary = try yuv420Frame(y: 40, u: 50, v: 190)
    let reconstructed = try RDPAVC444FrameStore().reconstruct(
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444,
        layout: .yuv420AndChroma420,
        firstFrame: main,
        secondFrame: auxiliary,
        chromaRegionRects: [RDPFrameRect(left: 8, top: 0, right: 16, bottom: 16)]
    )

    #expect(pixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
    #expect(pixel(x: 9, y: 0, in: reconstructed) == bgra(y: 128, u: 50, v: 190))
}

@Test func AVC444DoesNotApplyChromaOutsideAnEmptyRegionMask() throws {
    let main = try yuv420Frame(y: 128, u: 100, v: 150)
    let auxiliary = try yuv420Frame(y: 40, u: 50, v: 190)
    let reconstructed = try RDPAVC444FrameStore().reconstruct(
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444,
        layout: .yuv420AndChroma420,
        firstFrame: main,
        secondFrame: auxiliary,
        chromaRegionRects: []
    )

    #expect(pixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
    #expect(pixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
}

@Test func AVC444LumaOnlyUsesYUV420AndPersistsForChromaOnlyUpdate() throws {
    let store = RDPAVC444FrameStore()
    let main = try yuv420Frame(y: 90, u: 100, v: 150)
    let luma = try store.reconstruct(
        surfaceID: 7,
        codecID: RDPGFXCodecID.avc444,
        layout: .yuv420Only,
        firstFrame: main,
        secondFrame: nil
    )
    #expect(pixel(x: 3, y: 4, in: luma) == bgra(y: 90, u: 100, v: 150))

    let auxiliary = try yuv420Frame(y: 128, u: 50, v: 190)
    let chroma = try store.reconstruct(
        surfaceID: 7,
        codecID: RDPGFXCodecID.avc444,
        layout: .chroma420Only,
        firstFrame: auxiliary,
        secondFrame: nil,
        chromaRegionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)]
    )
    #expect(pixel(x: 1, y: 0, in: chroma) == bgra(y: 90, u: 50, v: 190))
}

@Test func rejectsAVC444ChromaOnlyUpdateWithoutStoredLuma() throws {
    let auxiliary = try yuv420Frame(y: 128, u: 50, v: 190)
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try RDPAVC444FrameStore().reconstruct(
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444,
            layout: .chroma420Only,
            firstFrame: auxiliary,
            secondFrame: nil
        )
    }
}

@Test func AVC444DoesNotReuseLumaFromAnotherPackingMode() throws {
    let store = RDPAVC444FrameStore()
    let main = try yuv420Frame(y: 90, u: 100, v: 150)
    _ = try store.reconstruct(
        surfaceID: 7,
        codecID: RDPGFXCodecID.avc444,
        layout: .yuv420Only,
        firstFrame: main,
        secondFrame: nil
    )

    let auxiliary = try yuv420Frame(y: 128, u: 50, v: 190)
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try store.reconstruct(
            surfaceID: 7,
            codecID: RDPGFXCodecID.avc444v2,
            layout: .chroma420Only,
            firstFrame: auxiliary,
            secondFrame: nil
        )
    }
}

@Test func AVC444DoesNotReuseLumaFromAnotherSurfaceRectangle() throws {
    let store = RDPAVC444FrameStore()
    let main = try yuv420Frame(y: 90, u: 100, v: 150)
    _ = try store.reconstruct(
        surfaceID: 7,
        codecID: RDPGFXCodecID.avc444v2,
        layout: .yuv420Only,
        firstFrame: main,
        secondFrame: nil,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)
    )

    let auxiliary = try yuv420Frame(y: 128, u: 50, v: 190)
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try store.reconstruct(
            surfaceID: 7,
            codecID: RDPGFXCodecID.avc444v2,
            layout: .chroma420Only,
            firstFrame: auxiliary,
            secondFrame: nil,
            destinationRect: RDPFrameRect(left: 16, top: 0, right: 32, bottom: 16)
        )
    }
}

@Test func rejectsUnalignedAVC444v2CodedFrame() throws {
    let main = try RDPYUV420Frame(
        width: 4,
        height: 2,
        y: [UInt8](repeating: 128, count: 8),
        u: [UInt8](repeating: 100, count: 2),
        v: [UInt8](repeating: 150, count: 2)
    )

    #expect(throws: RDPAVC444DecodeError.invalidYUV420Layout) {
        try RDPAVC444FrameStore().reconstruct(
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444v2,
            layout: .yuv420Only,
            firstFrame: main,
            secondFrame: nil
        )
    }
}

@Test func MetalAVC444ReconstructionMatchesCPUFallback() throws {
    let metalDecoder = try #require(RDPAVC444MetalDecoder())
    let main = try yuv420Frame(y: 128, u: 100, v: 150)
    let auxiliary = try yuv420Frame(y: 40, u: 50, v: 190)
    let destinationRect = RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)
    let regions = [RDPFrameRect(left: 4, top: 2, right: 14, bottom: 13)]

    for codecID in [RDPGFXCodecID.avc444, RDPGFXCodecID.avc444v2] {
        for chromaRegions in [[], regions] {
            let expected = try RDPAVC444FrameStore().reconstruct(
                surfaceID: 1,
                codecID: codecID,
                layout: .yuv420AndChroma420,
                firstFrame: main,
                secondFrame: auxiliary,
                destinationRect: destinationRect,
                chromaRegionRects: chromaRegions
            )
            let actual = try metalDecoder.decode(
                surfaceID: 1,
                codecID: codecID,
                layout: .yuv420AndChroma420,
                firstImageBuffer: try nv12PixelBuffer(from: main),
                secondImageBuffer: try nv12PixelBuffer(from: auxiliary),
                destinationRect: destinationRect,
                chromaRegionRects: chromaRegions
            )

            #expect(try bgraData(from: actual) == expected.bgra)
        }
    }
}

private func yuv420Frame(y: UInt8, u: UInt8, v: UInt8) throws -> RDPYUV420Frame {
    try RDPYUV420Frame(
        width: 16,
        height: 16,
        y: [UInt8](repeating: y, count: 256),
        u: [UInt8](repeating: u, count: 64),
        v: [UInt8](repeating: v, count: 64)
    )
}

private func pixel(x: Int, y: Int, in frame: RDPAVC444ReconstructedFrame) -> [UInt8] {
    let offset = (y * frame.width + x) * 4
    return Array(frame.bgra[offset ..< offset + 4])
}

private func bgra(y: Int, u: Int, v: Int) -> [UInt8] {
    let r = clamped((256 * y + 403 * (v - 128)) >> 8)
    let g = clamped((256 * y - 48 * (u - 128) - 120 * (v - 128)) >> 8)
    let b = clamped((256 * y + 475 * (u - 128)) >> 8)
    return [UInt8(b), UInt8(g), UInt8(r), 255]
}

private func clamped(_ value: Int) -> Int {
    min(max(value, 0), 255)
}

private func nv12PixelBuffer(from frame: RDPYUV420Frame) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame.width,
        frame.height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw AVC444MetalTestError.pixelBufferCreationFailed(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
        throw AVC444MetalTestError.missingBaseAddress
    }
    let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    frame.y.withUnsafeBytes { source in
        guard let sourceBase = source.baseAddress else {
            return
        }
        for row in 0 ..< frame.height {
            memcpy(
                yBase.advanced(by: row * yBytesPerRow),
                sourceBase.advanced(by: row * frame.width),
                frame.width
            )
        }
    }
    frame.u.withUnsafeBufferPointer { u in
        frame.v.withUnsafeBufferPointer { v in
            let destination = uvBase.assumingMemoryBound(to: UInt8.self)
            for row in 0 ..< frame.height / 2 {
                for column in 0 ..< frame.width / 2 {
                    let sourceOffset = row * frame.width / 2 + column
                    destination[row * uvBytesPerRow + column * 2] = u[sourceOffset]
                    destination[row * uvBytesPerRow + column * 2 + 1] = v[sourceOffset]
                }
            }
        }
    }
    return pixelBuffer
}

private func bgraData(from pixelBuffer: CVPixelBuffer) throws -> Data {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AVC444MetalTestError.missingBaseAddress
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    var data = Data(repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { destination in
        guard let destinationBase = destination.baseAddress else {
            return
        }
        for row in 0 ..< height {
            memcpy(
                destinationBase.advanced(by: row * width * 4),
                baseAddress.advanced(by: row * bytesPerRow),
                width * 4
            )
        }
    }
    return data
}

private enum AVC444MetalTestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case missingBaseAddress
}
