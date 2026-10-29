import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class RDPVideoToolboxFrameDecoder {
    private struct SequenceKey: Hashable {
        var surfaceID: UInt16
        var codec: RDPVideoCodec
    }

    private var sequenceDecoders: [SequenceKey: RDPVideoToolboxSequenceDecoder] = [:]
    /// x264 names itself only in the first access unit it encodes, so a surface created later
    /// in the session inherits what an earlier one learned.
    private var sawX264 = false
    private var avc444Decoders: [UInt16: RDPAVC444FrameDecoder] = [:]
    private let bitmapDecoder = RDPBitmapFrameDecoder()
    private lazy var imageContext = CIContext()

    public init() {}

    public func reset() {
        sequenceDecoders.removeAll()
        avc444Decoders.removeAll()
    }

    /// Decodes `frame` into the picture it shows: the top-left `width` x `height` of the
    /// coded picture, which can be larger.
    public func decode(_ frame: RDPGraphicsFrameSnapshot) throws -> CGImage {
        let ciImage = CIImage(cvImageBuffer: try decodeDetailed(frame).imageBuffer)
        let extent = ciImage.extent
        let height = CGFloat(frame.height)
        // Core Image counts rows from the bottom.
        let shown = CGRect(x: extent.minX, y: extent.maxY - height, width: CGFloat(frame.width), height: height)
            .intersection(extent)
        guard let image = imageContext.createCGImage(ciImage, from: shown) else {
            throw RDPVideoDecodeError.imageConversionFailed
        }
        return image
    }

    public func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        discardSurfaces(frame.deletedSurfaceIDs)
        if frame.contentKind == .bitmap {
            return try bitmapDecoder.decodeDetailed(frame)
        }
        if frame.videoCodec == .h264, frame.avc444SubframeLayout != nil {
            return try avc444Decoder(for: frame.surfaceID).decodeDetailed(frame)
        }
        let decoder = sequenceDecoder(for: frame.surfaceID, codec: frame.videoCodec)
        defer { sawX264 = sawX264 || decoder.encodedByX264 }
        return try decoder.decodeDetailed(frame.encodedVideoData)
    }

    var decoderContextCount: Int {
        sequenceDecoders.count + avc444Decoders.count
    }

    func discardSurfaces(_ surfaceIDs: [UInt16]) {
        guard !surfaceIDs.isEmpty else {
            return
        }
        sequenceDecoders = sequenceDecoders.filter { !surfaceIDs.contains($0.key.surfaceID) }
        for surfaceID in surfaceIDs {
            avc444Decoders[surfaceID] = nil
        }
    }

    private func sequenceDecoder(for surfaceID: UInt16, codec: RDPVideoCodec) -> RDPVideoToolboxSequenceDecoder {
        let key = SequenceKey(surfaceID: surfaceID, codec: codec)
        if let decoder = sequenceDecoders[key] {
            return decoder
        }
        let decoder = RDPVideoToolboxSequenceDecoder(codec: codec)
        decoder.encodedByX264 = sawX264
        sequenceDecoders[key] = decoder
        return decoder
    }

    private func avc444Decoder(for surfaceID: UInt16) -> RDPAVC444FrameDecoder {
        if let decoder = avc444Decoders[surfaceID] {
            return decoder
        }
        let decoder = RDPAVC444FrameDecoder()
        avc444Decoders[surfaceID] = decoder
        return decoder
    }
}

public struct RDPVideoToolboxDecodeResult {
    public var imageBuffer: CVImageBuffer
    public var samplePreparationMilliseconds: Double
    public var videoToolboxMilliseconds: Double
    public var imageConversionMilliseconds: Double
    public var decodedPixelFormat: UInt32
    public var usesHardwareAcceleration: Bool?
}

private final class RDPBitmapFrameDecoder {
    func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        guard let bitmapData = frame.decodedBitmapData,
              let bytesPerRow = frame.decodedBitmapBytesPerRow
        else {
            throw RDPBitmapFrameDecodeError.missingBitmapData
        }

        let width = Int(frame.width)
        let height = Int(frame.height)
        guard width > 0,
              height > 0,
              bytesPerRow >= width * 4,
              bitmapData.count >= bytesPerRow * height
        else {
            throw RDPBitmapFrameDecodeError.invalidBitmapLayout
        }

        let start = Date()
        let imageBuffer = try makePixelBuffer(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            data: bitmapData
        )
        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: 0,
            videoToolboxMilliseconds: 0,
            imageConversionMilliseconds: Date().timeIntervalSince(start) * 1000,
            decodedPixelFormat: kCVPixelFormatType_32BGRA,
            usesHardwareAcceleration: nil
        )
    }

    /// Wraps the bitmap bytes without copying; the pixel buffer keeps the backing `NSData` alive.
    private func makePixelBuffer(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        data: Data
    ) throws -> CVPixelBuffer {
        let nsData = data as NSData
        let retainedData = Unmanaged.passRetained(nsData)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            UnsafeMutableRawPointer(mutating: nsData.bytes),
            bytesPerRow,
            { releaseRefCon, _ in
                guard let releaseRefCon else {
                    return
                }
                Unmanaged<NSData>.fromOpaque(releaseRefCon).release()
            },
            retainedData.toOpaque(),
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            retainedData.release()
            return try rdpMakeBGRAPixelBuffer(width: width, height: height, copying: data, bytesPerRow: bytesPerRow)
        }
        return pixelBuffer
    }
}

/// Creates an IOSurface-backed, Metal-compatible BGRA pixel buffer, optionally filled with
/// `height` rows of `width * 4` bytes read from `source` at `bytesPerRow` stride. A `pool`
/// reuses buffers its earlier ones were released into.
func rdpMakeBGRAPixelBuffer(
    width: Int,
    height: Int,
    copying source: Data? = nil,
    bytesPerRow: Int = 0,
    pool: RDPBGRAPixelBufferPool? = nil
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = if let pool {
        try CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool(width: width, height: height), &pixelBuffer)
    } else {
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            rdpVideoPixelBufferAttributes() as CFDictionary,
            &pixelBuffer
        )
    }
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw RDPBitmapFrameDecodeError.coreVideo(operation: "create BGRA pixel buffer", status: status)
    }
    guard let source else {
        return pixelBuffer
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw RDPBitmapFrameDecodeError.missingBaseAddress
    }
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    source.withUnsafeBytes { sourceBuffer in
        guard let sourceBase = sourceBuffer.baseAddress else {
            return
        }
        for row in 0 ..< height {
            memcpy(
                destination.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * bytesPerRow),
                width * 4
            )
        }
    }
    return pixelBuffer
}

/// BGRA pixel buffers of the size last asked for. Creating an IOSurface for every frame
/// costs several times more than filling one; a pool hands back released buffers.
final class RDPBGRAPixelBufferPool {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    fileprivate func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
        if let pool, width == self.width, height == self.height {
            return pool
        }
        var attributes = rdpVideoPixelBufferAttributes(pixelFormat: kCVPixelFormatType_32BGRA)
        attributes[kCVPixelBufferWidthKey] = width
        attributes[kCVPixelBufferHeightKey] = height
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw RDPBitmapFrameDecodeError.coreVideo(operation: "create BGRA pixel buffer pool", status: status)
        }
        self.pool = pool
        self.width = width
        self.height = height
        return pool
    }
}

func rdpVideoPixelBufferAttributes(pixelFormat: OSType? = nil) -> [CFString: Any] {
    var attributes: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    if let pixelFormat {
        attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat
    }
    return attributes
}

/// Decodes one Annex B H.264 or HEVC stream through VideoToolbox, recreating the session
/// whenever the stream carries new parameter sets.
final class RDPVideoToolboxSequenceDecoder {
    private let codec: RDPVideoCodec
    private let preservesCodedSamples: Bool
    private let sequenceParameterSetRewrite: (Data, Bool) -> Data?
    /// Whether the stream named x264 as its encoder, which decides its colours.
    var encodedByX264 = false
    /// SPS and PPS for H.264; VPS, SPS, and PPS for HEVC.
    private var parameterSets: [Data?]
    private var formatDescription: CMVideoFormatDescription?
    private(set) var session: VTDecompressionSession?
    private var usesHardwareAcceleration: Bool?
    private let output = VideoToolboxDecodeOutput()
    /// With `preservesCodedSamples`, the width of the frames the H.264 encoder was given, which
    /// the coded pictures can exceed.
    private(set) var frameWidth: Int?

    /// With `preservesCodedSamples`, output is 8-bit NV12 holding the whole coded picture's
    /// decoded sample values unchanged, as AVC444 reconstruction requires.
    init(
        codec: RDPVideoCodec,
        preservesCodedSamples: Bool = false,
        sequenceParameterSetRewrite: @escaping (Data, Bool) -> Data? = RDPH264SequenceParameterSet.signalingSampleColours
    ) {
        self.codec = codec
        self.preservesCodedSamples = preservesCodedSamples
        self.sequenceParameterSetRewrite = sequenceParameterSetRewrite
        parameterSets = Array(repeating: nil, count: codec == .h264 ? 2 : 3)
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decodeDetailed(_ annexBData: Data) throws -> RDPVideoToolboxDecodeResult {
        let samplePreparationStartedAt = Date()
        let sample = prepareSample(annexBData)
        guard sample.lengthPrefixedData.isEmpty == false else {
            throw RDPVideoDecodeError.emptySample
        }
        let parameterSetsChanged = updateParameterSets(sample.parameterSets)
        if session == nil || parameterSetsChanged {
            // x264 writes its version SEI next to the parameter sets of its first access unit.
            if codec == .h264, !encodedByX264 {
                encodedByX264 = RDPAnnexB.identifiesX264(annexBData)
            }
            try rebuildSession()
        }

        let videoToolboxStartedAt = Date()
        let imageBuffer: CVImageBuffer
        do {
            imageBuffer = try decode(sample.lengthPrefixedData)
        } catch let RDPVideoDecodeError.videoToolbox(_, status) where status == kVTInvalidSessionErr {
            // iOS invalidates decompression sessions while the app is in the background.
            try rebuildSession()
            imageBuffer = try decode(sample.lengthPrefixedData)
        }
        let videoToolboxFinishedAt = Date()

        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: videoToolboxStartedAt.timeIntervalSince(samplePreparationStartedAt) * 1000,
            videoToolboxMilliseconds: videoToolboxFinishedAt.timeIntervalSince(videoToolboxStartedAt) * 1000,
            imageConversionMilliseconds: 0,
            decodedPixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            usesHardwareAcceleration: usesHardwareAcceleration
        )
    }

    private func decode(_ lengthPrefixedData: Data) throws -> CVImageBuffer {
        guard let formatDescription, let session else {
            throw RDPVideoDecodeError.missingParameterSets(codec)
        }
        let sampleBuffer = try makeSampleBuffer(
            formatDescription: formatDescription,
            lengthPrefixedData: lengthPrefixedData
        )
        output.status = noErr
        output.imageBuffer = nil
        defer {
            output.imageBuffer = nil
        }
        try check(
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: nil,
                infoFlagsOut: nil
            ),
            operation: "decode \(codec.displayName) frame"
        )
        try check(output.status, operation: "finish \(codec.displayName) decode")
        guard let imageBuffer = output.imageBuffer else {
            throw RDPVideoDecodeError.missingImageBuffer
        }
        return imageBuffer
    }

    private func prepareSample(_ annexBData: Data) -> (lengthPrefixedData: Data, parameterSets: [Data?]) {
        switch codec {
        case .h264:
            let sample = RDPH264AnnexB.sample(from: annexBData)
            return (sample.lengthPrefixedData, [sample.sequenceParameterSet, sample.pictureParameterSet])
        case .hevc:
            let sample = RDPHEVCAnnexB.sample(from: annexBData)
            return (
                sample.lengthPrefixedData,
                [sample.videoParameterSet, sample.sequenceParameterSet, sample.pictureParameterSet]
            )
        }
    }

    private func updateParameterSets(_ nextParameterSets: [Data?]) -> Bool {
        var changed = false
        for (index, nextParameterSet) in nextParameterSets.enumerated() {
            if let nextParameterSet, nextParameterSet != parameterSets[index] {
                parameterSets[index] = nextParameterSet
                changed = true
            }
        }
        return changed
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        usesHardwareAcceleration = nil
    }

    private func rebuildSession() throws {
        var parameterSets = parameterSets.compactMap { $0 }
        guard parameterSets.count == self.parameterSets.count else {
            throw RDPVideoDecodeError.missingParameterSets(codec)
        }
        invalidateSession()
        if codec == .h264, preservesCodedSamples {
            // AVC444 views are laid out on the coded picture's macroblocks (MS-RDPEGFX 3.3.8.3.2),
            // which a cropped picture cuts short.
            frameWidth = RDPH264SequenceParameterSet.croppedWidth(parameterSets[0])
            parameterSets[0] = RDPH264SequenceParameterSet.removingFrameCropping(parameterSets[0]) ?? parameterSets[0]
        }
        let formatDescription: CMVideoFormatDescription
        // The SPS states the colours the samples hold (see signalingSampleColours). If CoreMedia
        // rejects the rewritten SPS, the original still decodes, only with the signalled range.
        if codec == .h264,
           let sequenceParameterSet = sequenceParameterSetRewrite(parameterSets[0], encodedByX264),
           let signalledFormatDescription = try? makeFormatDescription(
               parameterSets: [sequenceParameterSet] + parameterSets.dropFirst()
           )
        {
            formatDescription = signalledFormatDescription
        } else {
            formatDescription = try makeFormatDescription(parameterSets: parameterSets)
        }
        self.formatDescription = formatDescription

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard let refCon else {
                    return
                }
                let output = Unmanaged<VideoToolboxDecodeOutput>.fromOpaque(refCon).takeUnretainedValue()
                output.status = status
                output.imageBuffer = imageBuffer
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque()
        )
        var session: VTDecompressionSession?
        try check(
            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: [
                    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                ] as CFDictionary,
                imageBufferAttributes: rdpVideoPixelBufferAttributes(
                    pixelFormat: outputPixelFormat(for: formatDescription)
                ) as CFDictionary,
                outputCallback: &callback,
                decompressionSessionOut: &session
            ),
            operation: "create \(codec.displayName) decompression session"
        )
        guard let session else {
            throw RDPVideoDecodeError.missingOutput("\(codec.displayName) decompression session")
        }
        self.session = session
        // A latency hint only; decoders that do not support it still decode correctly.
        _ = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var hardwareAcceleration: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hardwareAcceleration
        )
        let usesHardwareAcceleration = hardwareAcceleration?.takeRetainedValue()
        self.usesHardwareAcceleration = status == noErr ? usesHardwareAcceleration as? Bool : nil
    }

    private func outputPixelFormat(for formatDescription: CMVideoFormatDescription) -> OSType? {
        guard preservesCodedSamples else {
            return nil
        }
        // Requesting the other range makes VideoToolbox rescale every sample.
        let signalsFullRange = CMFormatDescriptionGetExtension(
            formatDescription,
            extensionKey: kCMFormatDescriptionExtension_FullRangeVideo
        ) as? Bool == true
        return signalsFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private func makeFormatDescription(parameterSets: [Data]) throws -> CMVideoFormatDescription {
        let joinedParameterSets = parameterSets.reduce(into: Data()) { $0.append($1) }
        var formatDescription: CMVideoFormatDescription?
        let status = joinedParameterSets.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            var offset = 0
            var pointers = parameterSets.map { parameterSet -> UnsafePointer<UInt8> in
                defer { offset += parameterSet.count }
                return base.advanced(by: offset)
            }
            var sizes = parameterSets.map(\.count)
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        try check(status, operation: "create \(codec.displayName) format description")
        guard let formatDescription else {
            throw RDPVideoDecodeError.missingOutput("\(codec.displayName) format description")
        }
        return formatDescription
    }

    private func makeSampleBuffer(
        formatDescription: CMVideoFormatDescription,
        lengthPrefixedData: Data
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        try check(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: lengthPrefixedData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: lengthPrefixedData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            operation: "create block buffer"
        )
        guard let blockBuffer else {
            throw RDPVideoDecodeError.missingOutput("block buffer")
        }
        try lengthPrefixedData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw RDPVideoDecodeError.emptySample
            }
            try check(
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: lengthPrefixedData.count
                ),
                operation: "copy sample bytes"
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = lengthPrefixedData.count
        try check(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            operation: "create sample buffer"
        )
        guard let sampleBuffer else {
            throw RDPVideoDecodeError.missingOutput("sample buffer")
        }
        return sampleBuffer
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RDPVideoDecodeError.videoToolbox(operation: operation, status: status)
        }
    }
}

/// Receives VideoToolbox output. Decoding is synchronous, so the callback runs before
/// `VTDecompressionSessionDecodeFrame` returns.
private final class VideoToolboxDecodeOutput {
    var status: OSStatus = noErr
    var imageBuffer: CVImageBuffer?
}

public enum RDPVideoDecodeError: Error, Equatable, CustomStringConvertible {
    case emptySample
    case missingParameterSets(RDPVideoCodec)
    case missingOutput(String)
    case missingImageBuffer
    case imageConversionFailed
    case videoToolbox(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .emptySample:
            "The video sample contained no NAL units."
        case let .missingParameterSets(codec):
            codec == .h264
                ? "H.264 stream did not include SPS and PPS NAL units."
                : "HEVC stream did not include VPS, SPS, and PPS NAL units."
        case let .missingOutput(output):
            "Core Media did not return a \(output)."
        case .missingImageBuffer:
            "VideoToolbox did not produce an image buffer."
        case .imageConversionFailed:
            "Core Image could not convert the decoded frame."
        case let .videoToolbox(operation, status):
            "\(operation) failed with OSStatus \(status)."
        }
    }
}

public enum RDPBitmapFrameDecodeError: Error, Equatable, CustomStringConvertible {
    case missingBitmapData
    case invalidBitmapLayout
    case missingBaseAddress
    case coreVideo(operation: String, status: CVReturn)

    public var description: String {
        switch self {
        case .missingBitmapData:
            "Decoded bitmap frame is missing BGRA data."
        case .invalidBitmapLayout:
            "Decoded bitmap frame has an invalid layout."
        case .missingBaseAddress:
            "Core Video did not expose the bitmap pixel buffer base address."
        case let .coreVideo(operation, status):
            "Core Video failed to \(operation): \(status)."
        }
    }
}
