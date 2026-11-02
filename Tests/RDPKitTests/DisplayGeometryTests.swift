import CoreGraphics
import Foundation
@testable import RDPKit
import Testing

@Test func remoteDisplayViewportAspectFitsRemotePixelsIntoBounds() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == CGRect(x: 0, y: 50, width: 200, height: 100))
}

@Test func remoteDisplayViewportMapsBottomLeftCoordinatesToRemotePoint() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 149.9)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 100)) == RDPRemotePoint(x: 50, y: 25))
    #expect(viewport.remotePoint(from: CGPoint(x: 199, y: 51)) == RDPRemotePoint(x: 99, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 49)) == nil)
}

// AppKit reports the mouse in an unflipped view's top pixel row at maxY, and NSMouseInRect
// counts that edge in and the bottom one out.
@Test func remoteDisplayViewportCountsTheTopEdgeAndNotTheBottomOneInBottomLeftCoordinates() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 150)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 50.5)) == RDPRemotePoint(x: 0, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 50)) == nil)
    #expect(viewport.remotePoint(from: CGPoint(x: 200, y: 100)) == nil)
}

@Test func remoteDisplayViewportCountsTheTopEdgeAndNotTheBottomOneInTopLeftCoordinates() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .topLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 50)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 149.5)) == RDPRemotePoint(x: 0, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 150)) == nil)
}

@Test func remoteDisplayViewportMapsTopLeftCoordinatesToRemotePoint() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .topLeft
    )

    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 50)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 100)) == RDPRemotePoint(x: 50, y: 25))
    #expect(viewport.remotePoint(from: CGPoint(x: 199, y: 149)) == RDPRemotePoint(x: 99, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 49)) == nil)
}

// A 1000 px desktop in a 1001 pt view at 1x is drawn a whole pixel in, not half a pixel.
@Test func remoteDisplayViewportMapsWithinTheRectTheDesktopIsDrawnIn() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 1000, height: 700),
        bounds: CGRect(x: 0, y: 0, width: 1001, height: 700),
        coordinateOrigin: .bottomLeft
    )
    let drawnRect = CGRect(x: 1, y: 0, width: 1000, height: 700)

    #expect(viewport.contentRect == CGRect(x: 0.5, y: 0, width: 1000, height: 700))
    #expect(viewport.remotePoint(from: CGPoint(x: 0.75, y: 350), contentRect: drawnRect) == nil)
    #expect(viewport.remotePoint(from: CGPoint(x: 1, y: 700), contentRect: drawnRect) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 1000.5, y: 0.5), contentRect: drawnRect) == RDPRemotePoint(x: 999, y: 699))
    #expect(viewport.remotePoint(from: CGPoint(x: 500, y: 0), contentRect: drawnRect) == nil)
    #expect(viewport.remotePoint(from: CGPoint(x: 1001, y: 350), contentRect: drawnRect) == nil)
    #expect(viewport.remotePoint(from: CGPoint(x: 1, y: 0), contentRect: .zero) == nil)
}

@Test func remoteDisplayViewportRejectsInvalidGeometry() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: .zero,
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == .zero)
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0)) == nil)
}

@Test func remoteDisplayViewportRejectsNonFiniteGeometry() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: CGFloat.infinity, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )
    let validViewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == .zero)
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0)) == nil)
    #expect(validViewport.remotePoint(from: CGPoint(x: CGFloat.nan, y: 0)) == nil)
}

// The right one of two 100x50 monitors side by side.
@Test func remoteDisplayViewportShowsOnlyItsSourceRect() {
    let viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 200, height: 50),
        sourceRect: CGRect(x: 100, y: 0, width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
        coordinateOrigin: .bottomLeft
    )

    #expect(viewport.contentRect == CGRect(x: 0, y: 50, width: 200, height: 100))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 150)) == RDPRemotePoint(x: 100, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 100, y: 100)) == RDPRemotePoint(x: 150, y: 25))
    #expect(viewport.remotePoint(from: CGPoint(x: 199.9, y: 50.1)) == RDPRemotePoint(x: 199, y: 49))
    #expect(viewport.remotePoint(from: CGPoint(x: 200, y: 100)) == nil)
}

@Test func remoteDisplayViewportShowsOneMonitorOfAFrame() {
    let primary = RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 100, bottom: 50), isPrimary: true)
    let secondary = RDPRemoteMonitor(rect: RDPFrameRect(left: 100, top: 10, right: 160, bottom: 50), isPrimary: false)
    let frame = RDPFrameMetadata(RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 0,
        codecID: RDPGFXCodecID.uncompressed,
        codecName: "graphics-output-bgra",
        pixelFormat: 0x20,
        monitors: [primary, secondary],
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 160, bottom: 50),
        regionRects: [],
        encodedVideoData: Data()
    ))
    let viewport = RDPRemoteDisplayViewport(
        frame: frame,
        monitor: secondary,
        bounds: CGRect(x: 0, y: 0, width: 60, height: 40),
        coordinateOrigin: .topLeft
    )

    #expect(viewport.sourceRect == CGRect(x: 100, y: 10, width: 60, height: 40))
    #expect(viewport.contentRect == CGRect(x: 0, y: 0, width: 60, height: 40))
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0)) == RDPRemotePoint(x: 100, y: 10))
    #expect(viewport.remotePoint(from: CGPoint(x: 59.5, y: 39.5)) == RDPRemotePoint(x: 159, y: 49))
}

@Test func remoteDisplayViewportShowsOnlyTheSourceRectWithinTheDesktop() {
    var viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 100, height: 50),
        sourceRect: CGRect(x: 50, y: 0, width: 100, height: 50),
        bounds: CGRect(x: 0, y: 0, width: 50, height: 50),
        coordinateOrigin: .topLeft
    )

    #expect(viewport.contentRect == CGRect(x: 0, y: 0, width: 50, height: 50))
    #expect(viewport.remotePoint(from: CGPoint(x: 49.9, y: 0)) == RDPRemotePoint(x: 99, y: 0))

    viewport.sourceRect = CGRect(x: 100, y: 0, width: 100, height: 50)
    #expect(viewport.contentRect == .zero)
    #expect(viewport.remotePoint(from: CGPoint(x: 0, y: 0), contentRect: viewport.bounds) == nil)
}

/// Display Control makes desktop widths even, so a desktop shown one to one in a view a pixel
/// wider sits half a pixel off; with the screen's scale the content moves onto a whole pixel,
/// keeps its size, and points map to the desktop where it is drawn.
@Test func remoteDisplayViewportPutsTheDesktopOnAWholePixel() {
    var viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 1_000, height: 700),
        bounds: CGRect(x: 0, y: 0, width: 1_001, height: 700),
        coordinateOrigin: .bottomLeft
    )
    #expect(viewport.contentRect == CGRect(x: 0.5, y: 0, width: 1_000, height: 700))

    viewport.backingScaleFactor = 1
    #expect(viewport.contentRect == CGRect(x: 1, y: 0, width: 1_000, height: 700))
    #expect(viewport.remotePoint(from: CGPoint(x: 1, y: 700)) == RDPRemotePoint(x: 0, y: 0))
    #expect(viewport.remotePoint(from: CGPoint(x: 0.75, y: 350)) == nil)
    #expect(viewport.remotePoint(from: CGPoint(x: 1_000.75, y: 0.25)) == RDPRemotePoint(x: 999, y: 699))

    // On a Retina screen the desktop is 500.5 points wide in a view 1,001 pixels wide.
    viewport.bounds = CGRect(x: 0, y: 0, width: 500.5, height: 350)
    viewport.backingScaleFactor = 2
    #expect(viewport.contentRect == CGRect(x: 0.5, y: 0, width: 500, height: 350))

    for factor: CGFloat? in [nil, 0, -1, .nan, .infinity] {
        viewport.backingScaleFactor = factor
        #expect(viewport.contentRect == CGRect(x: 0.25, y: 0, width: 500, height: 350))
    }
}

/// A drag past the desktop lands on its nearest pixel, the row the view's origin is away from
/// included, whatever the origin, and within the shown part when only part is shown.
@Test func remoteDisplayViewportMapsAPointPastTheDesktopToItsNearestPixel() {
    var viewport = RDPRemoteDisplayViewport(
        remotePixelSize: CGSize(width: 1_000, height: 700),
        bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        coordinateOrigin: .bottomLeft,
        backingScaleFactor: 1
    )
    let desktop = viewport.contentRect
    #expect(desktop == CGRect(x: 0, y: 50, width: 1_000, height: 700))
    #expect(viewport.remotePoint(from: CGPoint(x: desktop.midX, y: desktop.minY)) == nil)
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: desktop.midX, y: desktop.minY)) == RDPRemotePoint(x: 500, y: 699))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: -1_000, y: -1_000)) == RDPRemotePoint(x: 0, y: 699))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: 5_000, y: 5_000)) == RDPRemotePoint(x: 999, y: 0))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: 300.5, y: 400.5))
        == viewport.remotePoint(from: CGPoint(x: 300.5, y: 400.5)))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: CGFloat.nan, y: 0)) == nil)

    viewport.coordinateOrigin = .topLeft
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: desktop.midX, y: desktop.maxY + 10)) == RDPRemotePoint(x: 500, y: 699))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: desktop.midX, y: desktop.minY - 10)) == RDPRemotePoint(x: 500, y: 0))

    viewport.sourceRect = CGRect(x: 100, y: 10, width: 60, height: 40)
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: 5_000, y: 5_000)) == RDPRemotePoint(x: 159, y: 49))
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: -5_000, y: -5_000)) == RDPRemotePoint(x: 100, y: 10))

    viewport.remotePixelSize = .zero
    #expect(viewport.nearestRemotePoint(from: CGPoint(x: 0, y: 0)) == nil)
}
