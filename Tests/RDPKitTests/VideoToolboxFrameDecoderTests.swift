import CoreMedia
import CoreVideo
import Foundation
@testable import RDPKit
import Testing
import VideoToolbox

@Test func videoToolboxFrameDecoderCopiesBitmapFramesThroughReusableDecoder() throws {
    let decoder = RDPVideoToolboxFrameDecoder()

    let first = try decoder.decodeDetailed(bitmapFrame(pixels: [
        0x01, 0x02, 0x03, 0xFF,
        0x04, 0x05, 0x06, 0xFF,
        0x07, 0x08, 0x09, 0xFF,
        0x0A, 0x0B, 0x0C, 0xFF,
    ]))
    let second = try decoder.decodeDetailed(bitmapFrame(pixels: [
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0xFF,
        0x70, 0x80, 0x90, 0xFF,
        0xA0, 0xB0, 0xC0, 0xFF,
    ]))

    #expect(CVPixelBufferGetWidth(first.imageBuffer) == 2)
    #expect(CVPixelBufferGetHeight(first.imageBuffer) == 2)
    #expect(CVPixelBufferGetPixelFormatType(first.imageBuffer) == kCVPixelFormatType_32BGRA)
    #expect(try bgraPixel(atX: 1, y: 0, in: first.imageBuffer) == [0x04, 0x05, 0x06, 0xFF])

    #expect(CVPixelBufferGetWidth(second.imageBuffer) == 2)
    #expect(CVPixelBufferGetHeight(second.imageBuffer) == 2)
    #expect(CVPixelBufferGetPixelFormatType(second.imageBuffer) == kCVPixelFormatType_32BGRA)
    #expect(try bgraPixel(atX: 0, y: 1, in: second.imageBuffer) == [0x70, 0x80, 0x90, 0xFF])
}

@Test func videoToolboxFrameDecoderKeepsSequenceStatePerSurface() {
    let decoder = RDPVideoToolboxFrameDecoder()

    for surfaceID: UInt16 in [1, 2] {
        #expect(throws: (any Error).self) {
            try decoder.decodeDetailed(videoFrame(surfaceID: surfaceID, videoCodec: .h264))
        }
        #expect(throws: (any Error).self) {
            try decoder.decodeDetailed(videoFrame(
                surfaceID: surfaceID,
                codecID: RDPGFXCodecID.avc444v2,
                videoCodec: .h264,
                avc444SubframeLayout: .yuv420Only
            ))
        }
        #expect(throws: (any Error).self) {
            try decoder.decodeDetailed(videoFrame(surfaceID: surfaceID, videoCodec: .hevc))
        }
    }

    #expect(decoder.decoderContextCount == 6)

    decoder.reset(surfaceID: 1)

    #expect(decoder.decoderContextCount == 3)

    decoder.reset()

    #expect(decoder.decoderContextCount == 0)
}

@Test func sequenceDecoderDecodesEncodedH264Stream() throws {
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 60, chroma: 128), (luma: 60, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264)

    for accessUnit in accessUnits {
        let result = try decoder.decodeDetailed(accessUnit)
        #expect(CVPixelBufferGetWidth(result.imageBuffer) == 64)
        #expect(CVPixelBufferGetHeight(result.imageBuffer) == 64)
    }
}

@Test func sequenceDecoderPreservesCodedSamplesOfLimitedRangeStreams() throws {
    // VideoToolbox marks a stream encoded from video-range input as limited range, like the
    // SPS VUI that GNOME Remote Desktop and KRdp send.
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 20, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264, preservesCodedSamples: true)

    let result = try decoder.decodeDetailed(accessUnits[0])

    #expect(CVPixelBufferGetPixelFormatType(result.imageBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let luma = try lumaSample(atX: 8, y: 8, in: result.imageBuffer)
    #expect(abs(Int(luma) - 20) <= 2)
}

private func bitmapFrame(pixels: [UInt8]) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 1,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "surface-bgra",
        pixelFormat: 0x20,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data(pixels),
        decodedBitmapBytesPerRow: 8
    )
}

private func videoFrame(
    surfaceID: UInt16,
    codecID: UInt16 = RDPGFXCodecID.avc420,
    videoCodec: RDPVideoCodec,
    avc444SubframeLayout: RDPAVC444SubframeLayout? = nil
) -> RDPGraphicsFrameSnapshot {
    RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: surfaceID,
        codecID: codecID,
        codecName: RDPGFXCodecID.name(for: codecID),
        videoCodec: videoCodec,
        pixelFormat: 0x20,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16),
        regionRects: [RDPFrameRect(left: 0, top: 0, right: 16, bottom: 16)],
        encodedVideoData: Data([0]),
        avc444SubframeLayout: avc444SubframeLayout
    )
}

private func bgraPixel(atX x: Int, y: Int, in imageBuffer: CVImageBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
        throw PixelReadError.missingBaseAddress
    }

    let offset = y * CVPixelBufferGetBytesPerRow(imageBuffer) + x * 4
    let pixel = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
    return [pixel[0], pixel[1], pixel[2], pixel[3]]
}

private func lumaSample(atX x: Int, y: Int, in imageBuffer: CVImageBuffer) throws -> UInt8 {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }
    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else {
        throw PixelReadError.missingBaseAddress
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
    return baseAddress.advanced(by: y * bytesPerRow + x).assumingMemoryBound(to: UInt8.self).pointee
}

private enum PixelReadError: Error {
    case missingBaseAddress
}

/// Encodes flat 64x64 video-range NV12 frames as one VideoToolbox H.264 stream and returns
/// each access unit in Annex B form, with the SPS and PPS ahead of the first.
func encodeH264AnnexB(frames: [(luma: UInt8, chroma: UInt8)]) throws -> [Data] {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: 64,
        height: 64,
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else {
        throw H264TestEncodeError.encoder(status)
    }
    defer {
        VTCompressionSessionInvalidate(session)
    }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 1.0 as CFNumber)

    let encodedFrames = EncodedSampleLog()
    for (index, frame) in frames.enumerated() {
        let pixelBuffer = try flatVideoRangeNV12(luma: frame.luma, chroma: frame.chroma)
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { _, _, sampleBuffer in
            encodedFrames.append(sampleBuffer)
        }
        guard encodeStatus == noErr else {
            throw H264TestEncodeError.encoder(encodeStatus)
        }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

    let sampleBuffers = encodedFrames.samples
    guard sampleBuffers.count == frames.count else {
        throw H264TestEncodeError.missingOutput
    }
    return try sampleBuffers.enumerated().map { index, sampleBuffer in
        try annexB(from: sampleBuffer, includingParameterSets: index == 0)
    }
}

private func flatVideoRangeNV12(luma: UInt8, chroma: UInt8) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        64,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw H264TestEncodeError.pixelBuffer(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    for (plane, value) in [(0, luma), (1, chroma)] {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw H264TestEncodeError.missingOutput
        }
        memset(
            base,
            Int32(value),
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        )
    }
    return pixelBuffer
}

private func annexB(from sampleBuffer: CMSampleBuffer, includingParameterSets: Bool) throws -> Data {
    let startCode: [UInt8] = [0, 0, 0, 1]
    var annexB = Data()
    if includingParameterSets {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw H264TestEncodeError.missingOutput
        }
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )
        for index in 0 ..< parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard let pointer else {
                throw H264TestEncodeError.missingOutput
            }
            annexB.append(contentsOf: startCode)
            annexB.append(pointer, count: size)
        }
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        throw H264TestEncodeError.missingOutput
    }
    var lengthPrefixed = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(blockBuffer))
    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: lengthPrefixed.count, destination: &lengthPrefixed)
    var offset = 0
    while offset + 4 <= lengthPrefixed.count {
        let length = lengthPrefixed[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        annexB.append(contentsOf: startCode)
        annexB.append(contentsOf: lengthPrefixed[offset ..< offset + length])
        offset += length
    }
    return annexB
}

private final class EncodedSampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleBuffers: [CMSampleBuffer] = []

    var samples: [CMSampleBuffer] {
        lock.withLock { sampleBuffers }
    }

    func append(_ sampleBuffer: CMSampleBuffer?) {
        guard let sampleBuffer else {
            return
        }
        lock.withLock {
            sampleBuffers.append(sampleBuffer)
        }
    }
}

private enum H264TestEncodeError: Error {
    case encoder(OSStatus)
    case pixelBuffer(CVReturn)
    case missingOutput
}
