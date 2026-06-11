import CoreMedia
import CoreVideo
import Foundation
@testable import RDPKit
import Testing

@Test func frameSampleBufferFactoryCreatesImmediateDisplaySampleBuffer() throws {
    let factory = RDPFrameSampleBufferFactory()
    let imageBuffer = try makePixelBuffer(width: 4, height: 4)
    let presentation = RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 4, height: 4),
        imageBuffer: imageBuffer
    )

    #expect(factory.willChangeDisplayFormat(for: presentation))
    let sampleBuffer = try factory.makeSampleBuffer(for: presentation)

    #expect(factory.willChangeDisplayFormat(for: presentation) == false)
    #expect(CMSampleBufferGetImageBuffer(sampleBuffer) === imageBuffer)
    #expect(sampleBufferDisplaysImmediately(sampleBuffer))
}

@Test func frameSampleBufferFactoryAppliesAndRemovesCleanAperture() throws {
    let factory = RDPFrameSampleBufferFactory()
    let imageBuffer = try makePixelBuffer(width: 4, height: 4)
    let croppedPresentation = RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 2, height: 3),
        imageBuffer: imageBuffer
    )

    _ = try factory.makeSampleBuffer(for: croppedPresentation)

    let cleanAperture = try #require(cleanApertureAttachment(from: imageBuffer))
    #expect(cleanAperture.doubleValue(for: kCVImageBufferCleanApertureWidthKey) == 2)
    #expect(cleanAperture.doubleValue(for: kCVImageBufferCleanApertureHeightKey) == 3)
    #expect(cleanAperture.doubleValue(for: kCVImageBufferCleanApertureHorizontalOffsetKey) == -1)
    #expect(cleanAperture.doubleValue(for: kCVImageBufferCleanApertureVerticalOffsetKey) == -0.5)

    let fullSizePresentation = RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 4, height: 4),
        imageBuffer: imageBuffer
    )
    #expect(factory.willChangeDisplayFormat(for: fullSizePresentation))
    _ = try factory.makeSampleBuffer(for: fullSizePresentation)

    #expect(cleanApertureAttachment(from: imageBuffer) == nil)
}

@Test func frameSampleBufferFactoryResetRequiresNewDisplayFormat() throws {
    let factory = RDPFrameSampleBufferFactory()
    let presentation = RDPDecodedFramePresentation(
        frame: graphicsFrame(width: 4, height: 4),
        imageBuffer: try makePixelBuffer(width: 4, height: 4)
    )

    _ = try factory.makeSampleBuffer(for: presentation)
    #expect(factory.willChangeDisplayFormat(for: presentation) == false)

    factory.reset()

    #expect(factory.willChangeDisplayFormat(for: presentation))
}

private func graphicsFrame(width: UInt16, height: UInt16) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 0x20,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: width, bottom: height)],
        encodedVideoData: Data()
    )
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var imageBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &imageBuffer
    )
    guard status == kCVReturnSuccess,
          let imageBuffer
    else {
        throw PixelBufferTestError.creationFailed(status)
    }
    return imageBuffer
}

private func sampleBufferDisplaysImmediately(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
    ),
        CFArrayGetCount(attachments) > 0
    else {
        return false
    }

    let attachment = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFDictionary.self
    )
    guard let value = CFDictionaryGetValue(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
    ) else {
        return false
    }

    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
}

private func cleanApertureAttachment(from imageBuffer: CVImageBuffer) -> NSDictionary? {
    CVBufferCopyAttachment(imageBuffer, kCVImageBufferCleanApertureKey, nil) as? NSDictionary
}

private extension NSDictionary {
    func doubleValue(for key: CFString) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }
}

private enum PixelBufferTestError: Error {
    case creationFailed(CVReturn)
}
