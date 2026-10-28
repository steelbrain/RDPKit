import CoreImage
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

@Test func sequenceDecoderSignalsFullRangeWithoutRescalingSamples() throws {
    // VideoToolbox marks a stream encoded from video-range input as limited range. The decoder
    // re-signals it as full range, so the samples must still arrive unscaled.
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 20, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264, preservesCodedSamples: true)

    let result = try decoder.decodeDetailed(accessUnits[0])

    #expect(CVPixelBufferGetPixelFormatType(result.imageBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    let luma = try nv12Sample(atX: 8, y: 8, in: result.imageBuffer)[0]
    #expect(abs(Int(luma) - 20) <= 2)
}

@Test(arguments: [
    // GNOME Remote Desktop: High profile with Extended_SAR and timing info.
    (
        "67 64 08 28 ac 2b 20 0a 00 c3 7f e0 02 00 01 e2 00 00 07 d0 00 03 a9 81 08",
        "67 64 08 28 ac 2b 20 0a 00 c3 7f e0 02 00 01 ed c0 43 40 50 00 00 3e 80 00 1d 4c 08 40"
    ),
    // KRdp: Baseline profile with timing info and bitstream restrictions.
    (
        "67 42 c0 3e da 00 f0 01 2d a1 00 00 03 00 01 00 00 07 d0 8f 08 04 2a",
        "67 42 c0 3e da 00 f0 01 2d a6 e0 21 a0 28 00 00 03 00 08 00 00 3e 84 78 40 21 50"
    ),
    // No VUI.
    ("67 42 00 0a f4 21 32", "67 42 00 0a f4 21 34 dc 04 34 04 08"),
    // High profile with a scaling list.
    ("67 64 00 1e ad 84 40 5a 10 99", "67 64 00 1e ad 84 40 5a 10 9a 6e 02 1a 02 04"),
])
func sequenceParameterSetSignalsFullRangeBT709(originalHex: String, expectedHex: String) throws {
    let original = hexData(originalHex)
    let rewritten = try #require(RDPH264SequenceParameterSet.signalingFullRangeBT709(original))

    #expect(rewritten == hexData(expectedHex))
    #expect(RDPH264SequenceParameterSet.signalingFullRangeBT709(rewritten) == rewritten)
    let originalSize = CMVideoFormatDescriptionGetDimensions(try h264FormatDescription(sequenceParameterSet: original))
    let rewrittenFormat = try h264FormatDescription(sequenceParameterSet: rewritten)
    let rewrittenSize = CMVideoFormatDescriptionGetDimensions(rewrittenFormat)
    #expect(rewrittenSize.width == originalSize.width && rewrittenSize.height == originalSize.height)
    let extensions = try #require(CMFormatDescriptionGetExtensions(rewrittenFormat) as? [CFString: Any])
    #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool == true)
    #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
    #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    #expect(extensions[kCMFormatDescriptionExtension_TransferFunction] as? String == kCMFormatDescriptionTransferFunction_sRGB as String)
}

@Test func sequenceParameterSetRewriteRejectsTruncatedSPS() {
    #expect(RDPH264SequenceParameterSet.signalingFullRangeBT709(hexData("67 64 08 28 ac")) == nil)
    #expect(RDPH264SequenceParameterSet.signalingFullRangeBT709(hexData("68 ce 38 80")) == nil)
}

/// GNOME Remote Desktop and KRdp encode full-range samples under an SPS without a video signal
/// type. Presented AVC420 output must match the full-range BT.709 conversion of MS-RDPEGFX
/// 3.3.8.3.1 that the AVC444 path applies; read as limited range it is about 10 levels off.
@Test(arguments: [
    ("gnome-negotiation-transcript", 100, 100, [UInt8]([34, 130, 127])),
    ("krdp-negotiation-transcript", 1680, 1584, [UInt8]([35, 129, 126])),
])
func avc420FixtureFramesPresentAsFullRangeBT709(fixture: String, x: Int, y: Int, background: [UInt8]) throws {
    let frame = try firstTranscriptFrame(fixture)
    let presented = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame).imageBuffer
    let coded = try RDPVideoToolboxSequenceDecoder(codec: .h264, preservesCodedSamples: true)
        .decodeDetailed(frame.encodedVideoData).imageBuffer
    #expect(try nv12Sample(atX: x, y: y, in: coded) == background)

    let expected = try rdpReconstructAVC444OnCPU(main: coded, auxiliary: nil, usesV2Layout: false, chromaRegionRects: [])
    let rendered = try coreImageBGRA(presented)
    CVPixelBufferLockBaseAddress(expected, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(expected, .readOnly)
    }
    let expectedBase = try #require(CVPixelBufferGetBaseAddress(expected)).assumingMemoryBound(to: UInt8.self)
    let expectedBytesPerRow = CVPixelBufferGetBytesPerRow(expected)
    let width = CVPixelBufferGetWidth(expected)
    let backgroundOffset = y * width * 4 + x * 4
    for channel in 0 ..< 3 {
        #expect(abs(Int(rendered[backgroundOffset + channel]) - Int(expectedBase[y * expectedBytesPerRow + x * 4 + channel])) <= 2)
    }
    var difference = 0
    var count = 0
    for row in stride(from: 0, to: CVPixelBufferGetHeight(expected), by: 4) {
        for column in stride(from: 0, to: width, by: 4) {
            for channel in 0 ..< 3 {
                difference += abs(
                    Int(rendered[(row * width + column) * 4 + channel])
                        - Int(expectedBase[row * expectedBytesPerRow + column * 4 + channel])
                )
                count += 1
            }
        }
    }
    #expect(Double(difference) / Double(count) < 1.5)
}

@Test func sequenceDecoderFallsBackToOriginalSPSWhenRewriteIsRejected() throws {
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 60, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264) { _ in hexData("67 64") }

    let result = try decoder.decodeDetailed(accessUnits[0])

    #expect(CVPixelBufferGetWidth(result.imageBuffer) == 64)
}

@Test func sequenceDecoderRecreatesInvalidatedSession() throws {
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 60, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264)
    _ = try decoder.decodeDetailed(accessUnits[0])

    VTDecompressionSessionInvalidate(try #require(decoder.session))

    let result = try decoder.decodeDetailed(accessUnits[0])
    #expect(CVPixelBufferGetWidth(result.imageBuffer) == 64)
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

/// Returns the Y, Cb, and Cr samples of an NV12 pixel.
private func nv12Sample(atX x: Int, y: Int, in imageBuffer: CVImageBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
    }
    guard let luma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0),
          let chroma = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1)
    else {
        throw PixelReadError.missingBaseAddress
    }
    let lumaOffset = y * CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0) + x
    let chromaOffset = y / 2 * CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1) + x / 2 * 2
    return [
        luma.load(fromByteOffset: lumaOffset, as: UInt8.self),
        chroma.load(fromByteOffset: chromaOffset, as: UInt8.self),
        chroma.load(fromByteOffset: chromaOffset + 1, as: UInt8.self),
    ]
}

/// Renders the image the way the frame compositor does.
private func coreImageBGRA(_ imageBuffer: CVImageBuffer) throws -> [UInt8] {
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    CIContext().render(
        CIImage(cvImageBuffer: imageBuffer),
        toBitmap: &bytes,
        rowBytes: width * 4,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .BGRA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return bytes
}

private func h264FormatDescription(sequenceParameterSet: Data) throws -> CMVideoFormatDescription {
    let parameterSets = [[UInt8](sequenceParameterSet), [0x68, 0xCE, 0x38, 0x80]]
    var formatDescription: CMVideoFormatDescription?
    let status = parameterSets[0].withUnsafeBufferPointer { sps in
        parameterSets[1].withUnsafeBufferPointer { pps in
            var pointers = [sps.baseAddress, pps.baseAddress].compactMap { $0 }
            var sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescription
            )
        }
    }
    guard status == noErr, let formatDescription else {
        throw H264TestEncodeError.encoder(status)
    }
    return formatDescription
}

private func firstTranscriptFrame(_ fixture: String) throws -> RDPGraphicsFrameSnapshot {
    try #require(replayTranscriptFixture(fixture).report.rdpGraphicsFirstFrame)
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
