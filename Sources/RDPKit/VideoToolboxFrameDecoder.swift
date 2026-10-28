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

private final class RDPAVC444FrameDecoder {
    private struct MainFrameKey: Hashable {
        var codecID: UInt16
        var left: UInt16
        var top: UInt16
        var right: UInt16
        var bottom: UInt16
    }

    private let h264Decoder = RDPVideoToolboxSequenceDecoder(codec: .h264, preservesCodedSamples: true)
    private let frameStore = RDPAVC444FrameStore()
    private var metalDecoder: RDPAVC444MetalDecoder?
    private var didAttemptMetalDecoderCreation = false
    private var mainImageBuffers: [MainFrameKey: CVImageBuffer] = [:]

    func reset() {
        h264Decoder.reset()
        frameStore.reset()
        metalDecoder?.reset()
        mainImageBuffers.removeAll()
    }

    func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        guard let layout = frame.avc444SubframeLayout else {
            throw RDPAVC444DecodeError.missingLumaSubframe
        }

        let firstResult = try h264Decoder.decodeDetailed(frame.encodedVideoData)
        var samplePreparationMilliseconds = firstResult.samplePreparationMilliseconds
        var videoToolboxMilliseconds = firstResult.videoToolboxMilliseconds
        var usesHardwareAcceleration = firstResult.usesHardwareAcceleration
        var secondResult: RDPVideoToolboxDecodeResult?
        if let auxiliaryEncodedVideoData = frame.auxiliaryEncodedVideoData {
            let decoded = try h264Decoder.decodeDetailed(auxiliaryEncodedVideoData)
            secondResult = decoded
            samplePreparationMilliseconds += decoded.samplePreparationMilliseconds
            videoToolboxMilliseconds += decoded.videoToolboxMilliseconds
            usesHardwareAcceleration = usesHardwareAcceleration ?? decoded.usesHardwareAcceleration
        }

        let conversionStartedAt = Date()
        let chromaRegionRects: [RDPFrameRect] = switch layout {
        case .yuv420AndChroma420:
            sourceRegionRects(frame.auxiliaryRegionRects, destinationRect: frame.destinationRect)
        case .chroma420Only:
            sourceRegionRects(frame.regionRects, destinationRect: frame.destinationRect)
        case .yuv420Only:
            []
        }
        let mainFrameKey = MainFrameKey(
            codecID: frame.codecID,
            left: frame.destinationRect.left,
            top: frame.destinationRect.top,
            right: frame.destinationRect.right,
            bottom: frame.destinationRect.bottom
        )
        if layout != .chroma420Only {
            mainImageBuffers[mainFrameKey] = firstResult.imageBuffer
        }
        if layout == .yuv420Only {
            return RDPVideoToolboxDecodeResult(
                imageBuffer: firstResult.imageBuffer,
                samplePreparationMilliseconds: samplePreparationMilliseconds,
                videoToolboxMilliseconds: videoToolboxMilliseconds,
                imageConversionMilliseconds: 0,
                decodedPixelFormat: firstResult.decodedPixelFormat,
                usesHardwareAcceleration: usesHardwareAcceleration
            )
        }
        if let metalDecoder = availableMetalDecoder() {
            do {
                if layout == .chroma420Only,
                   let mainImageBuffer = mainImageBuffers[mainFrameKey]
                {
                    try metalDecoder.storeMainFrame(
                        surfaceID: frame.surfaceID,
                        codecID: frame.codecID,
                        imageBuffer: mainImageBuffer,
                        destinationRect: frame.destinationRect
                    )
                }
                let pixelBuffer = try metalDecoder.decode(
                    surfaceID: frame.surfaceID,
                    codecID: frame.codecID,
                    layout: layout,
                    firstImageBuffer: firstResult.imageBuffer,
                    secondImageBuffer: secondResult?.imageBuffer,
                    destinationRect: frame.destinationRect,
                    chromaRegionRects: chromaRegionRects
                )
                return RDPVideoToolboxDecodeResult(
                    imageBuffer: pixelBuffer,
                    samplePreparationMilliseconds: samplePreparationMilliseconds,
                    videoToolboxMilliseconds: videoToolboxMilliseconds,
                    imageConversionMilliseconds: Date().timeIntervalSince(conversionStartedAt) * 1000,
                    decodedPixelFormat: kCVPixelFormatType_32BGRA,
                    usesHardwareAcceleration: usesHardwareAcceleration
                )
            } catch is RDPAVC444MetalDecodeError {
                // Preserve the CPU implementation for devices or buffers Metal cannot use.
            }
        }

        let firstFrame = try yuv420Frame(from: firstResult.imageBuffer)
        let secondFrame = try secondResult.map { try yuv420Frame(from: $0.imageBuffer) }
        if layout == .chroma420Only,
           let mainImageBuffer = mainImageBuffers[mainFrameKey]
        {
            _ = try frameStore.reconstruct(
                surfaceID: frame.surfaceID,
                codecID: frame.codecID,
                layout: .yuv420Only,
                firstFrame: yuv420Frame(from: mainImageBuffer),
                secondFrame: nil,
                destinationRect: frame.destinationRect
            )
        }
        let reconstructed = try frameStore.reconstruct(
            surfaceID: frame.surfaceID,
            codecID: frame.codecID,
            layout: layout,
            firstFrame: firstFrame,
            secondFrame: secondFrame,
            destinationRect: frame.destinationRect,
            chromaRegionRects: chromaRegionRects
        )
        let pixelBuffer = try rdpMakeBGRAPixelBuffer(
            width: reconstructed.width,
            height: reconstructed.height,
            copying: reconstructed.bgra,
            bytesPerRow: reconstructed.width * 4
        )
        let imageConversionMilliseconds = Date().timeIntervalSince(conversionStartedAt) * 1000
        return RDPVideoToolboxDecodeResult(
            imageBuffer: pixelBuffer,
            samplePreparationMilliseconds: samplePreparationMilliseconds,
            videoToolboxMilliseconds: videoToolboxMilliseconds,
            imageConversionMilliseconds: imageConversionMilliseconds,
            decodedPixelFormat: kCVPixelFormatType_32BGRA,
            usesHardwareAcceleration: usesHardwareAcceleration
        )
    }

    private func availableMetalDecoder() -> RDPAVC444MetalDecoder? {
        if didAttemptMetalDecoderCreation == false {
            metalDecoder = RDPAVC444MetalDecoder()
            didAttemptMetalDecoderCreation = true
        }
        return metalDecoder
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

    private func yuv420Frame(from imageBuffer: CVImageBuffer) throws -> RDPYUV420Frame {
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else {
            throw RDPAVC444DecodeError.unsupportedPixelFormat(pixelFormat)
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              CVPixelBufferGetPlaneCount(imageBuffer) == 2
        else {
            throw RDPAVC444DecodeError.invalidYUV420Layout
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1)
        else {
            throw RDPAVC444DecodeError.missingPixelBufferPlane
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1)
        var yPlane = [UInt8](repeating: 0, count: width * height)
        var uPlane = [UInt8](repeating: 0, count: width * height / 4)
        var vPlane = [UInt8](repeating: 0, count: width * height / 4)
        yPlane.withUnsafeMutableBufferPointer { yDestination in
            uPlane.withUnsafeMutableBufferPointer { uDestination in
                vPlane.withUnsafeMutableBufferPointer { vDestination in
                    guard let yDestination = yDestination.baseAddress,
                          let uDestination = uDestination.baseAddress,
                          let vDestination = vDestination.baseAddress
                    else {
                        return
                    }
                    RDPYUV420PlaneCopy(
                        ySource: yBase.assumingMemoryBound(to: UInt8.self),
                        uvSource: uvBase.assumingMemoryBound(to: UInt8.self),
                        yDestination: yDestination,
                        uDestination: uDestination,
                        vDestination: vDestination,
                        width: width,
                        height: height,
                        yBytesPerRow: yBytesPerRow,
                        uvBytesPerRow: uvBytesPerRow
                    ).copy()
                }
            }
        }
        return try RDPYUV420Frame(width: width, height: height, y: yPlane, u: uPlane, v: vPlane)
    }
}

private struct RDPYUV420PlaneCopy: @unchecked Sendable {
    var ySource: UnsafePointer<UInt8>
    var uvSource: UnsafePointer<UInt8>
    var yDestination: UnsafeMutablePointer<UInt8>
    var uDestination: UnsafeMutablePointer<UInt8>
    var vDestination: UnsafeMutablePointer<UInt8>
    var width: Int
    var height: Int
    var yBytesPerRow: Int
    var uvBytesPerRow: Int

    func copy() {
        rdpConcurrentlyProcessRows(height: height) { rows in
            for row in rows {
                memcpy(
                    yDestination.advanced(by: row * width),
                    ySource.advanced(by: row * yBytesPerRow),
                    width
                )
            }
        }
        let chromaWidth = width / 2
        rdpConcurrentlyProcessRows(height: height / 2) { rows in
            for row in rows {
                let source = uvSource.advanced(by: row * uvBytesPerRow)
                let destinationRow = row * chromaWidth
                for column in 0 ..< chromaWidth {
                    uDestination[destinationRow + column] = source[column * 2]
                    vDestination[destinationRow + column] = source[column * 2 + 1]
                }
            }
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
    private var session: VTDecompressionSession?
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
        guard let formatDescription, let session else {
            throw RDPVideoDecodeError.missingParameterSets(codec)
        }
        let sampleBuffer = try makeSampleBuffer(
            formatDescription: formatDescription,
            lengthPrefixedData: sample.lengthPrefixedData
        )

        let videoToolboxStartedAt = Date()
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
        let videoToolboxFinishedAt = Date()
        try check(output.status, operation: "finish \(codec.displayName) decode")
        guard let imageBuffer = output.imageBuffer else {
            throw RDPVideoDecodeError.missingImageBuffer
        }

        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: videoToolboxStartedAt.timeIntervalSince(samplePreparationStartedAt) * 1000,
            videoToolboxMilliseconds: videoToolboxFinishedAt.timeIntervalSince(videoToolboxStartedAt) * 1000,
            imageConversionMilliseconds: 0,
            decodedPixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer),
            usesHardwareAcceleration: usesHardwareAcceleration
        )
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
