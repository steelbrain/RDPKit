import CoreVideo
import Foundation
@testable import RDPKit
import Testing

private let fullFrame = [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)]

@Test func reconstructsAVC444MacroblockChroma() throws {
    var auxiliaryY = [UInt8](repeating: 40, count: 16 * 16)
    for row in 8 ..< 16 {
        auxiliaryY.replaceSubrange(row * 16 ..< (row + 1) * 16, with: repeatElement(200, count: 16))
    }
    let auxiliary = try nv12PixelBuffer(
        y: auxiliaryY,
        u: [UInt8](repeating: 50, count: 64),
        v: [UInt8](repeating: 190, count: 64)
    )

    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: auxiliary,
        usesV2Layout: false,
        chromaRegionRects: fullFrame
    )

    #expect(try bgraPixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 50, v: 190))
    #expect(try bgraPixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 40, v: 200))
    #expect(try bgraPixel(x: 1, y: 1, in: reconstructed) == bgra(y: 128, u: 40, v: 200))
    #expect(try bgraPixel(x: 0, y: 0, in: reconstructed) == bgra(y: 128, u: 255, v: 10))
}

@Test func reconstructsAVC444v2FullFrameChroma() throws {
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

    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: try nv12PixelBuffer(y: auxiliaryY, u: auxiliaryU, v: auxiliaryV),
        usesV2Layout: true,
        chromaRegionRects: fullFrame
    )

    #expect(try bgraPixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 60, v: 180))
    #expect(try bgraPixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 70, v: 170))
    #expect(try bgraPixel(x: 2, y: 1, in: reconstructed) == bgra(y: 128, u: 80, v: 160))
    #expect(try bgraPixel(x: 0, y: 0, in: reconstructed) == bgra(y: 128, u: 210, v: 70))
}

@Test func AVC444ReverseFilterAppliesAtThresholdOfThirty() throws {
    // U: 4 * 100 - 3 * 90 = 130 changes the main value by exactly 30, so MS-RDPEGFX
    // 3.3.8.3.2 uses the reversed value; only changes below 30 keep the main value.
    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: try flatNV12PixelBuffer(y: 90, u: 90, v: 90),
        usesV2Layout: false,
        chromaRegionRects: fullFrame
    )

    #expect(try bgraPixel(x: 0, y: 0, in: reconstructed) == bgra(y: 128, u: 130, v: 255))
}

@Test func AVC444UsesChromaOnlyInsideChromaRegions() throws {
    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: try flatNV12PixelBuffer(y: 40, u: 50, v: 190),
        usesV2Layout: false,
        chromaRegionRects: [RDPFrameRect(left: 8, top: 0, right: 16, bottom: 16)]
    )

    #expect(try bgraPixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
    #expect(try bgraPixel(x: 9, y: 0, in: reconstructed) == bgra(y: 128, u: 50, v: 190))
}

@Test func AVC444DoesNotApplyChromaOutsideAnEmptyRegionMask() throws {
    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: try flatNV12PixelBuffer(y: 40, u: 50, v: 190),
        usesV2Layout: false,
        chromaRegionRects: []
    )

    #expect(try bgraPixel(x: 1, y: 0, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
    #expect(try bgraPixel(x: 0, y: 1, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
}

@Test func AVC444ChromaOnlyUpdateCombinesWithLastLumaView() throws {
    var views = RDPAVC444Views()
    let luma = try flatNV12PixelBuffer(y: 90, u: 100, v: 150)
    let lumaViews = try views.resolve(
        layout: .yuv420Only,
        codecID: RDPGFXCodecID.avc444,
        destinationRect: fullFrame[0],
        first: luma,
        second: nil
    )
    #expect(lumaViews.main === luma)
    #expect(lumaViews.auxiliary == nil)

    let chroma = try flatNV12PixelBuffer(y: 128, u: 50, v: 190)
    let chromaViews = try views.resolve(
        layout: .chroma420Only,
        codecID: RDPGFXCodecID.avc444,
        destinationRect: fullFrame[0],
        first: chroma,
        second: nil
    )
    #expect(chromaViews.main === luma)
    #expect(chromaViews.auxiliary === chroma)
}

@Test func AVC444ChromaOnlyUpdateRequiresMatchingLumaView() throws {
    let chroma = try flatNV12PixelBuffer(y: 128, u: 50, v: 190)
    var views = RDPAVC444Views()
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try views.resolve(
            layout: .chroma420Only,
            codecID: RDPGFXCodecID.avc444,
            destinationRect: fullFrame[0],
            first: chroma,
            second: nil
        )
    }

    _ = try views.resolve(
        layout: .yuv420Only,
        codecID: RDPGFXCodecID.avc444,
        destinationRect: fullFrame[0],
        first: try flatNV12PixelBuffer(y: 90, u: 100, v: 150),
        second: nil
    )
    // Another packing mode or another rectangle does not reuse the stored luma view.
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try views.resolve(
            layout: .chroma420Only,
            codecID: RDPGFXCodecID.avc444v2,
            destinationRect: fullFrame[0],
            first: chroma,
            second: nil
        )
    }
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try views.resolve(
            layout: .chroma420Only,
            codecID: RDPGFXCodecID.avc444,
            destinationRect: RDPFrameRect(left: 16, top: 0, right: 32, bottom: 16),
            first: chroma,
            second: nil
        )
    }
}

@Test func rejectsUnalignedAVC444CodedFrame() throws {
    let main = try nv12PixelBuffer(
        width: 4,
        height: 2,
        y: [UInt8](repeating: 128, count: 8),
        u: [UInt8](repeating: 100, count: 2),
        v: [UInt8](repeating: 150, count: 2)
    )

    #expect(throws: RDPAVC444DecodeError.invalidYUV420Layout) {
        try rdpReconstructAVC444OnCPU(main: main, auxiliary: nil, usesV2Layout: true, chromaRegionRects: [])
    }
}

@Test func MetalAVC444ReconstructionMatchesCPUFallback() throws {
    let metalDecoder = try #require(RDPAVC444MetalDecoder())
    let main = try flatNV12PixelBuffer(y: 128, u: 100, v: 150)
    let regions = [RDPFrameRect(left: 4, top: 2, right: 14, bottom: 13)]
    let auxiliaries: [CVPixelBuffer?] = [
        nil,
        try flatNV12PixelBuffer(y: 40, u: 50, v: 190),
        try flatNV12PixelBuffer(y: 90, u: 90, v: 90),
    ]

    for usesV2Layout in [false, true] {
        for chromaRegions in [[], regions] {
            for auxiliary in auxiliaries {
                let expected = try rdpReconstructAVC444OnCPU(
                    main: main,
                    auxiliary: auxiliary,
                    usesV2Layout: usesV2Layout,
                    chromaRegionRects: chromaRegions
                )
                let actual = try metalDecoder.reconstruct(
                    main: main,
                    auxiliary: auxiliary,
                    usesV2Layout: usesV2Layout,
                    chromaRegionRects: chromaRegions
                )

                #expect(try bgraData(from: actual) == bgraData(from: expected))
            }
        }
    }
}

@Test func AVC444DecodesVideoToolboxStreamWithFullRangeConversion() throws {
    // Two pictures of one stream: the main view (luma 20, neutral chroma) and a neutral
    // auxiliary view. The coded luma must reach the BT.709 full-range conversion unscaled.
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 20, chroma: 128), (luma: 128, chroma: 128)])
    let decoder = RDPVideoToolboxFrameDecoder()
    let destinationRect = RDPFrameRect(left: 0, top: 0, right: 64, bottom: 64)
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc444,
        codecName: "avc444",
        pixelFormat: 32,
        destinationRect: destinationRect,
        regionRects: [destinationRect],
        encodedVideoData: accessUnits[0],
        auxiliaryEncodedVideoData: accessUnits[1],
        auxiliaryRegionRects: [destinationRect],
        avc444SubframeLayout: .yuv420AndChroma420
    )

    let result = try decoder.decodeDetailed(frame)

    #expect(CVPixelBufferGetPixelFormatType(result.imageBuffer) == kCVPixelFormatType_32BGRA)
    let pixel = try bgraPixel(x: 10, y: 10, in: result.imageBuffer)
    #expect(pixel.prefix(3).allSatisfy { abs(Int($0) - 20) <= 3 })
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

private func flatNV12PixelBuffer(y: UInt8, u: UInt8, v: UInt8) throws -> CVPixelBuffer {
    try nv12PixelBuffer(
        y: [UInt8](repeating: y, count: 256),
        u: [UInt8](repeating: u, count: 64),
        v: [UInt8](repeating: v, count: 64)
    )
}

private func nv12PixelBuffer(
    width: Int = 16,
    height: Int = 16,
    y: [UInt8],
    u: [UInt8],
    v: [UInt8]
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw AVC444TestError.pixelBufferCreationFailed(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
        throw AVC444TestError.missingBaseAddress
    }
    let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let yDestination = yBase.assumingMemoryBound(to: UInt8.self)
    for row in 0 ..< height {
        for column in 0 ..< width {
            yDestination[row * yBytesPerRow + column] = y[row * width + column]
        }
    }
    let uvDestination = uvBase.assumingMemoryBound(to: UInt8.self)
    for row in 0 ..< height / 2 {
        for column in 0 ..< width / 2 {
            let sourceOffset = row * width / 2 + column
            uvDestination[row * uvBytesPerRow + column * 2] = u[sourceOffset]
            uvDestination[row * uvBytesPerRow + column * 2 + 1] = v[sourceOffset]
        }
    }
    return pixelBuffer
}

private func bgraPixel(x: Int, y: Int, in pixelBuffer: CVPixelBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw AVC444TestError.missingBaseAddress
    }
    let pixel = baseAddress
        .advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4)
        .assumingMemoryBound(to: UInt8.self)
    return [pixel[0], pixel[1], pixel[2], pixel[3]]
}

private func bgraData(from pixelBuffer: CVPixelBuffer) throws -> [UInt8] {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    return try (0 ..< height).flatMap { y in
        try (0 ..< width).flatMap { x in try bgraPixel(x: x, y: y, in: pixelBuffer) }
    }
}

private enum AVC444TestError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case missingBaseAddress
}
