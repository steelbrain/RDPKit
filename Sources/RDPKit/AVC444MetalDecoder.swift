import CoreVideo
import Foundation
import Metal

/// Reconstructs AVC444 frames on the GPU with the same math as `rdpReconstructAVC444OnCPU`.
final class RDPAVC444MetalDecoder {
    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var layout: UInt32
        var hasAuxiliary: UInt32
        var regionCount: UInt32
    }

    private let context: RDPAVC444MetalContext
    private let textureCache: CVMetalTextureCache

    /// Returns nil when the device has no usable Metal support.
    init?() {
        guard let context = RDPAVC444MetalContext.shared else {
            return nil
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache
        else {
            return nil
        }
        self.context = context
        self.textureCache = textureCache
    }

    func reconstruct(
        main: CVPixelBuffer,
        auxiliary: CVPixelBuffer?,
        usesV2Layout: Bool,
        chromaRegionRects: [RDPFrameRect]
    ) throws -> CVPixelBuffer {
        let (width, height) = try rdpAVC444FrameSize(main: main, auxiliary: auxiliary)
        defer {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        let output = try rdpMakeBGRAPixelBuffer(width: width, height: height)
        // The CVMetalTexture wrappers must outlive the GPU work that reads their IOSurfaces.
        let mainTextures = try makeNV12Textures(main)
        let auxiliaryTextures = try auxiliary.map(makeNV12Textures) ?? mainTextures
        let outputTexture = try makeTexture(output, pixelFormat: .bgra8Unorm, planeIndex: 0)
        var regions = chromaRegionRects.map {
            SIMD4<UInt32>(UInt32($0.left), UInt32($0.top), UInt32($0.right), UInt32($0.bottom))
        }
        var parameters = Parameters(
            width: UInt32(width),
            height: UInt32(height),
            layout: usesV2Layout ? 2 : 1,
            hasAuxiliary: auxiliary == nil ? 0 : 1,
            regionCount: UInt32(regions.count)
        )
        if regions.isEmpty {
            regions = [SIMD4<UInt32>(repeating: 0)]
        }

        guard let regionBuffer = context.device.makeBuffer(
            bytes: regions,
            length: regions.count * MemoryLayout<SIMD4<UInt32>>.stride,
            options: .storageModeShared
        ),
            let commandBuffer = context.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw RDPAVC444MetalDecodeError.commandCreationFailed
        }
        let pipeline = context.pipeline
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

    private func makeNV12Textures(_ imageBuffer: CVPixelBuffer) throws -> (y: RDPMetalTexture, uv: RDPMetalTexture) {
        (
            try makeTexture(imageBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
            try makeTexture(imageBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
        )
    }

    private func makeTexture(
        _ imageBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int
    ) throws -> RDPMetalTexture {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            pixelFormat,
            CVPixelBufferGetWidthOfPlane(imageBuffer, planeIndex),
            CVPixelBufferGetHeightOfPlane(imageBuffer, planeIndex),
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            throw RDPAVC444MetalDecodeError.textureCreationFailed(status)
        }
        return RDPMetalTexture(coreVideoTexture: cvTexture, metalTexture: texture)
    }
}

private struct RDPMetalTexture {
    var coreVideoTexture: CVMetalTexture
    var metalTexture: MTLTexture
}

/// The device, queue, and compiled pipeline, created once per process. Metal devices,
/// command queues, and pipeline states are thread-safe.
private final class RDPAVC444MetalContext: @unchecked Sendable {
    static let shared = RDPAVC444MetalContext()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: RDPAVC444MetalDecoder.shaderSource, options: nil),
              let function = library.makeFunction(name: "reconstructAVC444"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }
}

enum RDPAVC444MetalDecodeError: Error, CustomStringConvertible {
    case textureCreationFailed(CVReturn)
    case commandCreationFailed
    case commandFailed(String?)

    var description: String {
        switch self {
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

    inline int2 reverseFiltered(int2 filtered, int2 recovered) {
        int2 reversed = clamp(recovered, 0, 255);
        return int2(
            abs(reversed.x - filtered.x) < 30 ? filtered.x : reversed.x,
            abs(reversed.y - filtered.y) < 30 ? filtered.y : reversed.y
        );
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
            return reverseFiltered(filtered, 4 * filtered - right - below - belowRight);
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
            return reverseFiltered(filtered, 4 * filtered - right - below - belowRight);
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
