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

/// The areas a frame changed are held until it ends; past 1,024 rectangles they collapse into
/// their bounding box, so a frame the server never ends does not grow them without bound.
@Test func primarySurfaceCompositorBoundsTheAreasAnOpenFrameChanged() throws {
    let compositor = RDPPrimarySurfaceCompositor(width: 64, height: 32)
    _ = try compositor.process([.frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 0, frameID: 1))])
    for index in 0 ..< 1_100 {
        let left = UInt16(index % 64)
        let top = UInt16(index / 64)
        #expect(try compositor.process([.setSurfaceBits(RDPSurfaceBitsCommand(
            destinationLeft: left,
            destinationTop: top,
            destinationRight: left + 1,
            destinationBottom: top + 1,
            bitmapData: RDPExtendedBitmapData(
                bitsPerPixel: 32,
                flags: 0,
                codecID: 0,
                width: 1,
                height: 1,
                extendedCompressionHeader: nil,
                bitmapData: Data(repeating: 0x11, count: 4)
            )
        ))]).isEmpty)
    }

    let frame = try #require(try compositor.process([
        .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 1, frameID: 1)),
    ]).first)

    // The first 1,025 cells collapsed into rows 0-16; the 75 after them are listed.
    #expect(frame.regionRects.count == 76)
    #expect(frame.regionRects.first == RDPFrameRect(left: 0, top: 0, right: 64, bottom: 17))
}

/// A surface bits command that fails to decode must not swallow the frame
/// markers after it: every frame still needs its acknowledgement
/// ([MS-RDPRFX] 2.2.3.3), and the good bits reach the next snapshot.
@Test func primarySurfaceCompositorEndsFramesAfterUndecodableSurfaceBits() throws {
    func bits(left: UInt16, width: UInt16, pixel: UInt8) -> RDPSurfaceCommand {
        .setSurfaceBits(RDPSurfaceBitsCommand(
            destinationLeft: left,
            destinationTop: 0,
            destinationRight: left + width,
            destinationBottom: 1,
            bitmapData: RDPExtendedBitmapData(
                bitsPerPixel: 32,
                flags: 0,
                codecID: 0,
                width: width,
                height: 1,
                extendedCompressionHeader: nil,
                bitmapData: Data(repeating: pixel, count: 4)
            )
        ))
    }
    let compositor = RDPPrimarySurfaceCompositor(width: 2, height: 1)

    #expect(throws: RDPDecodeError.invalidGraphicsUpdatePDU) {
        try compositor.process([
            .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 0, frameID: 1)),
            bits(left: 0, width: 1, pixel: 0x11),
            .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 1, frameID: 1)),
            .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 0, frameID: 2)),
            bits(left: 1, width: 2, pixel: 0x22),
            .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 1, frameID: 2)),
        ])
    }
    #expect(compositor.takeCompletedFrameIDs() == [1, 2])

    let frames = try compositor.process([
        .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 0, frameID: 3)),
        .frameMarker(RDPSurfaceFrameMarkerCommand(frameAction: 1, frameID: 3)),
    ])
    #expect(frames.count == 1)
    #expect(frames.first?.regionRects == [RDPFrameRect(left: 0, top: 0, right: 1, bottom: 1)])
    #expect(frames.first?.decodedBitmapData?.prefix(4) == Data(repeating: 0x11, count: 4))
}
