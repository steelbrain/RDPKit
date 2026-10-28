import Foundation
@testable import RDPKit
import Testing

@Test func primarySurfaceCompositorPaintsOnlyDestinationOfPaddedBitmap() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 2)
    let bottomRow: [UInt8] = [
        0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x04, 0x04, 0x04,
    ]
    let topRow: [UInt8] = [
        0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x14, 0x14, 0x14,
    ]
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 1,
            destinationTop: 0,
            destinationRight: 3,
            destinationBottom: 0,
            width: 4,
            height: 2,
            bitsPerPixel: 24,
            flags: 0,
            compressedHeader: nil,
            bitmapDataStream: Data(bottomRow + topRow)
        ),
    ])

    let frame = try #require(try compositor.process(update).first)

    #expect(frame.regionRects == [RDPFrameRect(left: 1, top: 0, right: 4, bottom: 1)])
    #expect(frame.decodedBitmapData == Data([
        0x00, 0x00, 0x00, 0x00, 0x11, 0x11, 0x11, 0xFF, 0x12, 0x12, 0x12, 0xFF, 0x13, 0x13, 0x13, 0xFF,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
}

@Test func primarySurfaceCompositorClipsCompressedBitmapPaddedToFourPixels() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 3, height: 1)
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 2,
            destinationBottom: 0,
            width: 4,
            height: 1,
            bitsPerPixel: 16,
            flags: 0x0401,
            compressedHeader: nil,
            bitmapDataStream: Data([0x84, 0x1F, 0x00, 0xE0, 0x07, 0x00, 0xF8, 0xFF, 0xFF])
        ),
    ])

    let frame = try #require(try compositor.process(update).first)

    #expect(frame.decodedBitmapData == Data([
        0xFF, 0x00, 0x00, 0xFF,
        0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
    ]))
}

@Test func primarySurfaceCompositorRejectsBitmapLargerThanDesktop() {
    let compositor = RDPPrimarySurfaceCompositor(width: 4, height: 1)
    let update = RDPBitmapUpdate(rectangles: [
        RDPBitmapUpdateRectangle(
            destinationLeft: 0,
            destinationTop: 0,
            destinationRight: 0,
            destinationBottom: 0,
            width: 0xFFFF,
            height: 0xFFFF,
            bitsPerPixel: 16,
            flags: 0x0401,
            compressedHeader: nil,
            bitmapDataStream: Data([0xF0, 0xFF, 0xFF])
        ),
    ])

    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try compositor.process(update)
    }
}

@Test func primarySurfaceCompositorReportsCompletedFramesWithoutPixelChanges() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 2, height: 2)
    let frames = try compositor.process([
        .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 0, frameID: 7)),
        .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 1, frameID: 7)),
    ])

    #expect(frames.isEmpty)
    #expect(compositor.takeCompletedFrameIDs() == [7])
    #expect(compositor.takeCompletedFrameIDs().isEmpty)
}
