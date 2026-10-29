import CoreMedia
import CoreVideo
import Foundation

public final class RDPFrameSampleBufferFactory {
    private var format: RDPFrameSampleBufferFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var cleanAperture: CFDictionary?
    private var nextPresentationTimeValue: CMTimeValue = 0

    public init() {}

    public func willChangeDisplayFormat(for presentation: RDPDecodedFramePresentation) -> Bool {
        format != RDPFrameSampleBufferFormat(presentation: presentation)
    }

    public func makeSampleBuffer(for presentation: RDPDecodedFramePresentation) throws -> CMSampleBuffer {
        let nextFormat = RDPFrameSampleBufferFormat(presentation: presentation)
        if format != nextFormat {
            format = nextFormat
            formatDescription = nil
            cleanAperture = nextFormat.cleanAperture
        }

        // The clean aperture crops the coded picture to the frame's display size and
        // must be attached before the format description is derived from the buffer.
        if let cleanAperture {
            CVBufferSetAttachment(presentation.imageBuffer, kCVImageBufferCleanApertureKey, cleanAperture, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(presentation.imageBuffer, kCVImageBufferCleanApertureKey)
        }
        let formatDescription = try formatDescription ?? makeFormatDescription(for: presentation.imageBuffer)
        self.formatDescription = formatDescription

        nextPresentationTimeValue += 1
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: nextPresentationTimeValue, timescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        try check(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: presentation.imageBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            operation: "create display sample buffer"
        )

        guard let sampleBuffer else {
            throw RDPFrameSampleBufferError.missingSampleBuffer
        }
        markSampleBufferForImmediateDisplay(sampleBuffer)
        return sampleBuffer
    }

    public func reset() {
        format = nil
        formatDescription = nil
        cleanAperture = nil
        nextPresentationTimeValue = 0
    }

    private func makeFormatDescription(for imageBuffer: CVImageBuffer) throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        try check(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            operation: "create display format description"
        )
        guard let formatDescription else {
            throw RDPFrameSampleBufferError.missingFormatDescription
        }
        return formatDescription
    }

    private func markSampleBufferForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ),
            CFArrayGetCount(attachments) > 0
        else {
            return
        }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RDPFrameSampleBufferError.coreMedia(operation: operation, status: status)
        }
    }
}

public enum RDPFrameSampleBufferError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingFormatDescription
    case missingSampleBuffer
    case coreMedia(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .missingFormatDescription:
            "Core Media did not return a display format description."
        case .missingSampleBuffer:
            "Core Media did not return a display sample buffer."
        case let .coreMedia(operation, status):
            "Core Media failed to \(operation): \(status)."
        }
    }
}

private struct RDPFrameSampleBufferFormat: Equatable {
    var displayWidth: Int
    var displayHeight: Int
    var decodedWidth: Int
    var decodedHeight: Int
    // Direct VideoToolbox output (YUV) and composed BGRA frames can share dimensions,
    // and a format description only matches buffers of its own pixel format.
    var pixelFormat: OSType

    init(presentation: RDPDecodedFramePresentation) {
        displayWidth = Int(presentation.frame.width)
        displayHeight = Int(presentation.frame.height)
        decodedWidth = CVPixelBufferGetWidth(presentation.imageBuffer)
        decodedHeight = CVPixelBufferGetHeight(presentation.imageBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(presentation.imageBuffer)
    }

    var cleanAperture: CFDictionary? {
        guard displayWidth > 0,
              displayHeight > 0,
              displayWidth <= decodedWidth,
              displayHeight <= decodedHeight,
              displayWidth != decodedWidth || displayHeight != decodedHeight
        else {
            return nil
        }
        return [
            kCVImageBufferCleanApertureWidthKey: Double(displayWidth),
            kCVImageBufferCleanApertureHeightKey: Double(displayHeight),
            kCVImageBufferCleanApertureHorizontalOffsetKey: Double(displayWidth - decodedWidth) / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: Double(displayHeight - decodedHeight) / 2,
        ] as CFDictionary
    }
}
