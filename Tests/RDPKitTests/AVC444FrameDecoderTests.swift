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

/// FreeRDP packs YUV444v2 at the width of the frames its encoder was given
/// (general_RGBToAVC444YUVv2), which SPS cropping states when the coded picture is wider.
@Test func reconstructsAVC444v2AtTheFrameWidth() throws {
    // A 24-column frame coded 32 wide: its V halves start at column 12 of the auxiliary luma
    // and column 6 of the auxiliary U and V planes.
    let auxiliaryY = (0 ..< 16).flatMap { _ in (0 ..< 32).map { UInt8($0 * 4) } }
    let auxiliaryChroma = (0 ..< 8).flatMap { _ in (0 ..< 16).map { UInt8(100 + $0 * 4) } }

    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try nv12PixelBuffer(
            width: 32,
            y: [UInt8](repeating: 128, count: 512),
            u: [UInt8](repeating: 128, count: 128),
            v: [UInt8](repeating: 128, count: 128)
        ),
        auxiliary: try nv12PixelBuffer(width: 32, y: auxiliaryY, u: auxiliaryChroma, v: auxiliaryChroma),
        usesV2Layout: true,
        chromaRegionRects: [RDPFrameRect(left: 0, top: 0, right: 32, bottom: 16)],
        frameWidth: 24
    )

    #expect(try bgraPixel(x: 3, y: 0, in: reconstructed) == bgra(y: 128, u: 4, v: 52))
    #expect(try bgraPixel(x: 4, y: 1, in: reconstructed) == bgra(y: 128, u: 104, v: 128))
}

/// freerdp-shadow codes its 1920x1080 AVC444v2 frames as 1920x1088 pictures cropped in the SPS.
/// The fixture's first frame shows mpv's test pattern in a 1280x720 window at the top left:
/// six colour bars about 213 pixels wide, of which red, green, and blue are checked.
@Test func freeRDPAVC444v2FrameDecodesItsColourBars() throws {
    let frame = try #require(replayTranscriptFixture("freerdp-shadow-avc444v2-transcript").report.rdpGraphicsFirstFrame)
    #expect(frame.codecID == RDPGFXCodecID.avc444v2)
    #expect(frame.avc444SubframeLayout == .yuv420AndChroma420)

    let imageBuffer = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame).imageBuffer

    #expect(CVPixelBufferGetWidth(imageBuffer) == 1920)
    #expect(CVPixelBufferGetHeight(imageBuffer) == 1088)
    for (bar, colour) in [(0, [253, 23, 0]), (1, [0, 216, 0]), (3, [0, 14, 255])] {
        let pixel = try bgraPixel(x: bar * 213 + 100, y: 660, in: imageBuffer)
        let decoded = [Int(pixel[2]), Int(pixel[1]), Int(pixel[0])]
        #expect(zip(decoded, colour).allSatisfy { abs($0 - $1) <= 6 }, "bar \(bar): \(decoded)")
    }
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

@Test func AVC444IgnoresInvertedChromaRegion() throws {
    let reconstructed = try rdpReconstructAVC444OnCPU(
        main: try flatNV12PixelBuffer(y: 128, u: 100, v: 150),
        auxiliary: try flatNV12PixelBuffer(y: 40, u: 50, v: 190),
        usesV2Layout: false,
        chromaRegionRects: [RDPFrameRect(left: 0, top: 10, right: 8, bottom: 4)]
    )

    #expect(try bgraPixel(x: 1, y: 5, in: reconstructed) == bgra(y: 128, u: 100, v: 150))
}

@Test func AVC444ChromaOnlyUpdateCombinesWithLastLumaView() throws {
    var views = RDPAVC444Views()
    let luma = try flatNV12PixelBuffer(y: 90, u: 100, v: 150)
    let lumaViews = try views.resolve(
        layout: .yuv420Only,
        codecID: RDPGFXCodecID.avc444,
        first: luma,
        second: nil
    )
    #expect(lumaViews.main === luma)
    #expect(lumaViews.auxiliary == nil)

    let chroma = try flatNV12PixelBuffer(y: 128, u: 50, v: 190)
    let chromaViews = try views.resolve(
        layout: .chroma420Only,
        codecID: RDPGFXCodecID.avc444,
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
            first: chroma,
            second: nil
        )
    }

    _ = try views.resolve(
        layout: .yuv420Only,
        codecID: RDPGFXCodecID.avc444,
        first: try flatNV12PixelBuffer(y: 90, u: 100, v: 150),
        second: nil
    )
    // Another packing mode does not reuse the stored luma view.
    #expect(throws: RDPAVC444DecodeError.missingLumaSubframe) {
        try views.resolve(
            layout: .chroma420Only,
            codecID: RDPGFXCodecID.avc444v2,
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
    let invertedRegions = [RDPFrameRect(left: 0, top: 10, right: 8, bottom: 4)]
    let auxiliaries: [CVPixelBuffer?] = [
        nil,
        try flatNV12PixelBuffer(y: 40, u: 50, v: 190),
        try flatNV12PixelBuffer(y: 90, u: 90, v: 90),
        try nv12PixelBuffer(
            y: (0 ..< 256).map { UInt8($0 % 16 * 8) },
            u: (0 ..< 64).map { UInt8(100 + $0 % 8 * 10) },
            v: (0 ..< 64).map { UInt8(60 + $0 % 8 * 12) }
        ),
    ]

    for usesV2Layout in [false, true] {
        for chromaRegions in [[], regions, invertedRegions] {
            for auxiliary in auxiliaries {
                for frameWidth in [nil, 8] {
                    let expected = try rdpReconstructAVC444OnCPU(
                        main: main,
                        auxiliary: auxiliary,
                        usesV2Layout: usesV2Layout,
                        chromaRegionRects: chromaRegions,
                        frameWidth: frameWidth
                    )
                    let actual = try metalDecoder.reconstruct(
                        main: main,
                        auxiliary: auxiliary,
                        usesV2Layout: usesV2Layout,
                        chromaRegionRects: chromaRegions,
                        frameWidth: frameWidth
                    )

                    #expect(try bgraData(from: actual) == bgraData(from: expected))
                }
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

@Test func AVC444ChromaOnlyUpdateCombinesWithLumaOfAnotherRectangle() throws {
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 20, chroma: 128), (luma: 128, chroma: 128)])
    let decoder = RDPVideoToolboxFrameDecoder()
    func frame(_ layout: RDPAVC444SubframeLayout, left: UInt16, data: Data) -> RDPGraphicsFrameSnapshot {
        let destinationRect = RDPFrameRect(left: left, top: 0, right: left + 64, bottom: 64)
        return RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 1,
            codecID: RDPGFXCodecID.avc444,
            codecName: "avc444",
            pixelFormat: 32,
            destinationRect: destinationRect,
            regionRects: [destinationRect],
            encodedVideoData: data,
            avc444SubframeLayout: layout
        )
    }

    _ = try decoder.decodeDetailed(frame(.yuv420Only, left: 0, data: accessUnits[0]))
    let result = try decoder.decodeDetailed(frame(.chroma420Only, left: 64, data: accessUnits[1]))

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
