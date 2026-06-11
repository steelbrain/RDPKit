import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct RDPH264FirstFrameDecoder {
    public init() {}

    public func decode(_ annexBData: Data) throws -> CGImage {
        try RDPH264FrameSequenceDecoder().decode(annexBData)
    }
}

public final class RDPVideoToolboxFrameDecoder {
    private let h264Decoder = RDPH264FrameSequenceDecoder()
    private let hevcDecoder = RDPHEVCFrameSequenceDecoder()
    private let imageConverter = RDPVideoToolboxCGImageConverter()

    public init() {}

    public func decode(_ frame: RDPGraphicsFrameSnapshot) throws -> CGImage {
        try imageConverter.makeImage(from: decodeDetailed(frame).imageBuffer)
    }

    public func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        switch frame.videoCodec {
        case .h264:
            try h264Decoder.decodeDetailed(frame.encodedVideoData)
        case .hevc:
            try hevcDecoder.decodeDetailed(frame.encodedVideoData)
        }
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

private func makeVideoDecoderSpecification() -> CFDictionary {
    [
        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
    ] as CFDictionary
}

private func makeVideoDecoderImageBufferAttributes() -> CFDictionary {
    [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
    ] as CFDictionary
}

private func copyHardwareAccelerationState(from session: VTDecompressionSession) -> Bool? {
    var unmanagedValue: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(
        session,
        key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        allocator: kCFAllocatorDefault,
        valueOut: &unmanagedValue
    )
    let value = unmanagedValue?.takeRetainedValue()
    guard status == noErr,
          let value,
          CFGetTypeID(value) == CFBooleanGetTypeID()
    else {
        return nil
    }
    return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
}

private func setRealtimeDecodeIfSupported(_ session: VTDecompressionSession) -> OSStatus {
    let status = VTSessionSetProperty(
        session,
        key: kVTDecompressionPropertyKey_RealTime,
        value: kCFBooleanTrue
    )
    guard status != kVTPropertyNotSupportedErr else {
        return noErr
    }
    return status
}

private final class RDPVideoToolboxCGImageConverter {
    private let ciContext = CIContext()

    func makeImage(from imageBuffer: CVImageBuffer) throws -> CGImage {
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let image = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw RDPVideoToolboxImageConversionError.imageConversionFailed
        }
        return image
    }
}

private enum RDPVideoToolboxImageConversionError: Error, CustomStringConvertible {
    case imageConversionFailed

    var description: String {
        switch self {
        case .imageConversionFailed:
            "Core Image could not convert the decoded video buffer to a CGImage."
        }
    }
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
            throw RDPH264FirstFrameDecodeError.imageCropFailed(
                sourceWidth: image.width,
                sourceHeight: image.height,
                destinationWidth: destinationWidth,
                destinationHeight: destinationHeight
            )
        }
        return croppedImage
    }
}

public final class RDPH264FrameSequenceDecoder {
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var usesHardwareAcceleration: Bool?
    private let output = VideoToolboxDecodeOutput()
    private let imageConverter = RDPVideoToolboxCGImageConverter()

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    public init() {}

    public func decode(_ annexBData: Data) throws -> CGImage {
        try imageConverter.makeImage(from: decodeDetailed(annexBData).imageBuffer)
    }

    public func decodeDetailed(_ annexBData: Data) throws -> RDPVideoToolboxDecodeResult {
        let samplePreparationStartedAt = Date()
        let preparedSample = RDPH264AnnexB.sample(from: annexBData)
        guard preparedSample.isEmpty == false else {
            throw RDPH264FirstFrameDecodeError.emptySample
        }

        let parameterSetsChanged = updateParameterSets(from: preparedSample)
        if session == nil || parameterSetsChanged {
            try rebuildSession()
        }

        guard let formatDescription,
              let session
        else {
            throw RDPH264FirstFrameDecodeError.missingParameterSets
        }

        let sampleBuffer = try makeSampleBuffer(
            formatDescription: formatDescription,
            lengthPrefixedData: preparedSample.lengthPrefixedData
        )
        let samplePreparedAt = Date()

        output.status = noErr
        output.imageBuffer = nil
        defer {
            output.imageBuffer = nil
        }
        let videoToolboxStartedAt = Date()
        try check(
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: nil,
                infoFlagsOut: nil
            ),
            operation: "decode H.264 frame"
        )
        let videoToolboxFinishedAt = Date()
        try check(output.status, operation: "finish H.264 decode")

        guard let imageBuffer = output.imageBuffer else {
            throw RDPH264FirstFrameDecodeError.missingImageBuffer
        }

        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: samplePreparedAt.timeIntervalSince(samplePreparationStartedAt) * 1000,
            videoToolboxMilliseconds: videoToolboxFinishedAt.timeIntervalSince(videoToolboxStartedAt) * 1000,
            imageConversionMilliseconds: 0,
            decodedPixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            usesHardwareAcceleration: usesHardwareAcceleration
        )
    }

    private func updateParameterSets(from sample: RDPH264AnnexBSample) -> Bool {
        var changed = false
        if let nextSequenceParameterSet = sample.sequenceParameterSet,
           nextSequenceParameterSet != sequenceParameterSet
        {
            sequenceParameterSet = nextSequenceParameterSet
            changed = true
        }
        if let nextPictureParameterSet = sample.pictureParameterSet,
           nextPictureParameterSet != pictureParameterSet
        {
            pictureParameterSet = nextPictureParameterSet
            changed = true
        }
        return changed
    }

    private func rebuildSession() throws {
        guard let sequenceParameterSet,
              let pictureParameterSet
        else {
            throw RDPH264FirstFrameDecodeError.missingParameterSets
        }

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            usesHardwareAcceleration = nil
        }

        let formatDescription = try makeFormatDescription(
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet
        )
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

        try check(
            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: makeVideoDecoderSpecification(),
                imageBufferAttributes: makeVideoDecoderImageBufferAttributes(),
                outputCallback: &callback,
                decompressionSessionOut: &session
            ),
            operation: "create VideoToolbox session"
        )

        guard let session else {
            throw RDPH264FirstFrameDecodeError.missingDecompressionSession
        }
        try check(
            setRealtimeDecodeIfSupported(session),
            operation: "configure H.264 realtime decode"
        )
        usesHardwareAcceleration = copyHardwareAccelerationState(from: session)
    }

    private func makeFormatDescription(
        sequenceParameterSet: Data,
        pictureParameterSet: Data
    ) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?

        try sequenceParameterSet.withUnsafeBytes { spsBuffer in
            try pictureParameterSet.withUnsafeBytes { ppsBuffer in
                guard let sps = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    throw RDPH264FirstFrameDecodeError.invalidParameterSets
                }

                var parameterSetPointers = [sps, pps]
                var parameterSetSizes = [sequenceParameterSet.count, pictureParameterSet.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
                try check(status, operation: "create H.264 format description")
            }
        }

        guard let formatDescription else {
            throw RDPH264FirstFrameDecodeError.missingFormatDescription
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
            operation: "create H.264 block buffer"
        )

        guard let blockBuffer else {
            throw RDPH264FirstFrameDecodeError.missingBlockBuffer
        }

        try lengthPrefixedData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw RDPH264FirstFrameDecodeError.emptySample
            }
            try check(
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: lengthPrefixedData.count
                ),
                operation: "copy H.264 sample bytes"
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
            operation: "create H.264 sample buffer"
        )

        guard let sampleBuffer else {
            throw RDPH264FirstFrameDecodeError.missingSampleBuffer
        }
        return sampleBuffer
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RDPH264FirstFrameDecodeError.videoToolbox(operation: operation, status: status)
        }
    }
}

public final class RDPHEVCFrameSequenceDecoder {
    private var videoParameterSet: Data?
    private var sequenceParameterSet: Data?
    private var pictureParameterSet: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var usesHardwareAcceleration: Bool?
    private let output = VideoToolboxDecodeOutput()
    private let imageConverter = RDPVideoToolboxCGImageConverter()

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    public init() {}

    public func decode(_ annexBData: Data) throws -> CGImage {
        try imageConverter.makeImage(from: decodeDetailed(annexBData).imageBuffer)
    }

    public func decodeDetailed(_ annexBData: Data) throws -> RDPVideoToolboxDecodeResult {
        let samplePreparationStartedAt = Date()
        let preparedSample = RDPHEVCAnnexB.sample(from: annexBData)
        guard preparedSample.isEmpty == false else {
            throw RDPHEVCFrameDecodeError.emptySample
        }

        let parameterSetsChanged = updateParameterSets(from: preparedSample)
        if session == nil || parameterSetsChanged {
            try rebuildSession()
        }

        guard let formatDescription,
              let session
        else {
            throw RDPHEVCFrameDecodeError.missingParameterSets
        }

        let sampleBuffer = try makeSampleBuffer(
            formatDescription: formatDescription,
            lengthPrefixedData: preparedSample.lengthPrefixedData
        )
        let samplePreparedAt = Date()

        output.status = noErr
        output.imageBuffer = nil
        defer {
            output.imageBuffer = nil
        }
        let videoToolboxStartedAt = Date()
        try check(
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: nil,
                infoFlagsOut: nil
            ),
            operation: "decode HEVC frame"
        )
        let videoToolboxFinishedAt = Date()
        try check(output.status, operation: "finish HEVC decode")

        guard let imageBuffer = output.imageBuffer else {
            throw RDPHEVCFrameDecodeError.missingImageBuffer
        }

        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: samplePreparedAt.timeIntervalSince(samplePreparationStartedAt) * 1000,
            videoToolboxMilliseconds: videoToolboxFinishedAt.timeIntervalSince(videoToolboxStartedAt) * 1000,
            imageConversionMilliseconds: 0,
            decodedPixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            usesHardwareAcceleration: usesHardwareAcceleration
        )
    }

    private func updateParameterSets(from sample: RDPHEVCAnnexBSample) -> Bool {
        var changed = false
        if let nextVideoParameterSet = sample.videoParameterSet,
           nextVideoParameterSet != videoParameterSet
        {
            videoParameterSet = nextVideoParameterSet
            changed = true
        }
        if let nextSequenceParameterSet = sample.sequenceParameterSet,
           nextSequenceParameterSet != sequenceParameterSet
        {
            sequenceParameterSet = nextSequenceParameterSet
            changed = true
        }
        if let nextPictureParameterSet = sample.pictureParameterSet,
           nextPictureParameterSet != pictureParameterSet
        {
            pictureParameterSet = nextPictureParameterSet
            changed = true
        }
        return changed
    }

    private func rebuildSession() throws {
        guard let videoParameterSet,
              let sequenceParameterSet,
              let pictureParameterSet
        else {
            throw RDPHEVCFrameDecodeError.missingParameterSets
        }

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            usesHardwareAcceleration = nil
        }

        let formatDescription = try makeFormatDescription(
            videoParameterSet: videoParameterSet,
            sequenceParameterSet: sequenceParameterSet,
            pictureParameterSet: pictureParameterSet
        )
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

        try check(
            VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: makeVideoDecoderSpecification(),
                imageBufferAttributes: makeVideoDecoderImageBufferAttributes(),
                outputCallback: &callback,
                decompressionSessionOut: &session
            ),
            operation: "create HEVC VideoToolbox session"
        )

        guard let session else {
            throw RDPHEVCFrameDecodeError.missingDecompressionSession
        }
        try check(
            setRealtimeDecodeIfSupported(session),
            operation: "configure HEVC realtime decode"
        )
        usesHardwareAcceleration = copyHardwareAccelerationState(from: session)
    }

    private func makeFormatDescription(
        videoParameterSet: Data,
        sequenceParameterSet: Data,
        pictureParameterSet: Data
    ) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?

        try videoParameterSet.withUnsafeBytes { vpsBuffer in
            try sequenceParameterSet.withUnsafeBytes { spsBuffer in
                try pictureParameterSet.withUnsafeBytes { ppsBuffer in
                    guard let vps = vpsBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let sps = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let pps = ppsBuffer.bindMemory(to: UInt8.self).baseAddress
                    else {
                        throw RDPHEVCFrameDecodeError.invalidParameterSets
                    }

                    var parameterSetPointers = [vps, sps, pps]
                    var parameterSetSizes = [
                        videoParameterSet.count,
                        sequenceParameterSet.count,
                        pictureParameterSet.count,
                    ]
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSetPointers.count,
                        parameterSetPointers: &parameterSetPointers,
                        parameterSetSizes: &parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )
                    try check(status, operation: "create HEVC format description")
                }
            }
        }

        guard let formatDescription else {
            throw RDPHEVCFrameDecodeError.missingFormatDescription
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
            operation: "create HEVC block buffer"
        )

        guard let blockBuffer else {
            throw RDPHEVCFrameDecodeError.missingBlockBuffer
        }

        try lengthPrefixedData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw RDPHEVCFrameDecodeError.emptySample
            }
            try check(
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: lengthPrefixedData.count
                ),
                operation: "copy HEVC sample bytes"
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
            operation: "create HEVC sample buffer"
        )

        guard let sampleBuffer else {
            throw RDPHEVCFrameDecodeError.missingSampleBuffer
        }
        return sampleBuffer
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RDPHEVCFrameDecodeError.videoToolbox(operation: operation, status: status)
        }
    }
}

private final class VideoToolboxDecodeOutput {
    var status: OSStatus = noErr
    var imageBuffer: CVImageBuffer?
}

public enum RDPH264FirstFrameDecodeError: Error, CustomStringConvertible {
    case missingParameterSets
    case invalidParameterSets
    case missingFormatDescription
    case missingBlockBuffer
    case missingSampleBuffer
    case missingDecompressionSession
    case missingImageBuffer
    case emptySample
    case imageConversionFailed
    case imageCropFailed(sourceWidth: Int, sourceHeight: Int, destinationWidth: Int, destinationHeight: Int)
    case videoToolbox(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .missingParameterSets:
            "H.264 stream did not include SPS and PPS NAL units."
        case .invalidParameterSets:
            "H.264 parameter set bytes were invalid."
        case .missingFormatDescription:
            "CoreMedia did not return an H.264 format description."
        case .missingBlockBuffer:
            "CoreMedia did not return a block buffer."
        case .missingSampleBuffer:
            "CoreMedia did not return a sample buffer."
        case .missingDecompressionSession:
            "VideoToolbox did not return a decompression session."
        case .missingImageBuffer:
            "VideoToolbox did not produce an image buffer."
        case .emptySample:
            "H.264 sample was empty."
        case .imageConversionFailed:
            "CoreImage could not convert the decoded frame."
        case let .imageCropFailed(sourceWidth, sourceHeight, destinationWidth, destinationHeight):
            "CoreGraphics could not crop decoded frame from \(sourceWidth)x\(sourceHeight) to \(destinationWidth)x\(destinationHeight)."
        case let .videoToolbox(operation, status):
            "\(operation) failed with OSStatus \(status)."
        }
    }
}

public enum RDPHEVCFrameDecodeError: Error, CustomStringConvertible {
    case missingParameterSets
    case invalidParameterSets
    case missingFormatDescription
    case missingBlockBuffer
    case missingSampleBuffer
    case missingDecompressionSession
    case missingImageBuffer
    case emptySample
    case imageConversionFailed
    case videoToolbox(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .missingParameterSets:
            "HEVC stream did not include VPS, SPS, and PPS NAL units."
        case .invalidParameterSets:
            "HEVC parameter set bytes were invalid."
        case .missingFormatDescription:
            "CoreMedia did not return an HEVC format description."
        case .missingBlockBuffer:
            "CoreMedia did not return a block buffer."
        case .missingSampleBuffer:
            "CoreMedia did not return a sample buffer."
        case .missingDecompressionSession:
            "VideoToolbox did not return a decompression session."
        case .missingImageBuffer:
            "VideoToolbox did not produce an image buffer."
        case .emptySample:
            "HEVC sample was empty."
        case .imageConversionFailed:
            "CoreImage could not convert the decoded frame."
        case let .videoToolbox(operation, status):
            "\(operation) failed with OSStatus \(status)."
        }
    }
}
