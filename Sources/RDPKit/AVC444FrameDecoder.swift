import CoreVideo
import Foundation

/// Decodes AVC444 and AVC444v2 updates (MS-RDPEGFX 3.3.8.3.2 and 3.3.8.3.3). Both subframes
/// travel in one H.264 stream; the main (luma) and auxiliary (chroma) views are combined and
/// converted to BGRA with the full-range BT.709 matrix of MS-RDPEGFX 3.3.8.3.1.
final class RDPAVC444FrameDecoder {
    private let h264Decoder = RDPVideoToolboxSequenceDecoder(codec: .h264, preservesCodedSamples: true)
    private let metalDecoder = RDPAVC444MetalDecoder()
    private var views = RDPAVC444Views()

    func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        guard let layout = frame.avc444SubframeLayout else {
            throw RDPAVC444DecodeError.missingLumaSubframe
        }
        var result = try h264Decoder.decodeDetailed(frame.encodedVideoData)
        let firstImageBuffer = result.imageBuffer
        var secondImageBuffer: CVImageBuffer?
        if let auxiliaryEncodedVideoData = frame.auxiliaryEncodedVideoData {
            let second = try h264Decoder.decodeDetailed(auxiliaryEncodedVideoData)
            secondImageBuffer = second.imageBuffer
            result.samplePreparationMilliseconds += second.samplePreparationMilliseconds
            result.videoToolboxMilliseconds += second.videoToolboxMilliseconds
        }

        let conversionStartedAt = Date()
        let (main, auxiliary) = try views.resolve(
            layout: layout,
            codecID: frame.codecID,
            first: firstImageBuffer,
            second: secondImageBuffer
        )
        let chromaRegionRects = auxiliary == nil ? [] : sourceRegionRects(
            layout == .chroma420Only ? frame.regionRects : frame.auxiliaryRegionRects,
            destinationRect: frame.destinationRect
        )
        let usesV2Layout = frame.codecID == RDPGFXCodecID.avc444v2
        result.imageBuffer = try reconstruct(
            main: main,
            auxiliary: auxiliary,
            usesV2Layout: usesV2Layout,
            chromaRegionRects: chromaRegionRects,
            frameWidth: h264Decoder.frameWidth
        )
        result.imageConversionMilliseconds = Date().timeIntervalSince(conversionStartedAt) * 1000
        result.decodedPixelFormat = kCVPixelFormatType_32BGRA
        return result
    }

    private func reconstruct(
        main: CVPixelBuffer,
        auxiliary: CVPixelBuffer?,
        usesV2Layout: Bool,
        chromaRegionRects: [RDPFrameRect],
        frameWidth: Int?
    ) throws -> CVPixelBuffer {
        if let metalDecoder {
            do {
                return try metalDecoder.reconstruct(
                    main: main,
                    auxiliary: auxiliary,
                    usesV2Layout: usesV2Layout,
                    chromaRegionRects: chromaRegionRects,
                    frameWidth: frameWidth
                )
            } catch is RDPAVC444MetalDecodeError {
                // Fall back to the CPU for buffers Metal cannot wrap.
            }
        }
        return try rdpReconstructAVC444OnCPU(
            main: main,
            auxiliary: auxiliary,
            usesV2Layout: usesV2Layout,
            chromaRegionRects: chromaRegionRects,
            frameWidth: frameWidth
        )
    }

    private func sourceRegionRects(
        _ regionRects: [RDPFrameRect],
        destinationRect: RDPFrameRect
    ) -> [RDPFrameRect] {
        let regionsAreRelative = regionRects.allSatisfy {
            $0.right <= destinationRect.width && $0.bottom <= destinationRect.height
        }
        guard !regionsAreRelative else {
            return regionRects
        }
        return regionRects.compactMap { region in
            let left = max(0, Int(region.left) - Int(destinationRect.left))
            let top = max(0, Int(region.top) - Int(destinationRect.top))
            let right = max(0, Int(region.right) - Int(destinationRect.left))
            let bottom = max(0, Int(region.bottom) - Int(destinationRect.top))
            guard right > left, bottom > top else {
                return nil
            }
            return RDPFrameRect(
                left: UInt16(clamping: left),
                top: UInt16(clamping: top),
                right: UInt16(clamping: right),
                bottom: UInt16(clamping: bottom)
            )
        }
    }
}

/// Pairs each update with the main view it combines with. A chroma-only update (LC 0x2) is
/// combined with the AVC stream decoded so far (MS-RDPEGFX 2.2.4.5): the surface's last main
/// view of the same codec, whatever rectangle it updated. `rdpAVC444FrameSize` rejects a
/// main view of another size.
struct RDPAVC444Views {
    private var lastMain: (codecID: UInt16, imageBuffer: CVImageBuffer)?

    mutating func resolve(
        layout: RDPAVC444SubframeLayout,
        codecID: UInt16,
        first: CVImageBuffer,
        second: CVImageBuffer?
    ) throws -> (main: CVImageBuffer, auxiliary: CVImageBuffer?) {
        switch layout {
        case .yuv420AndChroma420:
            guard let second else {
                throw RDPAVC444DecodeError.missingChromaSubframe
            }
            lastMain = (codecID, first)
            return (first, second)
        case .yuv420Only:
            lastMain = (codecID, first)
            return (first, nil)
        case .chroma420Only:
            guard let lastMain, lastMain.codecID == codecID else {
                throw RDPAVC444DecodeError.missingLumaSubframe
            }
            return (lastMain.imageBuffer, first)
        }
    }
}

/// W of MS-RDPEGFX 3.3.8.3.3, where the YUV444v2 auxiliary view's V halves start: the width
/// of the frames the encoder was given, which FreeRDP's encoders signal by SPS cropping
/// (general_RGBToAVC444YUVv2 packs at the frame width), and otherwise the coded width.
func rdpAVC444PackedWidth(frameWidth: Int?, codedWidth: Int) -> Int {
    guard let frameWidth, frameWidth > 0, frameWidth <= codedWidth else {
        return codedWidth
    }
    return frameWidth
}

/// Validates the NV12 views both reconstruction paths read and returns their size. The
/// auxiliary-view layouts are defined per 16x16 macroblock.
func rdpAVC444FrameSize(main: CVPixelBuffer, auxiliary: CVPixelBuffer?) throws -> (width: Int, height: Int) {
    let width = CVPixelBufferGetWidth(main)
    let height = CVPixelBufferGetHeight(main)
    for view in [main, auxiliary].compactMap({ $0 }) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(view)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else {
            throw RDPAVC444DecodeError.unsupportedPixelFormat(pixelFormat)
        }
        guard CVPixelBufferGetWidth(view) == width, CVPixelBufferGetHeight(view) == height else {
            throw RDPAVC444DecodeError.mismatchedSubframeDimensions
        }
    }
    guard width > 0, height > 0, width.isMultiple(of: 16), height.isMultiple(of: 16) else {
        throw RDPAVC444DecodeError.invalidYUV420Layout
    }
    return (width, height)
}

/// CPU fallback for `RDPAVC444MetalDecoder`; both implement the same per-pixel math.
func rdpReconstructAVC444OnCPU(
    main: CVPixelBuffer,
    auxiliary: CVPixelBuffer?,
    usesV2Layout: Bool,
    chromaRegionRects: [RDPFrameRect],
    frameWidth: Int? = nil
) throws -> CVPixelBuffer {
    let (width, height) = try rdpAVC444FrameSize(main: main, auxiliary: auxiliary)
    let output = try rdpMakeBGRAPixelBuffer(width: width, height: height)
    let views = [main, auxiliary].compactMap { $0 }
    for view in views {
        CVPixelBufferLockBaseAddress(view, .readOnly)
    }
    CVPixelBufferLockBaseAddress(output, [])
    defer {
        CVPixelBufferUnlockBaseAddress(output, [])
        for view in views {
            CVPixelBufferUnlockBaseAddress(view, .readOnly)
        }
    }
    guard let mainPlanes = RDPNV12Planes(main),
          let outputBase = CVPixelBufferGetBaseAddress(output)
    else {
        throw RDPAVC444DecodeError.missingPixelBufferPlane
    }
    let auxiliaryPlanes = auxiliary.flatMap(RDPNV12Planes.init)
    if auxiliary != nil, auxiliaryPlanes == nil {
        throw RDPAVC444DecodeError.missingPixelBufferPlane
    }

    let chromaMask = auxiliary == nil ? [] : avc444ChromaMask(
        width: width,
        height: height,
        regionRects: chromaRegionRects
    )
    chromaMask.withUnsafeBufferPointer { mask in
        RDPAVC444PixelWriter(
            main: mainPlanes,
            auxiliary: auxiliaryPlanes,
            chromaMask: mask.baseAddress,
            width: width,
            height: height,
            packedWidth: rdpAVC444PackedWidth(frameWidth: frameWidth, codedWidth: width),
            usesV2Layout: usesV2Layout,
            output: outputBase.assumingMemoryBound(to: UInt8.self),
            outputBytesPerRow: CVPixelBufferGetBytesPerRow(output)
        ).write()
    }
    return output
}

private func avc444ChromaMask(width: Int, height: Int, regionRects: [RDPFrameRect]) -> [Bool] {
    var mask = [Bool](repeating: false, count: width * height)
    for rect in regionRects {
        let left = min(width, Int(rect.left))
        let right = min(width, Int(rect.right))
        let top = min(height, Int(rect.top))
        let bottom = min(height, Int(rect.bottom))
        guard right > left, bottom > top else {
            continue
        }
        for row in top ..< bottom {
            mask.replaceSubrange(row * width + left ..< row * width + right, with: repeatElement(true, count: right - left))
        }
    }
    return mask
}

/// Read access to a locked NV12 pixel buffer. Chroma accessors take chroma-plane coordinates.
private struct RDPNV12Planes {
    var y: UnsafePointer<UInt8>
    var yBytesPerRow: Int
    var uv: UnsafePointer<UInt8>
    var uvBytesPerRow: Int

    init?(_ pixelBuffer: CVPixelBuffer) {
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return nil
        }
        self.y = UnsafePointer(y.assumingMemoryBound(to: UInt8.self))
        self.uv = UnsafePointer(uv.assumingMemoryBound(to: UInt8.self))
        yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    }

    func luma(_ x: Int, _ y: Int) -> Int {
        Int(self.y[y * yBytesPerRow + x])
    }

    func u(_ x: Int, _ y: Int) -> Int {
        Int(uv[y * uvBytesPerRow + x * 2])
    }

    func v(_ x: Int, _ y: Int) -> Int {
        Int(uv[y * uvBytesPerRow + x * 2 + 1])
    }
}

private struct RDPAVC444PixelWriter: @unchecked Sendable {
    var main: RDPNV12Planes
    var auxiliary: RDPNV12Planes?
    var chromaMask: UnsafePointer<Bool>?
    var width: Int
    var height: Int
    var packedWidth: Int
    var usesV2Layout: Bool
    var output: UnsafeMutablePointer<UInt8>
    var outputBytesPerRow: Int

    func write() {
        rdpConcurrentlyProcessRows(height: height) { rows in
            for y in rows {
                let outputRow = output.advanced(by: y * outputBytesPerRow)
                for x in 0 ..< width {
                    let (u, v) = chroma(x: x, y: y)
                    writeBGRAPixel(y: main.luma(x, y), u: u, v: v, to: outputRow.advanced(by: x * 4))
                }
            }
        }
    }

    private func chroma(x: Int, y: Int) -> (Int, Int) {
        guard let auxiliary, let chromaMask, chromaMask[y * width + x] else {
            return mainChroma(x: x, y: y)
        }
        return usesV2Layout
            ? v2Chroma(x: x, y: y, auxiliary: auxiliary)
            : v1Chroma(x: x, y: y, auxiliary: auxiliary)
    }

    private func mainChroma(x: Int, y: Int) -> (Int, Int) {
        (main.u(x / 2, y / 2), main.v(x / 2, y / 2))
    }

    /// MS-RDPEGFX 3.3.8.3.2: odd rows come from the auxiliary luma, interleaved per 8 lines of
    /// each 16-line macroblock (U then V); odd columns of even rows from the auxiliary chroma.
    private func v1Chroma(x: Int, y: Int, auxiliary: RDPNV12Planes) -> (Int, Int) {
        if x.isMultiple(of: 2), y.isMultiple(of: 2) {
            let row = (y / 16) * 16 + (y + 1) % 16 / 2
            return reverseFiltered(
                mainChroma(x: x, y: y),
                right: (auxiliary.u(x / 2, y / 2), auxiliary.v(x / 2, y / 2)),
                below: (auxiliary.luma(x, row), auxiliary.luma(x, row + 8)),
                belowRight: (auxiliary.luma(x + 1, row), auxiliary.luma(x + 1, row + 8))
            )
        }
        if y.isMultiple(of: 2) {
            return (auxiliary.u(x / 2, y / 2), auxiliary.v(x / 2, y / 2))
        }
        let row = (y / 16) * 16 + y % 16 / 2
        return (auxiliary.luma(x, row), auxiliary.luma(x, row + 8))
    }

    private func v2Chroma(x: Int, y: Int, auxiliary: RDPNV12Planes) -> (Int, Int) {
        if x.isMultiple(of: 2), y.isMultiple(of: 2) {
            return reverseFiltered(
                mainChroma(x: x, y: y),
                right: v2PackedChroma(x: x + 1, y: y, auxiliary: auxiliary),
                below: v2PackedChroma(x: x, y: y + 1, auxiliary: auxiliary),
                belowRight: v2PackedChroma(x: x + 1, y: y + 1, auxiliary: auxiliary)
            )
        }
        return v2PackedChroma(x: x, y: y, auxiliary: auxiliary)
    }

    /// MS-RDPEGFX 3.3.8.3.3: odd columns come from the left (U) and right (V) halves of the
    /// auxiliary luma; even columns of odd rows from quarter-width halves of the auxiliary U
    /// (x % 4 == 0) and V (x % 4 == 2) planes.
    private func v2PackedChroma(x: Int, y: Int, auxiliary: RDPNV12Planes) -> (Int, Int) {
        guard x.isMultiple(of: 2) else {
            return (auxiliary.luma(x / 2, y), auxiliary.luma(packedWidth / 2 + x / 2, y))
        }
        let planeX = x / 4
        let quarterWidth = packedWidth / 4
        return x.isMultiple(of: 4)
            ? (auxiliary.u(planeX, y / 2), auxiliary.u(quarterWidth + planeX, y / 2))
            : (auxiliary.v(planeX, y / 2), auxiliary.v(quarterWidth + planeX, y / 2))
    }

    /// MS-RDPEGFX 3.3.8.3.2: the even-position chroma is recovered from the main view's 2x2
    /// average, keeping the main-view value when the filter changes it by less than 30.
    private func reverseFiltered(
        _ filtered: (Int, Int),
        right: (Int, Int),
        below: (Int, Int),
        belowRight: (Int, Int)
    ) -> (Int, Int) {
        func component(_ filtered: Int, _ recovered: Int) -> Int {
            let reversed = clampedByte(recovered)
            return abs(reversed - filtered) < 30 ? filtered : reversed
        }
        return (
            component(filtered.0, 4 * filtered.0 - right.0 - below.0 - belowRight.0),
            component(filtered.1, 4 * filtered.1 - right.1 - below.1 - belowRight.1)
        )
    }
}

func rdpConcurrentlyProcessRows(
    height: Int,
    operation: @escaping @Sendable (Range<Int>) -> Void
) {
    let workerCount = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount))
    DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
        let start = height * workerIndex / workerCount
        let end = height * (workerIndex + 1) / workerCount
        operation(start ..< end)
    }
}

/// Full-range BT.709 YUV to RGB (MS-RDPEGFX 3.3.8.3.1) in 8.8 fixed point.
@inline(__always)
private func writeBGRAPixel(y: Int, u: Int, v: Int, to output: UnsafeMutablePointer<UInt8>) {
    let r = (256 * y + 403 * (v - 128)) >> 8
    let g = (256 * y - 48 * (u - 128) - 120 * (v - 128)) >> 8
    let b = (256 * y + 475 * (u - 128)) >> 8
    output[0] = UInt8(clampedByte(b))
    output[1] = UInt8(clampedByte(g))
    output[2] = UInt8(clampedByte(r))
    output[3] = 255
}

private func clampedByte(_ value: Int) -> Int {
    min(max(value, 0), 255)
}

enum RDPAVC444DecodeError: Error, Equatable, CustomStringConvertible {
    case invalidYUV420Layout
    case unsupportedPixelFormat(UInt32)
    case missingPixelBufferPlane
    case missingLumaSubframe
    case missingChromaSubframe
    case mismatchedSubframeDimensions

    var description: String {
        switch self {
        case .invalidYUV420Layout:
            "The decoded AVC444 subframe has an invalid YUV420 layout."
        case let .unsupportedPixelFormat(pixelFormat):
            "The decoded AVC444 subframe has unsupported pixel format \(pixelFormat)."
        case .missingPixelBufferPlane:
            "Core Video did not expose an AVC444 pixel-buffer plane."
        case .missingLumaSubframe:
            "An AVC444 chroma-only update arrived before a luma subframe."
        case .missingChromaSubframe:
            "A combined AVC444 update is missing its chroma subframe."
        case .mismatchedSubframeDimensions:
            "The AVC444 luma and chroma subframes have different dimensions."
        }
    }
}
