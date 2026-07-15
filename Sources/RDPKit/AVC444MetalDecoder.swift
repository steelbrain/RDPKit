import CoreVideo
import Foundation
import Metal

final class RDPAVC444MetalDecoder {
    private struct MainFrameKey: Hashable {
        var surfaceID: UInt16
        var codecID: UInt16
        var left: UInt16
        var top: UInt16
        var right: UInt16
        var bottom: UInt16
    }

    private struct WrappedTexture {
        var coreVideoTexture: CVMetalTexture
        var metalTexture: MTLTexture
    }

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var layout: UInt32
        var hasAuxiliary: UInt32
        var regionCount: UInt32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var mainFrames: [MainFrameKey: CVPixelBuffer] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "reconstructAVC444"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else {
            return nil
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess,
              textureCache != nil
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = textureCache
    }

    func reset() {
        mainFrames.removeAll()
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    func storeMainFrame(
        surfaceID: UInt16,
        codecID: UInt16,
        imageBuffer: CVImageBuffer,
        destinationRect: RDPFrameRect
    ) throws {
        guard codecID == RDPGFXCodecID.avc444 || codecID == RDPGFXCodecID.avc444v2 else {
            throw RDPAVC444DecodeError.unsupportedCodec(codecID)
        }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width > 0,
              height > 0,
              width.isMultiple(of: 16),
              height.isMultiple(of: 16),
              isNV12(imageBuffer)
        else {
            throw RDPAVC444DecodeError.invalidYUV420Layout
        }
        mainFrames[mainFrameKey(
            surfaceID: surfaceID,
            codecID: codecID,
            destinationRect: destinationRect
        )] = imageBuffer
    }

    func decode(
        surfaceID: UInt16,
        codecID: UInt16,
        layout: RDPAVC444SubframeLayout,
        firstImageBuffer: CVImageBuffer,
        secondImageBuffer: CVImageBuffer?,
        destinationRect: RDPFrameRect,
        chromaRegionRects: [RDPFrameRect]
    ) throws -> CVPixelBuffer {
        guard codecID == RDPGFXCodecID.avc444 || codecID == RDPGFXCodecID.avc444v2 else {
            throw RDPAVC444DecodeError.unsupportedCodec(codecID)
        }
        let key = mainFrameKey(
            surfaceID: surfaceID,
            codecID: codecID,
            destinationRect: destinationRect
        )
        let mainImageBuffer: CVImageBuffer
        let auxiliaryImageBuffer: CVImageBuffer?
        switch layout {
        case .yuv420AndChroma420:
            guard let secondImageBuffer else {
                throw RDPAVC444DecodeError.missingChromaSubframe
            }
            mainImageBuffer = firstImageBuffer
            auxiliaryImageBuffer = secondImageBuffer
        case .yuv420Only:
            mainImageBuffer = firstImageBuffer
            auxiliaryImageBuffer = nil
        case .chroma420Only:
            guard let previousMainFrame = mainFrames[key] else {
                throw RDPAVC444DecodeError.missingLumaSubframe
            }
            mainImageBuffer = previousMainFrame
            auxiliaryImageBuffer = firstImageBuffer
        }

        let width = CVPixelBufferGetWidth(mainImageBuffer)
        let height = CVPixelBufferGetHeight(mainImageBuffer)
        guard width > 0,
              height > 0,
              width.isMultiple(of: 16),
              height.isMultiple(of: 16),
              isNV12(mainImageBuffer),
              auxiliaryImageBuffer.map({ isNV12($0) }) ?? true
        else {
            throw RDPAVC444DecodeError.invalidYUV420Layout
        }
        if let auxiliaryImageBuffer,
           (CVPixelBufferGetWidth(auxiliaryImageBuffer) != width
               || CVPixelBufferGetHeight(auxiliaryImageBuffer) != height)
        {
            throw RDPAVC444DecodeError.mismatchedSubframeDimensions
        }
        if layout != .chroma420Only {
            mainFrames[key] = firstImageBuffer
        }

        let output = try makeOutputPixelBuffer(width: width, height: height)
        let mainTextures = try makeNV12Textures(mainImageBuffer)
        let auxiliaryTextures = try auxiliaryImageBuffer.map(makeNV12Textures) ?? mainTextures
        let outputTexture = try makeTexture(
            output,
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            planeIndex: 0
        )
        let regions = chromaRegionRects.map {
            SIMD4<UInt32>(UInt32($0.left), UInt32($0.top), UInt32($0.right), UInt32($0.bottom))
        }
        let bufferedRegions = regions.isEmpty ? [SIMD4<UInt32>(repeating: 0)] : regions
        let regionBuffer = device.makeBuffer(
            bytes: bufferedRegions,
            length: bufferedRegions.count * MemoryLayout<SIMD4<UInt32>>.stride,
            options: .storageModeShared
        )
        var parameters = Parameters(
            width: UInt32(width),
            height: UInt32(height),
            layout: codecID == RDPGFXCodecID.avc444v2 ? 2 : 1,
            hasAuxiliary: auxiliaryImageBuffer == nil ? 0 : 1,
            regionCount: UInt32(regions.count)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw RDPAVC444MetalDecodeError.commandCreationFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(mainTextures.y.metalTexture, index: 0)
        encoder.setTexture(mainTextures.uv.metalTexture, index: 1)
        encoder.setTexture(auxiliaryTextures.y.metalTexture, index: 2)
        encoder.setTexture(auxiliaryTextures.uv.metalTexture, index: 3)
        encoder.setTexture(outputTexture.metalTexture, index: 4)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.setBuffer(regionBuffer, offset: 0, index: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw RDPAVC444MetalDecodeError.commandFailed(commandBuffer.error.map(String.init(describing:)))
        }
        return output
    }

    private func isNV12(_ imageBuffer: CVImageBuffer) -> Bool {
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        return (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            && CVPixelBufferGetPlaneCount(imageBuffer) == 2
    }

    private func mainFrameKey(
        surfaceID: UInt16,
        codecID: UInt16,
        destinationRect: RDPFrameRect
    ) -> MainFrameKey {
        MainFrameKey(
            surfaceID: surfaceID,
            codecID: codecID,
            left: destinationRect.left,
            top: destinationRect.top,
            right: destinationRect.right,
            bottom: destinationRect.bottom
        )
    }

    private func makeOutputPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RDPAVC444MetalDecodeError.outputCreationFailed(status)
        }
        return pixelBuffer
    }

    private func makeNV12Textures(
        _ imageBuffer: CVImageBuffer
    ) throws -> (y: WrappedTexture, uv: WrappedTexture) {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        return (
            try makeTexture(
                imageBuffer,
                pixelFormat: .r8Unorm,
                width: width,
                height: height,
                planeIndex: 0
            ),
            try makeTexture(
                imageBuffer,
                pixelFormat: .rg8Unorm,
                width: width / 2,
                height: height / 2,
                planeIndex: 1
            )
        )
    }

    private func makeTexture(
        _ imageBuffer: CVImageBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> WrappedTexture {
        guard let textureCache else {
            throw RDPAVC444MetalDecodeError.missingTextureCache
        }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            throw RDPAVC444MetalDecodeError.textureCreationFailed(status)
        }
        return WrappedTexture(coreVideoTexture: cvTexture, metalTexture: texture)
    }
}

enum RDPAVC444MetalDecodeError: Error, CustomStringConvertible {
    case outputCreationFailed(CVReturn)
    case missingTextureCache
    case textureCreationFailed(CVReturn)
    case commandCreationFailed
    case commandFailed(String?)

    var description: String {
        switch self {
        case let .outputCreationFailed(status):
            "Core Video could not create an IOSurface-backed AVC444 output: \(status)."
        case .missingTextureCache:
            "The AVC444 Metal texture cache is unavailable."
        case let .textureCreationFailed(status):
            "Core Video could not wrap an AVC444 IOSurface as a Metal texture: \(status)."
        case .commandCreationFailed:
            "Metal could not create an AVC444 reconstruction command."
        case let .commandFailed(message):
            "Metal AVC444 reconstruction failed\(message.map { ": \($0)" } ?? ".")"
        }
    }
}

private extension RDPAVC444MetalDecoder {
    static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        uint width;
        uint height;
        uint layout;
        uint hasAuxiliary;
        uint regionCount;
    };

    inline int byteValue(float value) {
        return int(round(clamp(value, 0.0f, 1.0f) * 255.0f));
    }

    inline int2 mainChroma(texture2d<float, access::read> uv, uint2 position) {
        float2 value = uv.read(position / 2).rg;
        return int2(byteValue(value.r), byteValue(value.g));
    }

    inline int2 v1Chroma(
        uint2 p,
        texture2d<float, access::read> mainUV,
        texture2d<float, access::read> auxiliaryY,
        texture2d<float, access::read> auxiliaryUV
    ) {
        if ((p.x & 1) == 0 && (p.y & 1) == 0) {
            int2 filtered = mainChroma(mainUV, p);
            int2 right = int2(byteValue(auxiliaryUV.read(p / 2).r), byteValue(auxiliaryUV.read(p / 2).g));
            uint auxiliaryRow = (p.y / 16) * 16 + ((p.y + 1) % 16) / 2;
            int2 below = int2(
                byteValue(auxiliaryY.read(uint2(p.x, auxiliaryRow)).r),
                byteValue(auxiliaryY.read(uint2(p.x, auxiliaryRow + 8)).r)
            );
            int2 belowRight = int2(
                byteValue(auxiliaryY.read(uint2(p.x + 1, auxiliaryRow)).r),
                byteValue(auxiliaryY.read(uint2(p.x + 1, auxiliaryRow + 8)).r)
            );
            int2 recovered = 4 * filtered - right - below - belowRight;
            return int2(
                abs(filtered.x - recovered.x) > 30 ? clamp(recovered.x, 0, 255) : filtered.x,
                abs(filtered.y - recovered.y) > 30 ? clamp(recovered.y, 0, 255) : filtered.y
            );
        }
        if ((p.y & 1) == 0) {
            float2 value = auxiliaryUV.read(p / 2).rg;
            return int2(byteValue(value.r), byteValue(value.g));
        }
        uint auxiliaryRow = (p.y / 16) * 16 + (p.y % 16) / 2;
        return int2(
            byteValue(auxiliaryY.read(uint2(p.x, auxiliaryRow)).r),
            byteValue(auxiliaryY.read(uint2(p.x, auxiliaryRow + 8)).r)
        );
    }

    inline int2 v2PackedChroma(
        uint2 p,
        texture2d<float, access::read> auxiliaryY,
        texture2d<float, access::read> auxiliaryUV
    ) {
        if ((p.x & 1) == 0) {
            uint planeX = p.x / 4;
            uint planeOffset = auxiliaryY.get_width() / 4;
            float2 value = auxiliaryUV.read(uint2(planeX, p.y / 2)).rg;
            float2 alternate = auxiliaryUV.read(uint2(planeOffset + planeX, p.y / 2)).rg;
            return (p.x % 4) == 0
                ? int2(byteValue(value.r), byteValue(alternate.r))
                : int2(byteValue(value.g), byteValue(alternate.g));
        }
        return int2(
            byteValue(auxiliaryY.read(uint2(p.x / 2, p.y)).r),
            byteValue(auxiliaryY.read(uint2(auxiliaryY.get_width() / 2 + p.x / 2, p.y)).r)
        );
    }

    inline int2 v2Chroma(
        uint2 p,
        texture2d<float, access::read> mainUV,
        texture2d<float, access::read> auxiliaryY,
        texture2d<float, access::read> auxiliaryUV
    ) {
        if ((p.x & 1) == 0 && (p.y & 1) == 0) {
            int2 filtered = mainChroma(mainUV, p);
            int2 right = v2PackedChroma(uint2(p.x + 1, p.y), auxiliaryY, auxiliaryUV);
            int2 below = v2PackedChroma(uint2(p.x, p.y + 1), auxiliaryY, auxiliaryUV);
            int2 belowRight = v2PackedChroma(uint2(p.x + 1, p.y + 1), auxiliaryY, auxiliaryUV);
            int2 recovered = 4 * filtered - right - below - belowRight;
            return int2(
                abs(filtered.x - recovered.x) > 30 ? clamp(recovered.x, 0, 255) : filtered.x,
                abs(filtered.y - recovered.y) > 30 ? clamp(recovered.y, 0, 255) : filtered.y
            );
        }
        return v2PackedChroma(p, auxiliaryY, auxiliaryUV);
    }

    kernel void reconstructAVC444(
        texture2d<float, access::read> mainY [[texture(0)]],
        texture2d<float, access::read> mainUV [[texture(1)]],
        texture2d<float, access::read> auxiliaryY [[texture(2)]],
        texture2d<float, access::read> auxiliaryUV [[texture(3)]],
        texture2d<float, access::write> output [[texture(4)]],
        constant Parameters& parameters [[buffer(0)]],
        constant uint4* regions [[buffer(1)]],
        uint2 p [[thread_position_in_grid]]
    ) {
        if (p.x >= parameters.width || p.y >= parameters.height) {
            return;
        }
        bool useAuxiliary = false;
        if (parameters.hasAuxiliary != 0) {
            for (uint index = 0; index < parameters.regionCount; ++index) {
                uint4 rect = regions[index];
                if (p.x >= rect.x && p.y >= rect.y && p.x < rect.z && p.y < rect.w) {
                    useAuxiliary = true;
                    break;
                }
            }
        }
        int y = byteValue(mainY.read(p).r);
        int2 uv = useAuxiliary
            ? (parameters.layout == 2
                ? v2Chroma(p, mainUV, auxiliaryY, auxiliaryUV)
                : v1Chroma(p, mainUV, auxiliaryY, auxiliaryUV))
            : mainChroma(mainUV, p);
        int r = (256 * y + 403 * (uv.y - 128)) >> 8;
        int g = (256 * y - 48 * (uv.x - 128) - 120 * (uv.y - 128)) >> 8;
        int b = (256 * y + 475 * (uv.x - 128)) >> 8;
        output.write(float4(
            float(clamp(r, 0, 255)) / 255.0f,
            float(clamp(g, 0, 255)) / 255.0f,
            float(clamp(b, 0, 255)) / 255.0f,
            1.0f
        ), p);
    }
    """#
}
