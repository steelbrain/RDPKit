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
    private var avc444Decoders: [UInt16: RDPAVC444FrameDecoder] = [:]
    private let bitmapDecoder = RDPBitmapFrameDecoder()
    private lazy var imageContext = CIContext()

    public init() {}

    public func reset() {
        sequenceDecoders.removeAll()
        avc444Decoders.removeAll()
    }

    func reset(surfaceID: UInt16) {
        sequenceDecoders = sequenceDecoders.filter { $0.key.surfaceID != surfaceID }
        avc444Decoders[surfaceID] = nil
    }

    public func decode(_ frame: RDPGraphicsFrameSnapshot) throws -> CGImage {
        let ciImage = CIImage(cvImageBuffer: try decodeDetailed(frame).imageBuffer)
        guard let image = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw RDPVideoDecodeError.imageConversionFailed
        }
        return image
    }

    public func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        if frame.contentKind == .bitmap {
            return try bitmapDecoder.decodeDetailed(frame)
        }
        if frame.videoCodec == .h264, frame.avc444SubframeLayout != nil {
            return try avc444Decoder(for: frame.surfaceID).decodeDetailed(frame)
        }
        return try sequenceDecoder(for: frame.surfaceID, codec: frame.videoCodec).decodeDetailed(frame.encodedVideoData)
    }

    var decoderContextCount: Int {
        sequenceDecoders.count + avc444Decoders.count
    }

    private func sequenceDecoder(for surfaceID: UInt16, codec: RDPVideoCodec) -> RDPVideoToolboxSequenceDecoder {
        let key = SequenceKey(surfaceID: surfaceID, codec: codec)
        if let decoder = sequenceDecoders[key] {
            return decoder
        }
        let decoder = RDPVideoToolboxSequenceDecoder(codec: codec)
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
/// `height` rows of `width * 4` bytes read from `source` at `bytesPerRow` stride.
func rdpMakeBGRAPixelBuffer(
    width: Int,
    height: Int,
    copying source: Data? = nil,
    bytesPerRow: Int = 0
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        rdpVideoPixelBufferAttributes() as CFDictionary,
        &pixelBuffer
    )
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

public enum RDPH264DecodedFrameImage {
    public static func cropToDestinationRect(
        _ image: CGImage,
        frame: RDPGraphicsFrameSnapshot
    ) throws -> CGImage {
        let destinationWidth = Int(frame.width)
        let destinationHeight = Int(frame.height)
        guard destinationWidth > 0,
              destinationHeight > 0
        else {
            return image
        }
        guard image.width != destinationWidth || image.height != destinationHeight else {
            return image
        }
        guard image.width >= destinationWidth,
              image.height >= destinationHeight
        else {
            return image
        }
        guard let croppedImage = image.cropping(
            to: CGRect(
                x: 0,
                y: 0,
                width: destinationWidth,
                height: destinationHeight
            )
        ) else {
            throw RDPVideoDecodeError.imageCropFailed(
                sourceWidth: image.width,
                sourceHeight: image.height,
                destinationWidth: destinationWidth,
                destinationHeight: destinationHeight
            )
        }
        return croppedImage
    }
}

/// Decodes one Annex B H.264 or HEVC stream through VideoToolbox, recreating the session
/// whenever the stream carries new parameter sets.
final class RDPVideoToolboxSequenceDecoder {
    private let codec: RDPVideoCodec
    private let preservesCodedSamples: Bool
    /// SPS and PPS for H.264; VPS, SPS, and PPS for HEVC.
    private var parameterSets: [Data?]
    private var formatDescription: CMVideoFormatDescription?
    private(set) var session: VTDecompressionSession?
    private var usesHardwareAcceleration: Bool?
    private let output = VideoToolboxDecodeOutput()

    /// With `preservesCodedSamples`, output is 8-bit NV12 holding the decoded sample values
    /// unchanged, as AVC444 reconstruction requires.
    init(codec: RDPVideoCodec, preservesCodedSamples: Bool = false) {
        self.codec = codec
        self.preservesCodedSamples = preservesCodedSamples
        parameterSets = Array(repeating: nil, count: codec == .h264 ? 2 : 3)
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func reset() {
        invalidateSession()
        parameterSets = Array(repeating: nil, count: parameterSets.count)
        formatDescription = nil
    }

    func decodeDetailed(_ annexBData: Data) throws -> RDPVideoToolboxDecodeResult {
        let samplePreparationStartedAt = Date()
        let sample = prepareSample(annexBData)
        guard sample.lengthPrefixedData.isEmpty == false else {
            throw RDPVideoDecodeError.emptySample
        }
        let parameterSetsChanged = updateParameterSets(sample.parameterSets)
        if session == nil || parameterSetsChanged {
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
        let parameterSets = parameterSets.compactMap { $0 }
        guard parameterSets.count == self.parameterSets.count else {
            throw RDPVideoDecodeError.missingParameterSets(codec)
        }
        invalidateSession()
        let formatDescription = try makeFormatDescription(parameterSets: parameterSets)
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
        // Requesting the other range makes VideoToolbox rescale every sample. GNOME Remote
        // Desktop and KRdp signal limited range in the SPS VUI although MS-RDPEGFX 3.3.8.3.1
        // defines the samples as full-range BT.709, so match the signalled range and let the
        // AVC444 conversion interpret the raw values.
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
    case imageCropFailed(sourceWidth: Int, sourceHeight: Int, destinationWidth: Int, destinationHeight: Int)
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
        case let .imageCropFailed(sourceWidth, sourceHeight, destinationWidth, destinationHeight):
            "CoreGraphics could not crop decoded frame from \(sourceWidth)x\(sourceHeight) to \(destinationWidth)x\(destinationHeight)."
        case let .videoToolbox(operation, status):
            "\(operation) failed with OSStatus \(status)."
        }
    }
}

public enum RDPBitmapFrameDecodeError: Error, Equatable, CustomStringConvertible {
    case missingBitmapData
    case invalidBitmapLayout
    case missingPixelBuffer
    case missingBaseAddress
    case coreVideo(operation: String, status: CVReturn)

    public var description: String {
        switch self {
        case .missingBitmapData:
            "Decoded bitmap frame is missing BGRA data."
        case .invalidBitmapLayout:
            "Decoded bitmap frame has an invalid layout."
        case .missingPixelBuffer:
            "Core Video did not return a bitmap pixel buffer."
        case .missingBaseAddress:
            "Core Video did not expose the bitmap pixel buffer base address."
        case let .coreVideo(operation, status):
            "Core Video failed to \(operation): \(status)."
        }
    }
}
