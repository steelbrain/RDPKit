import CoreMedia
import CoreVideo
import Foundation

public final class RDPFrameSampleBufferFactory {
    private var lastFormatKey: RDPFrameSampleBufferFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var formatDescriptionKey: RDPFrameSampleBufferFormat?
    private var cleanAperture: CFDictionary?
    private var cleanApertureKey: RDPFrameSampleBufferFormat?
    private var imageBuffersClearedForCurrentFormat = Set<ObjectIdentifier>()
    private var nextPresentationTimeValue: CMTimeValue = 0

    public init() {}

    public func willChangeDisplayFormat(for presentation: RDPDecodedFramePresentation) -> Bool {
        lastFormatKey != RDPFrameSampleBufferFormat(presentation: presentation)
    }

    public func makeSampleBuffer(for presentation: RDPDecodedFramePresentation) throws -> CMSampleBuffer {
        let formatKey = RDPFrameSampleBufferFormat(presentation: presentation)
        if lastFormatKey != formatKey {
            resetFormatCaches(for: formatKey)
        }

        applyCleanAperture(for: presentation, formatKey: formatKey)
        let formatDescription = try displayFormatDescription(for: presentation, formatKey: formatKey)

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
        lastFormatKey = nil
        formatDescription = nil
        formatDescriptionKey = nil
        cleanAperture = nil
        cleanApertureKey = nil
        imageBuffersClearedForCurrentFormat.removeAll(keepingCapacity: true)
        nextPresentationTimeValue = 0
    }

    private func resetFormatCaches(for formatKey: RDPFrameSampleBufferFormat) {
        formatDescription = nil
        formatDescriptionKey = nil
        cleanAperture = nil
        cleanApertureKey = nil
        imageBuffersClearedForCurrentFormat.removeAll(keepingCapacity: true)
        lastFormatKey = formatKey
    }

    private func applyCleanAperture(
        for presentation: RDPDecodedFramePresentation,
        formatKey: RDPFrameSampleBufferFormat
    ) {
        guard let cleanAperture = cleanAperture(for: presentation, formatKey: formatKey) else {
            removeCleanApertureIfNeeded(from: presentation.imageBuffer)
            return
        }

        CVBufferSetAttachment(
            presentation.imageBuffer,
            kCVImageBufferCleanApertureKey,
            cleanAperture,
            .shouldPropagate
        )
    }

    private func cleanAperture(
        for presentation: RDPDecodedFramePresentation,
        formatKey: RDPFrameSampleBufferFormat
    ) -> CFDictionary? {
        if cleanApertureKey == formatKey {
            return cleanAperture
        }

        let displayWidth = Int(presentation.frame.width)
        let displayHeight = Int(presentation.frame.height)
        let decodedWidth = CVPixelBufferGetWidth(presentation.imageBuffer)
        let decodedHeight = CVPixelBufferGetHeight(presentation.imageBuffer)

        guard displayWidth > 0,
              displayHeight > 0,
              displayWidth <= decodedWidth,
              displayHeight <= decodedHeight
        else {
            cleanAperture = nil
            cleanApertureKey = formatKey
            return nil
        }

        guard displayWidth != decodedWidth || displayHeight != decodedHeight else {
            cleanAperture = nil
            cleanApertureKey = formatKey
            return nil
        }

        let nextCleanAperture = [
            kCVImageBufferCleanApertureWidthKey: Double(displayWidth),
            kCVImageBufferCleanApertureHeightKey: Double(displayHeight),
            kCVImageBufferCleanApertureHorizontalOffsetKey: Double(displayWidth - decodedWidth) / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: Double(displayHeight - decodedHeight) / 2,
        ] as CFDictionary
        cleanAperture = nextCleanAperture
        cleanApertureKey = formatKey
        return nextCleanAperture
    }

    private func removeCleanApertureIfNeeded(from imageBuffer: CVImageBuffer) {
        let imageBufferID = ObjectIdentifier(imageBuffer)
        guard imageBuffersClearedForCurrentFormat.insert(imageBufferID).inserted else {
            return
        }
        CVBufferRemoveAttachment(imageBuffer, kCVImageBufferCleanApertureKey)
    }

    private func displayFormatDescription(
        for presentation: RDPDecodedFramePresentation,
        formatKey: RDPFrameSampleBufferFormat
    ) throws -> CMVideoFormatDescription {
        if let formatDescription,
           formatDescriptionKey == formatKey
        {
            return formatDescription
        }

        var nextFormatDescription: CMVideoFormatDescription?
        try check(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: presentation.imageBuffer,
                formatDescriptionOut: &nextFormatDescription
            ),
            operation: "create display format description"
        )

        guard let nextFormatDescription else {
            throw RDPFrameSampleBufferError.missingFormatDescription
        }

        formatDescription = nextFormatDescription
        formatDescriptionKey = formatKey
        return nextFormatDescription
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

    init(presentation: RDPDecodedFramePresentation) {
        displayWidth = Int(presentation.frame.width)
        displayHeight = Int(presentation.frame.height)
        decodedWidth = CVPixelBufferGetWidth(presentation.imageBuffer)
        decodedHeight = CVPixelBufferGetHeight(presentation.imageBuffer)
    }
}
