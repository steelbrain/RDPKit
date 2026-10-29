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

@Test func videoToolboxFrameDecoderDropsStateOfDeletedSurfaces() throws {
    let decoder = RDPVideoToolboxFrameDecoder()
    for surfaceID: UInt16 in [1, 2] {
        _ = try? decoder.decodeDetailed(videoFrame(surfaceID: surfaceID, videoCodec: .h264))
        _ = try? decoder.decodeDetailed(videoFrame(
            surfaceID: surfaceID,
            codecID: RDPGFXCodecID.avc444v2,
            videoCodec: .h264,
            avc444SubframeLayout: .yuv420Only
        ))
    }
    #expect(decoder.decoderContextCount == 4)

    var frame = bitmapFrame(pixels: Array(repeating: 0xFF, count: 16))
    frame.deletedSurfaceIDs = [1]
    _ = try decoder.decodeDetailed(frame)

    #expect(decoder.decoderContextCount == 2)
}

/// A decoder reset for another session forgets that the last one came from KPipeWire, whose
/// limited-range colours would otherwise be read into the next server's full-range video.
@Test func videoToolboxFrameDecoderResetForgetsTheEncoder() throws {
    let decoder = RDPVideoToolboxFrameDecoder()
    func matrix(_ imageBuffer: CVImageBuffer) -> String? {
        CVBufferCopyAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
    }
    let krdp = try decoder.decodeDetailed(firstTranscriptFrame("krdp-colour-chart-transcript")).imageBuffer
    #expect(matrix(krdp) == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)

    decoder.reset()
    let gnome = try decoder.decodeDetailed(firstTranscriptFrame("gnome-negotiation-transcript")).imageBuffer

    #expect(matrix(gnome) == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
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
    // KRdp: Baseline profile with timing info and bitstream restrictions, here not from KPipeWire.
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
    let rewritten = try #require(RDPH264SequenceParameterSet.signalingSampleColours(original, encodedByKPipeWire: false))

    #expect(rewritten == hexData(expectedHex))
    #expect(RDPH264SequenceParameterSet.signalingSampleColours(rewritten, encodedByKPipeWire: false) == rewritten)
    // KPipeWire streams keep a range they signal.
    #expect(RDPH264SequenceParameterSet.signalingSampleColours(rewritten, encodedByKPipeWire: true) == rewritten)
    let originalSize = CMVideoFormatDescriptionGetDimensions(try h264FormatDescription(sequenceParameterSet: original))
    let rewrittenFormat = try h264FormatDescription(sequenceParameterSet: rewritten)
    let rewrittenSize = CMVideoFormatDescriptionGetDimensions(rewrittenFormat)
    #expect(rewrittenSize.width == originalSize.width && rewrittenSize.height == originalSize.height)
    try expectColours(of: rewrittenFormat, fullRange: true, matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
}

@Test func kPipeWireSequenceParameterSetWithoutRangeSignalsLimitedRangeBT601() throws {
    let original = hexData("67 42 c0 3e da 00 f0 01 2d a1 00 00 03 00 01 00 00 07 d0 8f 08 04 2a")
    let rewritten = try #require(RDPH264SequenceParameterSet.signalingSampleColours(original, encodedByKPipeWire: true))

    #expect(rewritten == hexData("67 42 c0 3e da 00 f0 01 2d a6 a0 21 a0 c8 00 00 03 00 08 00 00 3e 84 78 40 21 50"))
    try expectColours(
        of: h264FormatDescription(sequenceParameterSet: rewritten),
        fullRange: false,
        matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
    )
}

@Test func sequenceParameterSetRewriteRejectsTruncatedSPS() {
    #expect(RDPH264SequenceParameterSet.signalingSampleColours(hexData("67 64 08 28 ac"), encodedByKPipeWire: false) == nil)
    #expect(RDPH264SequenceParameterSet.signalingSampleColours(hexData("68 ce 38 80"), encodedByKPipeWire: false) == nil)
}

/// FreeRDP's encoders code 1920x1080 as 1920x1088 pictures cropped in the SPS (freerdp-shadow
/// fixtures).
@Test func sequenceParameterSetLosesOnlyItsFrameCropping() throws {
    let cropped = hexData("67 64 00 28 ac b2 00 f0 04 4f cb 08 00 00 03 00 08 00 00 03 01 e4 78 c1 92 40")
    let uncropped = try #require(RDPH264SequenceParameterSet.removingFrameCropping(cropped))

    let croppedFormat = try h264FormatDescription(sequenceParameterSet: cropped)
    let uncroppedFormat = try h264FormatDescription(sequenceParameterSet: uncropped)
    #expect(CMVideoFormatDescriptionGetDimensions(croppedFormat).height == 1080)
    #expect(CMVideoFormatDescriptionGetDimensions(uncroppedFormat).width == 1920)
    #expect(CMVideoFormatDescriptionGetDimensions(uncroppedFormat).height == 1088)
    #expect(RDPH264SequenceParameterSet.croppedWidth(cropped) == 1920)
    #expect(RDPH264SequenceParameterSet.removingFrameCropping(uncropped) == uncropped)
    // The VUI after the cropping is copied whole.
    #expect(
        RDPH264SequenceParameterSet.signalingSampleColours(uncropped, encodedByKPipeWire: false).flatMap(RDPH264SequenceParameterSet.removingFrameCropping)
            == RDPH264SequenceParameterSet.signalingSampleColours(cropped, encodedByKPipeWire: false).flatMap(RDPH264SequenceParameterSet.removingFrameCropping)
    )
}

@Test func sequenceParameterSetCroppedWidthLeavesOutCroppedColumns() throws {
    let accessUnit = try encodeH264AnnexB(frames: [(luma: 60, chroma: 128)], width: 40, height: 24)[0]
    let sequenceParameterSet = try #require(RDPH264AnnexB.sample(from: accessUnit).sequenceParameterSet)

    #expect(RDPH264SequenceParameterSet.croppedWidth(sequenceParameterSet) == 40)
    #expect(RDPH264SequenceParameterSet.croppedWidth(hexData("67 64 08 28 ac")) == nil)
}

@Test func kPipeWireIsIdentifiedByItsX264Options() throws {
    #expect(try RDPAnnexB.identifiesKPipeWire(firstTranscriptFrame("krdp-colour-chart-transcript").encodedVideoData))
    #expect(try RDPAnnexB.identifiesKPipeWire(firstTranscriptFrame("krdp-negotiation-transcript").encodedVideoData))
    // x264 configured by FreeRDP, and another encoder.
    #expect(try !RDPAnnexB.identifiesKPipeWire(
        firstTranscriptFrame("freerdp-shadow-avc420-transcript", graphicsCapabilityProfile: .avc420).encodedVideoData
    ))
    #expect(try !RDPAnnexB.identifiesKPipeWire(firstTranscriptFrame("gnome-negotiation-transcript").encodedVideoData))

    let options = "cabac=0 ref=1 deblock=0:0:0 analyse=0:0 me=dia subme=0 psy=1 psy_rd=1,00:0,00 mixed_ref=0 "
        + "me_range=16 chroma_me=1 trellis=0 8x8dct=0 cqm=0 deadzone=21,11 fast_pskip=1 chroma_qp_offset=0 "
    #expect(RDPAnnexB.identifiesKPipeWire(x264VersionSEI(options: options + "keyint=100 rc=crf crf=21,0")))
    #expect(!RDPAnnexB.identifiesKPipeWire(x264VersionSEI(options: options + "keyint=250 rc=crf crf=23.0")))
    #expect(!RDPAnnexB.identifiesKPipeWire(x264VersionSEI(options: options + "keyint=100 rc=abr bitrate=10000")))
    // An SEI of another payload type, and one cut short.
    #expect(!RDPAnnexB.identifiesKPipeWire(x264VersionSEI(options: "keyint=100 rc=crf", payloadType: 4)))
    #expect(!RDPAnnexB.identifiesKPipeWire(x264VersionSEI(options: "keyint=100 rc=crf").prefix(30)))
}

/// FreeRDP converts to full-range BT.709 itself (MS-RDPEGFX 3.3.8.3.1) and encodes through x264
/// with no range signalled. The fixture's first frame shows mpv's test pattern in a 1280x720
/// window at the top left: six colour bars about 213 pixels wide, of which red, green, and blue
/// are checked against what gnome-remote-desktop's video and FreeRDP's RemoteFX show of them.
@Test func freeRDPX264FramePresentsFullRangeBT709() throws {
    let frame = try firstTranscriptFrame("freerdp-shadow-avc420-transcript", graphicsCapabilityProfile: .avc420)
    let imageBuffer = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame).imageBuffer
    let rendered = try coreImageBGRA(imageBuffer)
    let width = CVPixelBufferGetWidth(imageBuffer)
    for (bar, colour) in [(0, [253, 23, 0]), (1, [0, 216, 0]), (3, [0, 14, 255])] {
        let offset = (660 * width + bar * 213 + 100) * 4
        let presented = [Int(rendered[offset + 2]), Int(rendered[offset + 1]), Int(rendered[offset])]
        #expect(zip(presented, colour).allSatisfy { abs($0 - $1) <= 4 }, "bar \(bar): \(presented)")
    }
}

/// gnome-remote-desktop encodes full-range samples under an SPS without a video signal type.
/// Presented AVC420 output must match the full-range BT.709 conversion of MS-RDPEGFX 3.3.8.3.1
/// that the AVC444 path applies; read as limited range it is about 10 levels off.
@Test(arguments: [
    ("gnome-negotiation-transcript", 100, 100, [UInt8]([34, 130, 127])),
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

/// gnome-remote-desktop codes its 1280x720 frames as 1280x768 pictures without SPS cropping;
/// the 48 rows past the frame are black, below the login screen's grey.
@Test func decodedImagesShowOnlyTheFrame() throws {
    let frame = try firstTranscriptFrame("gnome-negotiation-transcript")
    let decoder = RDPVideoToolboxFrameDecoder()
    #expect(try CVPixelBufferGetHeight(decoder.decodeDetailed(frame).imageBuffer) == 768)

    let image = try decoder.decode(frame)

    #expect(image.width == 1280)
    #expect(image.height == 720)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bottomRow = (image.height - 1) * image.width * 4
    #expect(pixels[bottomRow + 100 * 4 ..< bottomRow + 100 * 4 + 3].allSatisfy { $0 > 16 })
}

/// KRdp 6.8 encodes through KPipeWire's libx264 path, which feeds x264 limited-range BT.601
/// and signals no range, against MS-RDPEGFX 3.3.8.3.1. The fixture's first frame is a chart
/// of flat patches drawn on a KRdp virtual monitor; each must present as the colour drawn.
@Test func krdpX264FramePresentsTheColoursDrawn() throws {
    let frame = try firstTranscriptFrame("krdp-colour-chart-transcript")
    let imageBuffer = try RDPVideoToolboxFrameDecoder().decodeDetailed(frame).imageBuffer
    let rendered = try coreImageBGRA(imageBuffer)
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    let patches: [[Int]] = [
        [0, 0, 0], [255, 255, 255], [128, 128, 128], [64, 64, 64],
        [192, 192, 192], [20, 22, 24], [255, 0, 0], [0, 255, 0],
        [0, 0, 255], [16, 16, 16], [235, 235, 235], [240, 120, 30],
    ]
    for (index, drawn) in patches.enumerated() {
        let x = (index % 4 * 2 + 1) * width / 8
        let y = (index / 4 * 2 + 1) * height / 6
        let offset = (y * width + x) * 4
        let presented = [Int(rendered[offset + 2]), Int(rendered[offset + 1]), Int(rendered[offset])]
        #expect(zip(presented, drawn).allSatisfy { abs($0 - $1) <= 3 }, "patch \(index): \(presented) for \(drawn)")
    }
}

@Test func sequenceDecoderFallsBackToOriginalSPSWhenRewriteIsRejected() throws {
    let accessUnits = try encodeH264AnnexB(frames: [(luma: 60, chroma: 128)])
    let decoder = RDPVideoToolboxSequenceDecoder(codec: .h264) { _, _ in hexData("67 64") }

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
func coreImageBGRA(_ imageBuffer: CVImageBuffer) throws -> [UInt8] {
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

private func expectColours(of format: CMVideoFormatDescription, fullRange: Bool, matrix: CFString) throws {
    let extensions = try #require(CMFormatDescriptionGetExtensions(format) as? [CFString: Any])
    #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool == fullRange)
    #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == matrix as String)
    #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    #expect(extensions[kCMFormatDescriptionExtension_TransferFunction] as? String == kCMFormatDescriptionTransferFunction_sRGB as String)
}

private func firstTranscriptFrame(
    _ fixture: String,
    graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .avcThinClient
) throws -> RDPGraphicsFrameSnapshot {
    try #require(replayTranscriptFixture(fixture, graphicsCapabilityProfile: graphicsCapabilityProfile).report.rdpGraphicsFirstFrame)
}

/// An access unit holding x264's version SEI with `options`.
private func x264VersionSEI(options: String, payloadType: UInt8 = 5) -> Data {
    let uuid: [UInt8] = [0xDC, 0x45, 0xE9, 0xBD, 0xE6, 0xD9, 0x48, 0xB7, 0x96, 0x2C, 0xD8, 0x20, 0xD9, 0x23, 0xEE, 0xEF]
    let payload = uuid + Array("x264 - core 165 r3222 b35605a - H.264/MPEG-4 AVC codec - options: \(options)".utf8) + [0]
    let size = [UInt8](repeating: 0xFF, count: payload.count / 255) + [UInt8(payload.count % 255)]
    return Data([0, 0, 0, 1, 0x06, payloadType] + size + payload + [0x80])
}

private enum PixelReadError: Error {
    case missingBaseAddress
}

/// Encodes flat video-range NV12 frames as one VideoToolbox H.264 stream and returns each
/// access unit in Annex B form, with the SPS and PPS ahead of the first.
func encodeH264AnnexB(frames: [(luma: UInt8, chroma: UInt8)], width: Int = 64, height: Int = 64) throws -> [Data] {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(width),
        height: Int32(height),
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
        let pixelBuffer = try flatVideoRangeNV12(luma: frame.luma, chroma: frame.chroma, width: width, height: height)
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

private func flatVideoRangeNV12(luma: UInt8, chroma: UInt8, width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
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
