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
    private var h264Decoders: [UInt16: RDPH264FrameSequenceDecoder] = [:]
    private var avc444Decoders: [UInt16: RDPAVC444FrameDecoder] = [:]
    private var hevcDecoders: [UInt16: RDPHEVCFrameSequenceDecoder] = [:]
    private let bitmapDecoder = RDPBitmapFrameDecoder()
    private let imageConverter = RDPVideoToolboxCGImageConverter()

    public init() {}

    public func reset() {
        h264Decoders.removeAll()
        avc444Decoders.removeAll()
        hevcDecoders.removeAll()
    }

    func reset(surfaceID: UInt16) {
        h264Decoders[surfaceID] = nil
        avc444Decoders[surfaceID] = nil
        hevcDecoders[surfaceID] = nil
    }

    public func decode(_ frame: RDPGraphicsFrameSnapshot) throws -> CGImage {
        try imageConverter.makeImage(from: decodeDetailed(frame).imageBuffer)
    }

    public func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        if frame.contentKind == .bitmap {
            return try bitmapDecoder.decodeDetailed(frame)
        }

        switch frame.videoCodec {
        case .h264:
            if frame.avc444SubframeLayout != nil {
                return try avc444Decoder(for: frame.surfaceID).decodeDetailed(frame)
            }
            return try h264Decoder(for: frame.surfaceID).decodeDetailed(frame.encodedVideoData)
        case .hevc:
            return try hevcDecoder(for: frame.surfaceID).decodeDetailed(frame.encodedVideoData)
        }
    }

    var decoderContextCounts: (h264: Int, avc444: Int, hevc: Int) {
        (h264Decoders.count, avc444Decoders.count, hevcDecoders.count)
    }

    private func h264Decoder(for surfaceID: UInt16) -> RDPH264FrameSequenceDecoder {
        if let decoder = h264Decoders[surfaceID] {
            return decoder
        }
        let decoder = RDPH264FrameSequenceDecoder()
        h264Decoders[surfaceID] = decoder
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

    private func hevcDecoder(for surfaceID: UInt16) -> RDPHEVCFrameSequenceDecoder {
        if let decoder = hevcDecoders[surfaceID] {
            return decoder
        }
        let decoder = RDPHEVCFrameSequenceDecoder()
        hevcDecoders[surfaceID] = decoder
        return decoder
    }
}

private final class RDPBitmapFrameDecoder {
    func decodeDetailed(_ frame: RDPGraphicsFrameSnapshot) throws -> RDPVideoToolboxDecodeResult {
        guard frame.contentKind == .bitmap,
              let bitmapData = frame.decodedBitmapData,
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
        let elapsed = Date().timeIntervalSince(start) * 1000
        return RDPVideoToolboxDecodeResult(
            imageBuffer: imageBuffer,
            samplePreparationMilliseconds: 0,
            videoToolboxMilliseconds: 0,
            imageConversionMilliseconds: elapsed,
            decodedPixelFormat: kCVPixelFormatType_32BGRA,
            usesHardwareAcceleration: nil
        )
    }

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

        if status != kCVReturnSuccess {
            retainedData.release()
            return try makeCopiedPixelBuffer(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
        }

        guard let pixelBuffer else {
            throw RDPBitmapFrameDecodeError.missingPixelBuffer
        }
        return pixelBuffer
    }

    private func makeCopiedPixelBuffer(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        data: Data
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            makeVideoDecoderImageBufferAttributes(),
            &pixelBuffer
        )
        try check(status, operation: "create bitmap pixel buffer")

        guard let pixelBuffer else {
            throw RDPBitmapFrameDecodeError.missingPixelBuffer
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RDPBitmapFrameDecodeError.missingBaseAddress
        }

        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress else {
                return
            }
            for row in 0 ..< height {
                let sourceRow = source.advanced(by: row * bytesPerRow)
                let destinationRow = destination.advanced(by: row * destinationBytesPerRow)
                memcpy(destinationRow, sourceRow, width * 4)
            }
        }
        return pixelBuffer
    }

    private func check(_ status: CVReturn, operation: String) throws {
        guard status == kCVReturnSuccess else {
            throw RDPBitmapFrameDecodeError.coreVideo(operation: operation, status: status)
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

private final class RDPAVC444FrameDecoder {
    private struct MainFrameKey: Hashable {
        var codecID: UInt16
        var left: UInt16
        var top: UInt16
        var right: UInt16
        var bottom: UInt16
    }

    private let h264Decoder = RDPH264FrameSequenceDecoder(
        outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    )
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
        let pixelBuffer = try makeBGRAImageBuffer(from: reconstructed)
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

    private func makeBGRAImageBuffer(from frame: RDPAVC444ReconstructedFrame) throws -> CVImageBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            makeVideoDecoderImageBufferAttributes(),
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RDPAVC444DecodeError.coreVideo(operation: "create AVC444 pixel buffer", status: status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RDPAVC444DecodeError.missingPixelBufferPlane
        }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        frame.bgra.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else {
                return
            }
            for row in 0 ..< frame.height {
                memcpy(
                    destination.advanced(by: row * destinationBytesPerRow),
                    sourceBase.advanced(by: row * frame.width * 4),
                    frame.width * 4
                )
            }
        }
        return pixelBuffer
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

private func makeVideoDecoderSpecification() -> CFDictionary {
    [
        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
    ] as CFDictionary
}

private func makeVideoDecoderImageBufferAttributes(pixelFormat: OSType? = nil) -> CFDictionary {
    var attributes: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    if let pixelFormat {
        attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat
    }
    return attributes as CFDictionary
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
    private let outputPixelFormat: OSType?

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    public init() {
        outputPixelFormat = nil
    }

    init(outputPixelFormat: OSType) {
        self.outputPixelFormat = outputPixelFormat
    }

    public func reset() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        sequenceParameterSet = nil
        pictureParameterSet = nil
        formatDescription = nil
        session = nil
        usesHardwareAcceleration = nil
        output.status = noErr
        output.imageBuffer = nil
    }

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
                imageBufferAttributes: makeVideoDecoderImageBufferAttributes(pixelFormat: outputPixelFormat),
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

    public func reset() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        videoParameterSet = nil
        sequenceParameterSet = nil
        pictureParameterSet = nil
        formatDescription = nil
        session = nil
        usesHardwareAcceleration = nil
        output.status = noErr
        output.imageBuffer = nil
    }

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
