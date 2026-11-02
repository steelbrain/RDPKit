import CoreGraphics
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
